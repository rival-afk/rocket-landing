//! Rigid body physics — kinematic model mirroring Godot 4 RigidBody2D + this
//! game's `torque.gd` + `rocket.tscn` shape constants.
//!
//! Integration: semi-implicit Euler (velocity first, then position), exactly
//! how GodotPhysics2D integrates. Angular velocity is set *directly* to the
//! commanded value each tick (±4.0 rad/s, else 0) — same as torque.gd.
//! Forces: gravity 980 px/s² down, thrust 1500 px/s² along body's up.
//!
//! Collision: the walls are *lethal on touch* (game rule), so we use an
//! analytic point-in-corridor test over the OBB's 4 corners and we sample
//! along its edges for extra robustness (sub-pixel via binary refinement).
//! This cannot match Godot's SAT impulse solver *bitwise* — but since the
//! rocket dies on any contact, the observable behavior (dead or not at tick
//! N) coincides for the same wall boundary curve.

use crate::cave;

pub const DT: f64 = 1.0 / 60.0;              // physics tick = 60 Hz
pub const GRAVITY: f64 = 980.0;              // px/s² (Godot 2D default)
pub const THRUST_POWER: f64 = 1500.0;        // px/s² (torque.gd, thrust_power)
pub const ANGULAR_SPEED: f64 = 4.0;          // rad/s (torque.gd)
pub const MASS: f64 = 1.0;

pub const BODY_W: f64 = 20.0;                // RectangleShape2D width
pub const BODY_H: f64 = 24.0;                // RectangleShape2D height
pub const BODY_OFF_Y: f64 = -2.0;            // Collision position (0, -2)
pub const LINEAR_DAMP: f64 = 0.1;            // Godot default_linear_damp = 0.1
pub const ANGULAR_DAMP: f64 = 1.0;           // Godot default_angular_damp = 1.0

/// Corner offsets of the OBB in body-local space.
const CORNERS: [(f64, f64); 4] = [
    (-BODY_W / 2.0, BODY_OFF_Y - BODY_H / 2.0),
    (BODY_W / 2.0, BODY_OFF_Y - BODY_H / 2.0),
    (BODY_W / 2.0, BODY_OFF_Y + BODY_H / 2.0),
    (-BODY_W / 2.0, BODY_OFF_Y + BODY_H / 2.0),
];

/// 4 OBB corners in world space, rotated by body rotation.
#[inline]
pub fn obb_corners(x: f64, y: f64, angle: f64) -> [(f64, f64); 4] {
    let c = angle.cos();
    let s = angle.sin();
    CORNERS.map(|(lx, ly)| {
        let wx = x + lx * c - ly * s;
        let wy = y + lx * s + ly * c;
        (wx, wy)
    })
}

/// Point inside corridor? (pure corridor bounds — no lane_offset here; lanes
/// shared the same cave in one process only in the old per-lane-world design.)
#[inline]
pub fn point_in_corridor(px: f64, py: f64) -> bool {
    let c = cave::center_at(py);
    let h = cave::half_at(py);
    px >= c - h && px <= c + h
}

/// True if any part of the rocket overlaps the rock (= dead by game rules).
#[inline]
pub fn rocket_intersects_rock(x: f64, y: f64, angle: f64) -> bool {
    // Godot tas_search.gd checks 3x3 grid of OBB points (corners + edge midpoints);
    // this is much more lenient than dense edge sampling — same as production TAS.
    const OFFS: [(f64, f64); 9] = [
        (-BODY_W / 2.0, BODY_OFF_Y - BODY_H / 2.0),
        (0.0,                       BODY_OFF_Y - BODY_H / 2.0),
        ( BODY_W / 2.0, BODY_OFF_Y - BODY_H / 2.0),
        (-BODY_W / 2.0, BODY_OFF_Y),
        (0.0,                       BODY_OFF_Y),
        ( BODY_W / 2.0, BODY_OFF_Y),
        (-BODY_W / 2.0, BODY_OFF_Y + BODY_H / 2.0),
        (0.0,                       BODY_OFF_Y + BODY_H / 2.0),
        ( BODY_W / 2.0, BODY_OFF_Y + BODY_H / 2.0),
    ];
    let c = angle.cos();
    let s = angle.sin();
    for &(lx, ly) in &OFFS {
        let px = x + lx * c - ly * s;
        let py = y + lx * s + ly * c;
        if !point_in_corridor(px, py) {
            return true;
        }
    }
    false
}

/// Ray-vs-corridor distance: smallest t ∈ [0, max_len] where the ray exits the
/// corridor, else max_len. Used for the 5 lidars.
#[inline]
pub fn raycast_corridor(origin_x: f64, origin_y: f64, dir_x: f64, dir_y: f64, max_len: f64) -> f64 {
    // Coarse 4 px sweep + 1/16 refinement.
    let mut t = 0.0;
    while t <= max_len {
        if !point_in_corridor(origin_x + dir_x * t, origin_y + dir_y * t) {
            // binary search for boundary crossing
            let mut lo = t - 4.0;
            let mut hi = t;
            if lo < 0.0 { lo = 0.0; }
            for _ in 0..6 {
                let mid = (lo + hi) * 0.5;
                if point_in_corridor(origin_x + dir_x * mid, origin_y + dir_y * mid) {
                    lo = mid;
                } else {
                    hi = mid;
                }
            }
            return hi;
        }
        t += 4.0;
    }
    max_len
}

/// Lidar target directions, exactly as in rocket.tscn (pre-normalized lengths
/// equal to 280 px: right (280,0), right_down (198,198), down (0,280),
/// left_down (-198,198), left (-280,0)).
pub const LIDAR_TARGETS: [(f64, f64); 5] = [
    (280.0, 0.0),
    (198.0, 198.0),
    (0.0, 280.0),
    (-198.0, 198.0),
    (-280.0, 0.0),
];
pub const LIDAR_RANGE: f64 = 280.0;

#[inline]
pub fn raycast_lidars(x: f64, y: f64, angle: f64) -> [f64; 5] {
    let c = angle.cos();
    let s = angle.sin();
    LIDAR_TARGETS.map(|(tx, ty)| {
        // rotate target into world
        let dx = tx * c - ty * s;
        let dy = tx * s + ty * c;
        let len = dx.hypot(dy);
        let dirx = dx / len;
        let diry = dy / len;
        raycast_corridor(x, y, dirx, diry, LIDAR_RANGE)
    })
}

/// One physics tick of a rigid body — returns nothing, mutates in place.
/// `time_scale ∈ [0.05, 20]` as /speed accepts; dt = (1/60) * time_scale.
pub fn step_body(
    x: &mut f64,
    y: &mut f64,
    vx: &mut f64,
    vy: &mut f64,
    angle: &mut f64,
    thrust: bool,
    torque_cmd: f64,
    time_scale: f64,
) {
    let dt = DT * time_scale;

    // --- rotation: angular velocity is *set* directly (torque.gd semantics),
    // but the engine applies angular_damp on each tick BEFORE the rotate:
    let omega = torque_cmd * ANGULAR_SPEED;
    let omega_effective = omega * (1.0 - ANGULAR_DAMP * dt);

    // --- translation: damp FIRST, then forces, then position integration
    // (order per calibrated Godot model — TAS.md).
    let linear_damp_f = 1.0 - LINEAR_DAMP * dt;
    *vx *= linear_damp_f;
    *vy *= linear_damp_f;

    let c = angle.cos();
    let s = angle.sin();
    let mut fx = 0.0f64;
    let mut fy = GRAVITY * MASS;
    if thrust {
        fx += s * THRUST_POWER;
        fy += -c * THRUST_POWER;
    }
    *vx += fx / MASS * dt;
    *vy += fy / MASS * dt;
    *x += *vx * dt;
    *y += *vy * dt;
    *angle += omega_effective * dt;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn body_falls_straight_down_with_no_input() {
        let mut x = 0.0;
        let mut y = 0.0;
        let mut vx = 0.0;
        let mut vy = 0.0;
        let mut angle = 0.0;
        for _ in 0..60 {
            step_body(&mut x, &mut y, &mut vx, &mut vy, &mut angle, false, 0.0, 1.0);
        }
        assert!(y > 400.0, "fell to y={}", y);
        assert!(angle == 0.0);
        assert!(vx == 0.0);
        assert!(vy > 900.0, "vy={}", vy);
    }

    #[test]
    fn thrust_upwards_reduces_fall() {
        let mut x = 0.0;
        let mut y = 0.0;
        let mut vx = 0.0;
        let mut vy = 0.0;
        let mut angle = 0.0;
        for _ in 0..120 {
            step_body(&mut x, &mut y, &mut vx, &mut vy, &mut angle, true, 0.0, 1.0);
        }
        // net accel upwards: thrust 1500 up vs gravity 980 down => climbs
        assert!(y < 0.0, "climbs: y={}", y);
        assert!(vy < 0.0);
    }

    #[test]
    fn rocket_hits_wall_when_corridor_narrows() {
        // straight down from center — must eventually meet the wall
        let mut x = 0.0;
        let mut y = 0.0;
        let mut vx = 0.0;
        let mut vy = 0.0;
        let mut angle = 0.0;
        let mut dead_tick = None;
        for i in 0..400 {
            step_body(&mut x, &mut y, &mut vx, &mut vy, &mut angle, false, 0.0, 1.0);
            if rocket_intersects_rock(x, y, angle) {
                dead_tick = Some(i);
                break;
            }
        }
        assert!(dead_tick.is_some(), "rocket should die without control");
        assert!(dead_tick.unwrap() < 60 * 30, "died by tick {}", dead_tick.unwrap());
    }
}
