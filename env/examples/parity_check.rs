use rocket_landing_env::cave;
fn main() {
    for y in [-256.0, 0.0, 128.0, 300.0, 512.0, 1000.0, 10000.0] {
        println!("y={:.1} left={:.4} right={:.4} center={:.4} half={:.4}",
            y, cave::left_x(y), cave::right_x(y), cave::center_at(y), cave::half_at(y));
    }
}
