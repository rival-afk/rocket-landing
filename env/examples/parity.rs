use rocket_landing_env::cave;

fn main() {
    for y in [0.0_f64, 128.0, -512.0, 300.0, 2000.0, 10000.0] {
        println!(
            "y={:.1} left={:.3} right={:.3} half={:.3} center={:.3} hash0={:.3} offset1={:.3}",
            y,
            cave::left_x(y),
            cave::right_x(y),
            cave::half_at(y),
            cave::center_at(y),
            cave::cave_hash(0.0),
            cave::knot_offset(1.0)
        );
    }
}
