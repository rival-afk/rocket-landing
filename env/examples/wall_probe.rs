use rocket_landing_env::cave;

fn main() {
    for y in (0..=6000i32).map(|i| i as f64 * 32.0) {
        let l = cave::left_x(y);
        let r = cave::right_x(y);
        println!("y={:>5.1} left={:>8.3} right={:>8.3} center={:>8.3} half={:>8.3} width={:>8.2}",
            y, l, r, cave::center_at(y), cave::half_at(y), r - l);
    }
}
