//! Центр-following контроллер — смотрит на ближайший узел впереди (узлy > y).

use rocket_landing_env::cave;
use rocket_landing_env::env::Lane;

const KNOT: f64 = 256.0;
const TARGET_VY: f64 = 180.0;       // px/s — медленно, чтобы успевать на изломах
const ANGLE_KP: f64 = 2.2;

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| "centre_tape.json".to_string());
    let nticks: u32 = std::env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(25000);
    let target_vy: f64 = std::env::args().nth(3).and_then(|s| s.parse().ok()).unwrap_or(TARGET_VY);
    let mut lane = Lane::new(0, 0);
    let mut tape: Vec<(bool, f64)> = Vec::new();
    let mut died = None;

    // отладочный счётчик лучших глубины
    let mut best_tick = 0u32;

    for i in 0..nticks {
        // смотрим на ближайший узел впереди (rope движется от узла к узлу)
        let k_y = (lane.y / KNOT).floor() * KNOT;
        let target = cave::center_at(k_y + KNOT);
        let dx = target - lane.x;
        // желаемый угол носа от вертикали (положительный — вправо)
        let speed = lane.vy.abs().max(50.0);
        let desired_angle = (dx / speed).clamp(-1.0, 1.0) * 0.3;

        let mut d_angle = desired_angle - lane.angle;
        while d_angle > std::f64::consts::PI { d_angle -= 2.0 * std::f64::consts::PI; }
        while d_angle < -std::f64::consts::PI { d_angle += 2.0 * std::f64::consts::PI; }

        let torque = (d_angle * ANGLE_KP).clamp(-1.0, 1.0);

        let thrust = lane.vy > target_vy;

        if i % 25 == 0 { eprintln!("tick={i:5} y={:.1} x={:.2} vy={:.1} angle={:.1} torque={:+.2} target_dx={:+.2}", lane.y, lane.x, lane.vy, lane.angle.to_degrees(), torque, dx); }

        let (_, terminated) = lane.step(thrust, torque, 1.0, "depth");
        tape.push((thrust, torque));
        if terminated {
            died = Some(i);
            break;
        }
        if i % 1000 == 0 && i > best_tick {
            best_tick = i;
            eprintln!("tick={i:6} y={:.2} m x={:.1} vy={:.1} angle={:.1}", lane.y / 50.0, lane.x, lane.vy, lane.angle.to_degrees());
        }
    }

    match died {
        Some(t) => println!("died at tick {t}, depth_m = {:.2}", lane.max_depth),
        None => println!("survived {nticks} ticks, depth_m = {:.2}", lane.max_depth),
    }

    let out = serde_json::json!({
        "ticks": tape.len(),
        "final_depth_m": lane.max_depth,
        "survived": died.is_none(),
        "inputs": tape.iter().map(|&(t, q)| serde_json::json!({ "thrust": t, "torque": q })).collect::<Vec<_>>(),
    });
    std::fs::write(&path, serde_json::to_vec(&out).unwrap()).expect("write tape");
    println!("wrote {path} ({} ticks)", tape.len());
}
