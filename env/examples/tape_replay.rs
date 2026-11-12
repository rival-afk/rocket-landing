use rocket_landing_env::env::Lane;
use rocket_landing_env::tas;

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| "ai/tas/tape.json".to_string());
    let data = std::fs::read_to_string(&path).expect("read tape.json");
    let v: serde_json::Value = serde_json::from_str(&data).expect("parse tape.json");
    let tape: Vec<(bool, f64)> = v["inputs"].as_array().unwrap_or(&vec![])
        .iter()
        .map(|x| (x["thrust"].as_bool().unwrap_or(false), x["torque"].as_f64().unwrap_or(0.0)))
        .collect();
    println!("inputs: {}, final_depth_m (claimed): {:?}", tape.len(), v["final_depth_m"]);

    let mut lane = Lane::new(0, 0);
    let mut dead_tick = None;
    for (i, &(thrust, torque)) in tape.iter().enumerate() {
        let (_, terminated) = lane.step(thrust, torque, 1.0, "depth");
        if terminated {
            dead_tick = Some(i);
            break;
        }
    }
    match dead_tick {
        Some(i) => println!("DIED at tick {i}/{}, depth_m={:.3}", tape.len(), lane.max_depth),
        None => println!("survived {tape_len} inputs, depth_m={:.3}", lane.max_depth, tape_len = tape.len()),
    }
}
