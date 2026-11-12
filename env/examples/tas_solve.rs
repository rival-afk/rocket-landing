use rocket_landing_env::tas;

fn main() {
    let beam: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(64);
    let max_ticks: u32 = std::env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(1500);
    let speed_weight: f64 = std::env::args().nth(3).and_then(|s| s.parse().ok()).unwrap_or(0.0);
    let vy_cap: f64 = std::env::args().nth(4).and_then(|s| s.parse().ok()).unwrap_or(235.0);
    let cfg = tas::TasSolveConfig {
        beam_width: beam,
        max_ticks,
        wall_margin: 14.0,
        wall_penalty: 0.002,
        speed_weight,
        vy_cap,
        goal_depth_m: None,
    };
    let t0 = std::time::Instant::now();
    let res = tas::solve(cfg);
    let dt = t0.elapsed();
    println!(
        "final_depth_m={:.2} ticks={} survived={} beam={} max_ticks={} time={:.1}s",
        res.final_depth_m, res.ticks, res.survived, beam, max_ticks, dt.as_secs_f64()
    );
    let rows: Vec<Vec<serde_json::Value>> = res.tape.iter()
        .map(|&(t, tq)| vec![serde_json::json!(t), serde_json::json!(tq)])
        .collect();
    let s = serde_json::to_string(&rows).unwrap_or_default();
    std::fs::write("tas_tape.json", s).expect("write tas_tape.json");
    println!("wrote tas_tape.json ({} bytes)", std::fs::metadata("tas_tape.json").map(|m| m.len()).unwrap_or(0));
}
