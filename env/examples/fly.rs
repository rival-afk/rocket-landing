//! Скрипт-трекер: держится центра коридора, пишет ленту TAS.
//! Использование: fly [out.json] [max_ticks] [vy_tgt] [lookahead] [kx] [kp]
//! out.json — файл в формате Godot user://tas.json (inputs + samples).
//!
//! Отличия от провалившегося @centre_tape:
//!   - управление по желаемой горизонтальной скорости (vx_des = dx * KX),
//!     а не по углу от dx напрямую — нет перелётов и осцилляций;
//!   - desired_angle = atan(vx_des / vy) с насыщением ±0.6 рад;
//!   - thrust только при vy > cap (не жмём, когда медленно).
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
    let path = std::env::args().nth(1).unwrap_or_else(|| "tas_fly.json".to_string());
    let max_ticks: u64 = std::env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(20000);
    let vy_tgt: f64 = std::env::args().nth(3).and_then(|s| s.parse().ok()).unwrap_or(225.0);
    let lookahead: f64 = std::env::args().nth(4).and_then(|s| s.parse().ok()).unwrap_or(250.0);
    let _ = lookahead; // legacy arg, kept for CLI compatibility
    let kx: f64 = std::env::args().nth(5).and_then(|s| s.parse().ok()).unwrap_or(1.3);
    let kp: f64 = std::env::args().nth(6).and_then(|s| s.parse().ok()).unwrap_or(3.2);
    let cs: f64 = std::env::args().nth(7).and_then(|s| s.parse().ok()).unwrap_or(0.6);
    let _ = cs; // legacy, kept for CLI compatibility

    let mut lane = Lane::new(0, 0);
    let mut tape: Vec<(bool, f64)> = Vec::new();
    let mut samples: Vec<serde_json::Value> = Vec::new();
    let mut died_at: Option<u64> = None;
    let mut worst_h = 0.0f64;
    let mut worst_off = 0.0f64;

    for i in 0..max_ticks {
        // сэмпл ДО тика (как _tas_sample в игре), tick % 4 == 0
        if i % 4 == 0 {
            samples.push(serde_json::json!({
                "t": i, "x": lane.x, "y": lane.y,
                "vx": lane.vx, "vy": lane.vy, "depth": lane.cur_depth,
            }));
        }

        let y = lane.y;
        // два референса: ближний (вернуться в центр СЕЙЧАС) и дальний (планирование),
        // вес ближнего растёт по мере ухода ракеты от оси коридора
        let near = cave::center_at(y);
        let h_now = cave::half_at(y);
        let pos_err = ((lane.x - near).abs() / h_now).clamp(0.0, 1.5);
        let far = cave::center_at(y + lookahead);
        let w = pos_err.min(1.0);
        let dx = (far - lane.x) * (1.0 - w) + (near - lane.x) * w;
        // превентивное торможение перед сужениями впереди
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

        // инвариант игры: центр ракеты внутри коридора (проверка _tas_check_logic)
        let c = cave::center_at(y);
        let h = cave::half_at(y);
        worst_off = worst_off.max((lane.x - c).abs() / h);
        worst_h = worst_h.max(h);

        let (_, terminated) = lane.step(thrust, torque, 1.0, "depth");
        tape.push((thrust, torque));
        if terminated {
            died_at = Some(i);
            break;
        }
        if i % 5 == 0 {
            eprintln!("tick={i:4} y={:7.1} x={:7.2} vx={:6.1} vy={:6.1} ang={:6.1} torque={:+.2} vx_des={:+.1} des_ang={:+.2} c={:.1}",
                y, lane.x, lane.vx, lane.vy, lane.angle.to_degrees(), torque, vx_des, des_ang, cave::center_at(y));
        }
    }

    let depth = lane.max_depth;
    match died_at {
        Some(t) => println!("DIED at tick {t}, depth = {depth:.2} m ({} ticks)", tape.len()),
        None => println!("SURVIVED {max_ticks} ticks, depth = {depth:.2} m"),
    }
    println!("worst |x-c|/h = {worst_off:.3} (must stay < 1.0 for in-game verify)");

    let out = serde_json::json!({
        "version": 1,
        "created": "rust-fly",
        "engine": "rust-env",
        "spawn_y": 0.0,
        "final_depth_m": depth,
        "ticks": tape.len(),
        "inputs": tape.iter().map(|&(t, q)| serde_json::json!({ "thrust": t, "torque": q })).collect::<Vec<_>>(),
        "samples": samples,
    });
    std::fs::write(&path, serde_json::to_string_pretty(&out).unwrap()).expect("write");
    println!("wrote {path}");
}
