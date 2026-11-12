fn main() {
    // покажем коридор каждые 50 px глубины в пределах 0..600
    for y in (0..=12).map(|i| i as f64 * 50.0) {
        println!("y={:.1} center={:.1} half={:.1} left={:.1} right={:.1} width={:.1}",
            y,
            rocket_landing_env::cave::center_at(y),
            rocket_landing_env::cave::half_at(y),
            rocket_landing_env::cave::left_x(y),
            rocket_landing_env::cave::right_x(y),
            2.0 * rocket_landing_env::cave::half_at(y)
        );
    }
}
