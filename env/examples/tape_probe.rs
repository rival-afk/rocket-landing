use rocket_landing_env::env::Lane;

fn main() {
    // stretch the 60.12 m rope past its end — same actions, see if it keeps alive
    let path = std::env::args().nth(1).unwrap_or_else(|| "tape.json".to_string());
    let data = std::fs::read_to_string(&path).expect("read tape");
    let v: serde_json::Value = serde_json::from_str(&data).expect("parse");
    let tape: Vec<(bool, f64)> = v["inputs"].as_array().unwrap()
        .iter()
        .map(|x| (x["thrust"].as_bool().unwrap_or(false), x["torque"].as_f64().unwrap_or(0.0)))
        .collect();
    println!("tape len: {}", tape.len());
    let mut lane = Lane::new(0, 0);
    for (i, &(thrust, torque)) in tape.iter().enumerate() {
        let (_, terminated) = lane.step(thrust, torque, 1.0, "depth");
        if terminated {
            println!("died at tick {} y={:.1} depth={:.2} m", i, lane.y, lane.max_depth);
            return;
        }
    }
    println!("survived 791 tape ticks, y={:.1} depth_m={:.1}", lane.y, lane.max_depth);

    // replay rope cyclically (indistinguishable from what a constant loop would do) — see if it hits stop corridor
    for i in 0..6000 {
        let (thrust, torque) = tape[i % tape.len()];
        let (_, terminated) = lane.step(thrust, torque, 1.0, "depth");
        if i % 200 == 0 {
            println!("tick={} y={:.1} depth_m={:.1} vy={:.1}", i, lane.y, lane.max_depth, lane.vy);
        }
        if terminated {
            println!("cyclic died at tick {} y={:.1} depth={:.2} m", i, lane.y, lane.max_depth);
            return;
        }
    }
    println!("cyclic survived, y={:.1} depth={:.2} m", lane.y, lane.max_depth);
}
