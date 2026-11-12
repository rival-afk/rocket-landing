//! Как fly.rs, но стартует не со спавна, а реплеит префикс ленты (например,
//! оптимизированный local_optimize), а дальше управляется контроллером.
//! Использование: fly_from [prefix.json] [out.json] [max_ticks] [vy_tgt] [la] [kx] [kp] [cs]
use rocket_landing_env::cave;
use rocket_landing_env::env::Lane;

fn clamp(x: f64, lo: f64, hi: f64) -> f64 {
    x.max(lo).min(hi)
}

fn ang_wrap(a: f64) -> f64 {
    let mut a = a;
    while a > std::f64::consts::PI { a -= 2.0 * std::f64::consts::PI; }
    while a < -std::f64::consts::PI { a += 2.0 * std::f64::consts::PI; }
    a
}

fn main() {
    let prefix_path = std::env::args().nth(1).unwrap_or_else(|| "tas_fly_opt.json".to_string());
    let path = std::env::args().nth(2).unwrap_or_else(|| "tas_fly2.json".to_string());
    let max_ticks: u64 = std::env::args().nth(3).and_then(|s| s.parse().ok()).unwrap_or(30000);
    let vy_tgt: f64 = std::env::args().nth(4).and_then(|s| s.parse().ok()).unwrap_or(225.0);
    let lookahead: f64 = std::env::args().nth(5).and_then(|s| s.parse().ok()).unwrap_or(250.0);
    let kx: f64 = std::env::args().nth(6).and_then(|s| s.parse().ok()).unwrap_or(1.3);
    let kp: f64 = std::env::args().nth(7).and_then(|s| s.parse().ok()).unwrap_or(3.2);
    let cs: f64 = std::env::args().nth(8).and_then(|s| s.parse().ok()).unwrap_or(0.6);

    // читаем префикс
    let pdata = std::fs::read_to_string(&prefix_path).expect("read prefix");
    let pv: serde_json::Value = serde_json::from_str(&pdata).expect("parse prefix");
    let prefix: Vec<(bool, f64)> = pv["inputs"].as_array().expect("inputs")
        .iter()
        .map(|x| (x["thrust"].as_bool().unwrap_or(false), x["torque"].as_f64().unwrap_or(0.0)))
        .collect();
    eprintln!("prefix: {} ticks", prefix.len());

    let mut lane = Lane::new(0, 0);
    let mut tape: Vec<(bool, f64)> = Vec::with_capacity(prefix.len() + 4096);
    let mut samples: Vec<serde_json::Value> = Vec::new();
    let mut died_at: Option<u64> = None;
    let mut worst_off = 0.0f64;
    let mut tick: u64 = 0;

    // реплей префикса (сэмплы в том же формате, что пишет Godot)
    for &(thrust, torque) in &prefix {
        if tick % 4 == 0 {
            samples.push(serde_json::json!({
                "t": tick, "x": lane.x, "y": lane.y,
                "vx": lane.vx, "vy": lane.vy, "depth": lane.cur_depth,
            }));
        }
        let (_, terminated) = lane.step(thrust, torque, 1.0, "depth");
        tape.push((thrust, torque));
        tick += 1;
        if terminated {
            died_at = Some(tick);
            break;
        }
    }
    if died_at.is_some() {
        println!("prefix DIED at tick {}, depth={:.2} m", died_at.unwrap(), lane.max_depth);
        std::process::exit(1);
    }
    eprintln!("prefix replayed OK, y={:.1} depth={:.2} m state: vx={:.1} vy={:.1} angle={:.1}",
        lane.y, lane.max_depth, lane.vx, lane.vy, lane.angle.to_degrees());

    // дальше — контроллер fly
    for i in 0..max_ticks {
        if tick % 4 == 0 {
            samples.push(serde_json::json!({
                "t": tick, "x": lane.x, "y": lane.y,
                "vx": lane.vx, "vy": lane.vy, "depth": lane.cur_depth,
            }));
        }
        let y = lane.y;
        let near = cave::center_at(y);
        let h_now = cave::half_at(y);
        let pos_err = ((lane.x - near).abs() / h_now).clamp(0.0, 1.5);
        let far = cave::center_at(y + lookahead);
        let w = pos_err.min(1.0);
        let dx = (far - lane.x) * (1.0 - w) + (near - lane.x) * w;
        let mut min_h = h_now;
        for &dy in &[128.0f64, 256.0, 384.0, 512.0, 640.0] {
            min_h = min_h.min(cave::half_at(y + dy));
        }
        let vy_cap2 = if min_h < 70.0 { 155.0 } else if min_h < 80.0 { 185.0 } else if min_h < 90.0 { 210.0 } else { vy_tgt };
        let vy_cap3 = if pos_err > 0.6 { 145.0 } else if pos_err > 0.4 { 185.0 } else { vy_cap2 };
        let vy_cap = vy_cap3;
        let vx_des = clamp(dx * kx - cs * lane.vx, -180.0, 180.0);
        let vy_eff = lane.vy.abs().max(80.0);
        let des_ang = (vx_des / vy_eff).atan().clamp(-0.62, 0.62);
        let ang_err = ang_wrap(des_ang - lane.angle);
        let torque = clamp(ang_err * kp, -1.0, 1.0);
        let thrust = lane.vy > vy_cap;
        let c = cave::center_at(y);
        let h = cave::half_at(y);
        worst_off = worst_off.max((lane.x - c).abs() / h);

        let (_, terminated) = lane.step(thrust, torque, 1.0, "depth");
        tape.push((thrust, torque));
        tick += 1;
        if terminated {
            died_at = Some(tick);
            break;
        }
        if i % 500 == 0 && i > 0 {
            eprintln!("tick={tick:6} depth={:7.2} m y={:9.1} x={:7.1} vy={:6.1} angle={:6.1}",
                lane.cur_depth, lane.y, lane.x, lane.vy, lane.angle.to_degrees());
        }
    }

    let depth = lane.max_depth;
    match died_at {
        Some(t) => println!("DIED at tick {t}, depth = {depth:.2} m ({} ticks)", tape.len()),
        None => println!("SURVIVED {max_ticks} ticks, depth = {depth:.2} m"),
    }
    println!("worst |x-c|/h = {worst_off:.3}");

    let out = serde_json::json!({
        "version": 1,
        "created": "rust-fly-from",
        "engine": "env-fly",
        "spawn_y": 0.0,
        "final_depth_m": depth,
        "ticks": tape.len(),
        "inputs": tape.iter().map(|&(t, q)| serde_json::json!({ "thrust": t, "torque": q })).collect::<Vec<_>>(),
        "samples": samples,
    });
    std::fs::write(&path, serde_json::to_string(&out).unwrap()).expect("write");
    println!("wrote {path} ({} ticks)", tape.len());
}
