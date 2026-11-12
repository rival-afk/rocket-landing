use rocket_landing_env::env::Lane;

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| "tape.json".to_string());
    let data = std::fs::read_to_string(&path).expect("read tape");
    let v: serde_json::Value = serde_json::from_str(&data).expect("parse");
    let tape: Vec<(bool, f64)> = v["inputs"].as_array().unwrap()
        .iter()
        .map(|x| (x["thrust"].as_bool().unwrap_or(false), x["torque"].as_f64().unwrap_or(0.0)))
        .collect();
    eprintln!("total ticks: {}", tape.len());
    let mut lane = Lane::new(0, 0);
    for (i, &(thrust, torque)) in tape.iter().enumerate() {
        let (_, terminated) = lane.step(thrust, torque, 1.0, "depth");
        if i >= 160 && i <= 240 {
            println!("tick={i:4} y={:.1} x={:.2} vx={:.1} vy={:.1} angle={:.1} thrust={} torque={:+.1}",
                lane.y, lane.x, lane.vx, lane.vy, lane.angle.to_degrees(), thrust, torque);
        }
        if terminated {
            println!("DIED at tick {i}, depth_m={:.2}", lane.max_depth);
            break;
        }
    }
}
