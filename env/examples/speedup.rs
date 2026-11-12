//! Фаза 2: ускорить готовую ленту.
//! Идём по тикам (тот порядок, в котором они лёгкие на старте) и для тех тиков,
//! где в ленте стоит thrust=true, пробуем заменить его на thrust=false и
//! проверяем, что лента по-прежнему выживает и не становится заметно мельче.
use rocket_landing_env::tas;

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| "seed.json".to_string());
    let data = std::fs::read_to_string(&path).expect("read tape");
    let v: serde_json::Value = serde_json::from_str(&data).expect("parse");
    let seed: Vec<(bool, f64)> = v["inputs"].as_array().unwrap()
        .iter()
        .map(|x| (x["thrust"].as_bool().unwrap_or(false), x["torque"].as_f64().unwrap_or(0.0)))
        .collect();

    let depth0 = tas::evaluate(&seed).0;
    println!("seed: len={} depth={:.2} m", seed.len(), depth0);

    let t0 = std::time::Instant::now();
    let mut tape = seed.clone();
    let mut improved = 0u32;

    // 1) убрать thrust где можно — ракета падает быстрее
    for i in 0..tape.len() {
        if !tape[i].0 { continue; }
        let mut cand = tape.clone();
        cand[i].0 = false;
        let (d, survived) = tas::evaluate(&cand);
        if survived && d >= depth0 * 0.95 {   // даём небольшую просадку
            tape = cand;
            improved += 1;
        }
    }
    println!("phase 1 (drop thrust): {:.2} m, {improved} ticks freed, time={:.2}s", tas::evaluate(&tape).0, t0.elapsed().as_secs_f64());

    // 2) затем изри.тарить каждый тик не-значительно (±1 torque), если не умирает
    for i in 0..tape.len() {
        for &cand in &[(true, 1.0f64), (true, -1.0), (false, 1.0), (false, -1.0), (false, 0.0)] {
            if tape[i] == cand { continue; }
            let mut trial = tape.clone();
            trial[i] = cand;
            let (d, survived) = tas::evaluate(&trial);
            if survived && d >= depth0 * 0.95 {
                tape = trial;
                improved += 1;
            }
        }
    }
    println!("phase 2 (vary actions): {:.2} m, total improvements={improved}, time={:.2}s", tas::evaluate(&tape).0, t0.elapsed().as_secs_f64());

    let final_depth = tas::evaluate(&tape).0;
    let out = serde_json::json!({
        "inputs": tape.iter().map(|&(t, q)| serde_json::json!({ "thrust": t, "torque": q })).collect::<Vec<_>>(),
        "final_depth_m": final_depth,
        "ticks": tape.len(),
        "survived": true,
    });
    let out_path = std::env::args().nth(2).unwrap_or_else(|| "tape_faster.json".to_string());
    std::fs::write(&out_path, serde_json::to_string(&out).unwrap()).unwrap();
    println!("wrote {out_path} ({:.2} m, {} ticks)", final_depth, tape.len());
}
