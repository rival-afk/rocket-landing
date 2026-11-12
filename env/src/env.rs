//! Lane (= one game) state machine — port of `game.gd`'s
//! `_physics_process`/`_on_lane_killed` scoring semantics.
//!
//! Score: signed depth meters `(y - spawn_y) / 50`; grows below spawn,
//! shrinks (can go negative) above it. `max_depth` is the historical max
//! (for records). Dead on wall touch (game rule). `time_scale` ∈ [0.05, 20].

use serde::Serialize;
use crate::rocket;

pub const PX_PER_METER: f64 = 50.0;
pub const SPAWN_Y: f64 = 0.0;
pub const BEST_PATH: &str = "user://rocket_landing_best.txt";
pub const MAX_TIME_SCALE: f64 = 20.0;
pub const MIN_TIME_SCALE: f64 = 0.05;

#[derive(Clone, Debug)]
pub struct Lane {
    pub id: u32,
    pub x: f64,
    pub y: f64,
    pub vx: f64,
    pub vy: f64,
    pub angle: f64,
    pub alive: bool,
    pub max_depth: f64,
    pub cur_depth: f64,
    pub tick: u32,
    pub spawn_tick: u32,
    pub dead_tick: Option<u32>,
    pub time_alive: f64,
    pub time_scale: f64,
    // scoring accumulators for the session stats panel
    pub session_best: f64,
    pub session_sum_score: f64,
    pub session_sum_time: f64,
    pub session_runs: u32,
    pub session_best_time: f64,
    pub session_last_run_time: f64,
    pub spawn_msec: std::time::Instant,
    pub global_best: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct LaneSnapshot {
    pub lane: u32,
    pub alive: bool,
    pub score: i64,
    pub depth_m: f64,
    pub vel_x: f64,
    pub vel_y: f64,
    pub speed: f64,
    pub position: [f64; 2],
    pub angle: f64,
    pub angle_vel: f64,
    pub thrust: bool,
    pub torque: f64,
    pub time_alive: f64,
    pub lidars: [f64; 5],
    pub best: u64,
    pub time_scale: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct SessionSnapshot {
    pub best: f64,
    pub avg: f64,
    pub runs: u32,
    pub avg_time_s: f64,
    pub best_time_s: f64,
    pub last_run_time_s: f64,
}

impl Lane {
    pub fn new(id: u32, global_best: u64) -> Self {
        Self {
            id,
            x: 0.0,
            y: SPAWN_Y,
            vx: 0.0,
            vy: 0.0,
            angle: 0.0,
            alive: true,
            max_depth: 0.0,
            cur_depth: 0.0,
            tick: 0,
            spawn_tick: 0,
            dead_tick: None,
            time_alive: 0.0,
            time_scale: 1.0,
            session_best: 0.0,
            session_sum_score: 0.0,
            session_sum_time: 0.0,
            session_runs: 0,
            session_best_time: 0.0,
            session_last_run_time: 0.0,
            spawn_msec: std::time::Instant::now(),
            global_best,
        }
    }

    /// Reset to spawn state — used by both reset() and respawn.
    pub fn reset_rocket(&mut self) {
        self.x = 0.0;
        self.y = SPAWN_Y;
        self.vx = 0.0;
        self.vy = 0.0;
        self.angle = 0.0;
        self.alive = true;
        self.max_depth = 0.0;
        self.cur_depth = 0.0;
        self.tick += 1;
        self.spawn_tick = self.tick;
        self.dead_tick = None;
        self.time_alive = 0.0;
        self.spawn_msec = std::time::Instant::now();
    }

    /// Advance one physics tick with the given inputs.
    /// Returns the reward for this tick (0.0 default policy
    /// when `reward_mode` = "depth": Δdepth; "survival": 1.0/step; "death": -100 on death).
    pub fn step(
        &mut self,
        thrust: bool,
        torque: f64,
        time_scale: f64,
        reward_mode: &str,
    ) -> (f64, bool) {
        let old_depth = self.cur_depth;

        rocket::step_body(&mut self.x, &mut self.y, &mut self.vx, &mut self.vy, &mut self.angle, thrust, torque, time_scale);
        self.tick += 1;
        self.time_alive =
            (self.tick - self.spawn_tick) as f64 / 60.0; // 60 Hz, tick-based (matches game)

        let depth = (self.y - SPAWN_Y) / PX_PER_METER;
        self.cur_depth = depth;
        if depth > self.max_depth {
            self.max_depth = depth;
        }

        if self.alive && rocket::rocket_intersects_rock(self.x, self.y, self.angle) {
            self.alive = false;
            self.dead_tick = Some(self.tick);
            // session stats
            let run_time = self.time_alive;
            self.session_last_run_time = run_time;
            if self.max_depth > self.session_best {
                self.session_best = self.max_depth;
            }
            self.session_sum_score += self.max_depth;
            self.session_sum_time += run_time;
            self.session_runs += 1;
            if run_time > self.session_best_time {
                self.session_best_time = run_time;
            }
            // global best (persisted file — same semantics as game)
            let best_score = self.max_depth as i64;
            if best_score > self.global_best as i64 {
                self.global_best = best_score as u64;
                let _ = std::fs::write("user_rocket_landing_best.txt", self.global_best.to_string());
                // user_rocket_landing_best.txt written next to exe if cwd writable
            }
            return (reward_for(reward_mode, old_depth, depth, true), true);
        }

        (reward_for(reward_mode, old_depth, depth, false), false)
    }

    pub fn snapshot(&self, thrust: bool, torque: f64) -> LaneSnapshot {
        let lidars = rocket::raycast_lidars(self.x, self.y, self.angle);
        LaneSnapshot {
            lane: self.id,
            alive: self.alive,
            score: self.cur_depth as i64,
            depth_m: self.cur_depth,
            vel_x: self.vx,
            vel_y: self.vy,
            speed: self.vx.hypot(self.vy),
            position: [self.x, self.y],
            angle: self.angle.to_degrees(),
            angle_vel: torque * rocket::ANGULAR_SPEED,
            thrust,
            torque: torque.clamp(-1.0, 1.0),
            time_alive: self.time_alive,
            lidars,
            best: self.global_best,
            time_scale: self.time_scale,
        }
    }

    pub fn session_snapshot(&self) -> SessionSnapshot {
        let runs = self.session_runs.max(1);
        SessionSnapshot {
            best: self.session_best,
            avg: self.session_sum_score / runs as f64,
            runs: self.session_runs,
            avg_time_s: self.session_sum_time / runs as f64,
            best_time_s: self.session_best_time,
            last_run_time_s: self.session_last_run_time,
        }
    }
}

fn reward_for(mode: &str, old_depth: f64, depth: f64, dead: bool) -> f64 {
    match mode {
        "depth" => depth - old_depth,                 // shape: progress per tick
        "survival" => if dead { 0.0 } else { 1.0 },   // +1 per tick alive
        "death" => if dead { -100.0 } else { depth - old_depth }, // sparse-ish hybrid
        "depth_clipped" => (depth - old_depth).clamp(-0.2, 0.2),
        _ => depth - old_depth,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lane_scores_and_dies() {
        let mut lane = Lane::new(0, 0);
        let mut dead_ticks = 0;
        for _ in 0..2000 {
            let (_, dead) = lane.step(false, 0.0, 1.0, "depth");
            if dead {
                dead_ticks += 1;
                break;
            }
        }
        assert!(dead_ticks == 1, "rocket must die without input");
        assert!(lane.max_depth > 1.0, "depth={}", lane.max_depth);
    }

    #[test]
    fn signed_depth_can_go_negative() {
        let mut lane = Lane::new(0, 0);
        for _ in 0..60 {
            lane.step(true, 0.0, 1.0, "depth");
        }
        assert!(lane.cur_depth < 0.0, "climbing above spawn must be negative depth");
    }
}
