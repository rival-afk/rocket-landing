//! CPU batch simulation — rayon-parallel lanes.
//!
//! Each lane is independent, so `step_many` scales linearly with cores.
//! For thousands of lanes the GPU backend (feature `gpu`) keeps the CPU free.

use rayon::prelude::*;
use crate::env::{Lane, LaneSnapshot};

pub struct Batch {
    pub lanes: Vec<Lane>,
    /// snapshot time base — not needed, each lane carries it
    pub best: u64,
}

impl Batch {
    pub fn new(n: usize, best: u64) -> Self {
        Self {
            lanes: (0..n as u32).map(|id| Lane::new(id, best)).collect(),
            best,
        }
    }

    /// Step all lanes in parallel. `actions[i] = (thrust, torque)`.
    /// Returns (snapshots, rewards, terminated, alive_mask).
    pub fn step_many(
        &mut self,
        actions: &[(bool, f64)],
        time_scale: f64,
        reward_mode: &str,
    ) -> (Vec<LaneSnapshot>, Vec<f64>, Vec<bool>) {
        let n = self.lanes.len().min(actions.len());

        let results: Vec<(f64, bool)> = self
            .lanes
            .par_iter_mut()
            .take(n)
            .zip(actions.par_iter())
            .map(|(lane, &(thrust, torque))| lane.step(thrust, torque, time_scale, reward_mode))
            .collect();

        let (rewards, dones): (Vec<f64>, Vec<bool>) = results.into_iter().unzip();

        let snaps: Vec<LaneSnapshot> = self
            .lanes
            .iter()
            .take(n)
            .zip(actions.iter())
            .map(|(lane, &(thrust, torque))| lane.snapshot(thrust, torque))
            .collect();

        (snaps, rewards, dones)
    }

    pub fn reset_many(&mut self) {
        for lane in &mut self.lanes {
            lane.reset_rocket();
        }
    }
}
