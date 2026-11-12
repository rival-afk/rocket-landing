//! Контроллер "следование по центру коридора":
//!   будущий центр рассчитывается для позиции чуть ниже текущей,
//!   PD-регулятор по углу носа ставит torque для поворота,
//!   вперёд плывущее демпфирование через thrust (braking).
use rocket_landing_env::cave;
use rocket_landing_env::env::Lane;

const TARGET_VY: f64 = 210.0;       // желаемая скорость погружения, px/s
const LOOKAHEAD: f64 = 120.0;       // смотрим ближе
const KP_ANGLE: f64 = 0.7;          // насколько круто поворачиваем

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| "flow_tape.json".to_string());
    let nticks: u32 = std::env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(12000);
    let mut lane = Lane::new(0, 0);
    let mut tape = Vec::with_capacity(nticks as usize);
    let mut died = None;
    for i in 0..nticks {
        let dx = cave::center_at(lane.y + LOOKAHEAD) - lane.x;

        // желаемый угол носа от вертикали — насыщается на ~±33°,
        // чтобы ракета не делала резкие повороты прямо в стену
        let speed = lane.vy.max(50.0);
        let raw_angle = dx / speed;
        let angle_target = raw_angle.clamp(-0.6, 0.6);

        // разница между желаемым и текущим углом
        let mut d_angle = angle_target - lane.angle;
        while d_angle > std::f64::consts::PI { d_angle -= 2.0 * std::f64::consts::PI; }
        while d_angle < -std::f64::consts::PI { d_angle += 2.0 * std::f64::consts::PI; }

        // torque: кнуш сильнее если дальше от цели
        let torque = (d_angle * KP_ANGLE).clamp(-1.0, 1.0);

        // тяга: притормаживаем, если падаем быстрее целевой скорости
        let thrust = lane.vy > TARGET_VY;

        if i % 20 == 0 || (i % 5 == 0 && lane.y > 400.0 && lane.y < 600.0) {
            eprintln!("tick={} x={:.1} y={:.1} vy={:.1} angle={:.1} torque={:.2} dx={:.1}", i, lane.x, lane.y, lane.vy, lane.angle.to_degrees(), torque, dx);
        }
        let (_, terminated) = lane.step(thrust, torque, 1.0, "depth");
        tape.push((thrust, torque));
        if terminated {
            died = Some(i);
            break;
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
    std::fs::write(&path, serde_json::to_string(&out).unwrap()).expect("write tape");
    println!("wrote {path} ({} bytes)", tape.len());
}
