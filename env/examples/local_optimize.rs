//! Local optimizer from a known-good tape — walks tick by tick, trying all
//! 6 actions; keeps any that reaches deeper. Prints progress every 100 ticks.

use rocket_landing_env::tas;

fn main() {
    let seed_path = std::env::args().nth(1).expect("seed tape.json");
    let rounds: u32 = std::env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(2);
    let data = std::fs::read_to_string(&seed_path).expect("read tape");
    let v: serde_json::Value = serde_json::from_str(&data).expect("parse tape");
    let seed: Vec<(bool, f64)> = v["inputs"].as_array().unwrap_or(&vec![])
        .iter()
        .map(|x| (x["thrust"].as_bool().unwrap_or(false), x["torque"].as_f64().unwrap_or(0.0)))
        .collect::<Vec<_>>();

    let (d0, survived0) = tas::evaluate(&seed);
    eprintln!("seed: depth={:.2} survived={survived0} len={}", d0, seed.len());

    let t0 = std::time::Instant::now();
    let res = tas::optimize_tape(&seed, rounds);
    let dt = t0.elapsed();
    eprintln!(
        "opt: depth={:.2} m ticks={} survived={} time={:.1}s",
        res.final_depth_m, res.ticks, res.survived, dt.as_secs_f64()
    );

    let out = serde_json::json!({
        "final_depth_m": res.final_depth_m,
        "ticks": res.ticks,
        "survived": res.survived,
        "version": 1,
        "engine": "env-optimize",
        "inputs": res.tape.iter().map(|&(t, q)| {
            serde_json::json!({"thrust": t, "torque": q})
        }).collect::<Vec<_>>(),
    });
    let out_path = std::env::args().nth(3).unwrap_or_else(|| "env_tape.json".to_string());
    std::fs::write(&out_path, serde_json::to_string_pretty(&out).unwrap()).expect("write tape");
    eprintln!("wrote {}", out_path);
}
