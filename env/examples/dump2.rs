use rocket_landing_env::cave;

fn main() {
    let y0: f64 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(2800.0);
    let y1: f64 = std::env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(3500.0);
    let step: f64 = std::env::args().nth(3).and_then(|s| s.parse().ok()).unwrap_or(16.0);
    let mut y = y0;
    while y <= y1 {
        println!(
            "y={:6.1} center={:9.2} half={:6.2} L={:9.2} R={:9.2}",
            y, cave::center_at(y), cave::half_at(y),
            cave::center_at(y) - cave::half_at(y),
            cave::center_at(y) + cave::half_at(y)
        );
        y += step;
    }
}
