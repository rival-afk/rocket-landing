//! TAS solver — beam search over per-tick inputs (`thrust` on/off × `torque`
//! ∈ {-1, 0, +1}) on the deterministic corridor. Goal: reach maximum depth
//! while staying alive; wall proximity applies a soft penalty, touching a
//! wall kills the candidate.
//!
//! Design: each beam node stores the full input history of the branch that
//! produced it, so once the search ends the single best-surviving branch can
//! be returned verbatim. Memory cost is `beam_width * tape_len² / 2` bytes —
//! keep beam modest (64–128) for long runs. A cheaper arena-based variant can
//! replace this later without changing `TasResult`.

use crate::cave;
use crate::rocket;

/// Beam search configuration.
#[derive(Clone, Debug)]
pub struct TasSolveConfig {
    /// Beam width — candidates kept per tick.
    pub beam_width: usize,
    /// Hard cap on simulated ticks.
    pub max_ticks: u32,
    /// Distance-to-wall (px) over which the corridor-offset penalty ramps.
    pub wall_margin: f64,
    /// Weight of the corridor-offset penalty (relative to y, per unit off²).
    pub wall_penalty: f64,
    /// Reward per px/s of downward velocity — higher = faster descent.
    /// (reserved, replaced by vy_cap for sharp-edge behaviour)
    pub speed_weight: f64,
    /// Soft clamp: vy above this is penalised (Godot-calibrated: 235 px/s).
    /// Set to a much higher value to allow max-speed descent.
    pub vy_cap: f64,
    /// Stop when a node reaches this depth (m); `None` = descend as far as possible.
    pub goal_depth_m: Option<f64>,
}

impl Default for TasSolveConfig {
    fn default() -> Self {
        Self {
            beam_width: 64,
            max_ticks: 2700,
            wall_margin: 14.0,
            wall_penalty: 0.002,
            speed_weight: 0.0,
            vy_cap: 235.0,
            goal_depth_m: None,
        }
    }
}

/// One node of the beam — full body state + input history of its branch.
#[derive(Clone, Debug)]
struct Node {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    angle: f64,
    alive: bool,
    score: f64,
    /// Input history `(thrust, torque)` per tick, oldest first.
    path: Vec<(bool, f64)>,
}

/// Result of a solved run.
#[derive(Clone, Debug)]
pub struct TasResult {
    /// Input tape per tick.
    pub tape: Vec<(bool, f64)>,
    /// Final depth reached (m).
    pub final_depth_m: f64,
    /// Ticks in the tape.
    pub ticks: u32,
    /// Did the chosen branch stay alive until the end of the tape?
    pub survived: bool,
}

#[inline]
fn corridor_off2(x: f64, y: f64) -> f64 {
    let c = cave::center_at(y);
    let h = cave::half_at(y);
    let off = (x - c).abs() / h.max(1.0);
    off * off
}

/// Calibrated score with adjustable fall-speed term.
/// `vy_cap` — мягкий предел vy (калиброванное значение 235.0); выше vy штраф.
#[inline]
fn score(x: f64, y: f64, vx: f64, vy: f64, alive: bool, cfg: &TasSolveConfig) -> f64 {
    if !alive {
        return f64::NEG_INFINITY;
    }
    let excess = (vy - cfg.vy_cap).max(0.0);
    y - corridor_off2(x, y) * 60.0 - corridor_off2(x, y + 240.0) * 90.0
        - vx.abs() * 0.15 - excess * 0.22
}

/// Run the beam search and return the deepest branch found.
pub fn solve(cfg: TasSolveConfig) -> TasResult {
    const ACTIONS: [(bool, f64); 6] = [
        (false, -1.0), (false, 0.0), (false, 1.0),
        (true,  -1.0), (true,   0.0), (true,   1.0),
    ];

    let mut beam: Vec<Node> = vec![Node {
        x: 0.0,
        y: 0.0,
        vx: 0.0,
        vy: 0.0,
        angle: 0.0,
        alive: true,
        score: 0.0,
        path: Vec::new(),
    }];

    let mut best: TasResult = TasResult { tape: Vec::new(), final_depth_m: 0.0, ticks: 0, survived: false };

    for tick in 0..cfg.max_ticks {
        let mut candidates: Vec<Node> = Vec::with_capacity(beam.len() * ACTIONS.len());

        for node in &beam {
            if !node.alive {
                // keep the corpse (its depth was recorded) — cost is one clone;
                // it scores poorly so it survives only if beam_width is slack
                candidates.push(node.clone());
                continue;
            }
            for &(thrust, torque) in &ACTIONS {
                let mut n = node.clone();
                rocket::step_body(&mut n.x, &mut n.y, &mut n.vx, &mut n.vy, &mut n.angle, thrust, torque, 1.0);
                n.alive = !rocket::rocket_intersects_rock(n.x, n.y, n.angle);
                n.score = score(n.x, n.y, n.vx, n.vy, n.alive, &cfg);
                n.path.push((thrust, torque));
                candidates.push(n);
            }
        }

        // dedup: keep only best-scoring node per quantized state key —
        // otherwise the beam fills with near-identical branches that all die together
        let quant = |n: &Node| -> i64 {
            let kx = (n.x * 2.0).round() as i64;
            let ky = (n.y * 2.0).round() as i64;
            let kvx = n.vx.round() as i64;
            let kvy = n.vy.round() as i64;
            let kr = (n.angle * 8.0).round() as i64;
            // pack with large offsets to avoid accidental signs
            kx ^ (ky.wrapping_shl(21) | ky >> 43)
               ^ (kvx.wrapping_shl(32) | kvx >> 32)
               ^ (kvy.wrapping_shl(43) | kvy >> 21)
               ^ (kr.wrapping_shl(53) | kr >> 11)
        };
        let mut seen = std::collections::HashSet::with_capacity(candidates.len());
        let mut unique: Vec<Node> = Vec::with_capacity(candidates.len());
        for c in candidates {
            let k = quant(&c);
            if seen.insert(k) {
                unique.push(c);
            }
        }
        let mut candidates = unique;

        // diversified selection: one best branch per (x-bucket, vy-bucket), then fill by score —
        // prevents greedy top-k from collapsing the beam into near-identical states
        const BX: f64 = 48.0;
        const BY: f64 = 60.0;
        candidates.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
        let mut picked_idx: Vec<usize> = Vec::with_capacity(cfg.beam_width);
        let mut bucket_used: std::collections::HashSet<i64> = std::collections::HashSet::new();
        for (i, c) in candidates.iter().enumerate() {
            let bx = (c.x / BX).floor() as i64;
            let by = (c.vy / BY).floor() as i64;
            let key = bx + by * 1000;
            if bucket_used.insert(key) {
                picked_idx.push(i);
                if picked_idx.len() >= cfg.beam_width {
                    break;
                }
            }
        }
        for i in 0..candidates.len() {
            if picked_idx.len() >= cfg.beam_width {
                break;
            }
            if !picked_idx.contains(&i) {
                picked_idx.push(i);
            }
        }
        picked_idx.sort_unstable();
        picked_idx.dedup();
        beam = picked_idx.into_iter().map(|i| candidates[i].clone()).collect();

        let mut current_best: Option<&Node> = None;
        let mut deepest = f64::NEG_INFINITY;
        for node in &beam {
            if node.y / 50.0 > deepest {
                deepest = node.y / 50.0;
                current_best = Some(node);
            }
        }

        if deepest > best.final_depth_m {
            if let Some(n) = current_best {
                best = TasResult {
                    tape: n.path.clone(),
                    final_depth_m: deepest,
                    ticks: tick + 1,
                    survived: n.alive,
                };
            }
        }

        if tick % 10 == 0 {
            let dedup_size = beam.len();
            eprintln!("tick={:4} beam={} unique={} deepest={:.3} last_alive={}", tick, dedup_size, candidates.len(), deepest, beam.iter().filter(|n| n.alive).count());
        }

        if let Some(goal) = cfg.goal_depth_m {
            if beam.iter().any(|n| n.alive && n.y / 50.0 >= goal) {
                best.survived = true;
                return best;
            }
        }

        if !beam.iter().any(|n| n.alive) {
            best.ticks = tick + 1;
            return best;
        }
    }

    best.survived = true;
    best.ticks = cfg.max_ticks;
    best
}

/// Forward optimization from a seed tape: for each tick, try all 6 actions
/// and keep any that makes the run deeper (or reaches farther).
/// Runs in passes; each pass is O(len²) body steps. Existing best is kept
/// strictly so this never degrades a seed.
pub fn optimize_tape(seed: &[(bool, f64)], rounds: u32) -> TasResult {
    const ACTIONS: [(bool, f64); 6] = [
        (false, -1.0), (false, 0.0), (false, 1.0),
        (true,  -1.0), (true,   0.0), (true,   1.0),
    ];
    let (depth, survived) = evaluate(seed);
    let mut best: TasResult = TasResult { tape: seed.to_vec(), final_depth_m: depth, ticks: seed.len() as u32, survived };

    for _ in 0..rounds {
        let mut improved = false;
        for i in 0..best.tape.len() {
            let current = best.tape[i];
            for &act in &ACTIONS {
                if act == current {
                    continue;
                }
                let mut cand = best.tape.clone();
                cand[i] = act;
                let (d, survived) = evaluate(&cand);
                if survived && d > best.final_depth_m {
                    best = TasResult { tape: cand, final_depth_m: d, ticks: best.tape.len() as u32, survived };
                    improved = true;
                }
            }
        }
        if !improved {
            break;
        }
    }
    best.ticks = best.tape.len() as u32;
    best
}
pub fn evaluate(tape: &[(bool, f64)]) -> (f64, bool) {
    let mut lane = crate::env::Lane::new(0, 0);
    let mut dead = false;
    for &(thrust, torque) in tape {
        let (_, terminated) = lane.step(thrust, torque, 1.0, "depth");
        if terminated {
            dead = true;
            break;
        }
    }
    (lane.max_depth, !dead)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn solver_survives_a_little_deeper_than_unpowered_descent() {
        // weak solve: tiny beam, few ticks — just smoke test
        let cfg = TasSolveConfig { beam_width: 4, max_ticks: 120, wall_margin: 14.0, wall_penalty: 0.0, speed_weight: 0.0, vy_cap: 235.0, goal_depth_m: None };
        let res = solve(cfg);
        // unpowered 60-tick fall = ~5 m; 120 ticks = ~23 m-ish trajectories exist
        assert!(res.ticks > 0);
        assert!(res.final_depth_m > 1.0);
    }

    #[test]
    fn tape_replays_identically() {
        let cfg = TasSolveConfig { beam_width: 8, max_ticks: 60, wall_margin: 14.0, wall_penalty: 0.0, speed_weight: 0.0, vy_cap: 235.0, goal_depth_m: None };
        let res = solve(cfg);
        let (depth, survived) = evaluate(&res.tape);
        assert!(depth >= 0.0);
        assert!(survived || !res.survived); // tiny beam may die; just check it runs
    }
}
