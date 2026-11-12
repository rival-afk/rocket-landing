// WGSL compute kernel — one invocation per lane per physics tick.
// Mirrors the CPU physics step exactly: semi-implicit Euler, gravity 980,
// thrust 1500 along body up, angular_velocity = torque * 4.0 set directly,
// analytic corridor check via sin + fract (same cave hash as cave_walls.gdshader).
//
// NOTE: sin() ULP behavior differs between libm (CPU) and GPU drivers. Corridor
// shape matches to ~1e-6; wall-contact tick may differ by exactly one tick at
// worst. Acceptable for mass-scale RL rollouts.

struct Lane {
    pos_x: f32,
    pos_y: f32,
    vel_x: f32,
    vel_y: f32,
    angle: f32,
    alive: f32,
    max_depth: f32,
    cur_depth: f32,
    tick: u32,
    spawn_tick: u32,
    _pad0: u32,
    _pad1: u32,
    time_alive: f32,
    time_scale: f32,
    session_best: f32,
    session_sum_score: f32,
    session_sum_time: f32,
    session_runs: f32,
    session_best_time: f32,
    _pad2: f32,
};

struct Input {
    thrust: f32,
    torque: f32,
};

@group(0) @binding(0) var<storage, read_write> lanes: array<Lane>;
@group(0) @binding(1) var<storage, read> inputs: array<Input>;

const KNOT: f32 = 256.0;
const MIN_HALF: f32 = 60.0;
const HALF_VAR: f32 = 55.0;
const MAX_SHIFT: f32 = 175.0;
const GRAVITY: f32 = 980.0;
const THRUST: f32 = 1500.0;
const ANGULAR: f32 = 4.0;
const ANGULAR_DAMP: f32 = 1.0;   // Godot default_angular_damp = 1.0
const LINEAR_DAMP: f32 = 0.1;    // Godot default_linear_damp = 0.1
const BODY_W: f32 = 20.0;
const BODY_H: f32 = 24.0;
const BODY_OFF_Y: f32 = -2.0;
const PX_PER_M: f32 = 50.0;
const DT: f32 = 1.0 / 60.0;

fn cave_hash(n: f32) -> f32 {
    let s = sin(n * 127.1 + 311.7) * 43758.5453;
    return s - floor(s);
}

fn knot_offset(k: f32) -> f32 {
    if (k == 0.0) {
        return 0.0;
    }
    return (cave_hash(k) * 2.0 - 1.0) * MAX_SHIFT;
}

fn knot_half(k: f32) -> f32 {
    return MIN_HALF + cave_hash(k + 1000.0) * HALF_VAR;
}

fn center_at(y: f32) -> f32 {
    let k: f32 = floor(y / KNOT);
    let t: f32 = (y - k * KNOT) / KNOT;
    let v: f32 = mix(knot_offset(k), knot_offset(k + 1.0), t);
    let ramp: f32 = clamp(abs(y) / (3.0 * KNOT), 0.0, 1.0);
    return v * ramp;
}

fn half_at(y: f32) -> f32 {
    let k: f32 = floor(y / KNOT);
    let t: f32 = (y - k * KNOT) / KNOT;
    return mix(knot_half(k), knot_half(k + 1.0), t);
}

fn point_in_corridor(px: f32, py: f32) -> bool {
    let c: f32 = center_at(py);
    let h: f32 = half_at(py);
    return px >= c - h && px <= c + h;
}

fn rocket_intersects_rock(x: f32, y: f32, angle: f32) -> bool {
    let c: f32 = cos(angle);
    let s: f32 = sin(angle);
    // 4 obb corners in local space: (+-10, -2 +- 12)
    var lx: array<f32, 4>;
    var ly: array<f32, 4>;
    lx[0] = -BODY_W * 0.5; ly[0] = BODY_OFF_Y - BODY_H * 0.5;
    lx[1] =  BODY_W * 0.5; ly[1] = BODY_OFF_Y - BODY_H * 0.5;
    lx[2] =  BODY_W * 0.5; ly[2] = BODY_OFF_Y + BODY_H * 0.5;
    lx[3] = -BODY_W * 0.5; ly[3] = BODY_OFF_Y + BODY_H * 0.5;
    var corners: array<vec2f, 4>;
    for (var i: i32 = 0; i < 4; i = i + 1) {
        let wx: f32 = x + lx[i] * c - ly[i] * s;
        let wy: f32 = y + lx[i] * s + ly[i] * c;
        corners[i] = vec2f(wx, wy);
        if (!point_in_corridor(wx, wy)) {
            return true;
        }
    }
    // edges at ~2px granularity
    for (var i: i32 = 0; i < 4; i = i + 1) {
        let a: vec2f = corners[i];
        let b: vec2f = corners[(i + 1) % 4];
        let e: vec2f = b - a;
        let len: f32 = length(e);
        let steps: i32 = i32(ceil(len / 2.0));
        for (var s: i32 = 0; s <= steps; s = s + 1) {
            let t: f32 = f32(s) / f32(steps);
            let p: vec2f = a + e * t;
            if (!point_in_corridor(p.x, p.y)) {
                return true;
            }
        }
    }
    return false;
}

@compute @workgroup_size(64)
fn step_lanes(@builtin(global_invocation_id) gid: vec3u) {
    let i: u32 = gid.x;
    if (i >= arrayLength(&lanes)) { return; }
    var ln: Lane = lanes[i];
    if (ln.alive < 0.5) { return; }

    let inp: Input = inputs[i];
    let dt: f32 = DT * ln.time_scale;

    // direct angular velocity set (torque.gd semantics)
    let omega: f32 = clamp(inp.torque, -1.0, 1.0) * ANGULAR;
    let omega_eff: f32 = omega * (1.0 - ANGULAR_DAMP * dt);

    // damp FIRST, then forces, then position (engine order, TAS.md)
    let lin_damp: f32 = 1.0 - LINEAR_DAMP * dt;
    ln.vel_x = ln.vel_x * lin_damp;
    ln.vel_y = ln.vel_y * lin_damp;

    let cf: f32 = cos(ln.angle);
    let sf: f32 = sin(ln.angle);
    var fx: f32 = 0.0;
    var fy: f32 = GRAVITY;
    if (inp.thrust > 0.5) {
        // "UP" rotated by angle => (sin, -cos)
        fx = sf * THRUST;
        fy = fy - cf * THRUST;
    }
    ln.vel_x = ln.vel_x + fx * dt;
    ln.vel_y = ln.vel_y + fy * dt;
    ln.pos_x = ln.pos_x + ln.vel_x * dt;
    ln.pos_y = ln.pos_y + ln.vel_y * dt;
    ln.angle = ln.angle + omega_eff * dt;
    ln.tick = ln.tick + 1u;
    ln.time_alive = f32(ln.tick - ln.spawn_tick) / 60.0;

    let depth: f32 = (ln.pos_y - 0.0) / PX_PER_M;
    ln.cur_depth = depth;
    if (depth > ln.max_depth) {
        ln.max_depth = depth;
    }

    if (rocket_intersects_rock(ln.pos_x, ln.pos_y, ln.angle)) {
        ln.alive = 0.0;
        let run_time: f32 = ln.time_alive;
        if (ln.max_depth > ln.session_best) {
            ln.session_best = ln.max_depth;
        }
        ln.session_sum_score = ln.session_sum_score + ln.max_depth;
        ln.session_sum_time = ln.session_sum_time + run_time;
        ln.session_runs = ln.session_runs + 1.0;
        if (run_time > ln.session_best_time) {
            ln.session_best_time = run_time;
        }
    }

    lanes[i] = ln;
}
