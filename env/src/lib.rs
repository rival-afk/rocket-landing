//! PyO3 bindings for Rocket Landing — gym-style environment.
//!
//! ```python
//! import rocket_landing_env as rl
//! env = rl.RocketEnv()
//! obs = env.reset()
//! obs, reward, terminated, truncated, info = env.step([1.0, 0.0])
//! bench = rl.BatchEnv(512, backend="gpu")   # or backend="cpu"
//! out = bench.step([[1.0, 0.0]] * 512)
//! ```

pub mod batch;
pub mod cave;
pub mod env;
pub mod gpu;
pub mod rocket;
pub mod tas;

#[cfg(feature = "python")]
mod py {
    use pyo3::prelude::*;
    use pyo3::types::{PyDict, PyList};
    use crate::batch::Batch;
    use crate::env::{Lane, MAX_TIME_SCALE, MIN_TIME_SCALE, PX_PER_METER};
    use crate::gpu::{init as gpu_init, GpuInput};

    fn lane_dict(py: Python, lane: &Lane, thrust: bool, torque: f64) -> PyResult<Py<PyDict>> {
        let snap = lane.snapshot(thrust, torque);
        let lidars = snap.lidars;
        let d = PyDict::new_bound(py);
        d.set_item("lane", snap.lane)?;
        d.set_item("alive", snap.alive)?;
        d.set_item("score", snap.score)?;
        d.set_item("depth_m", snap.depth_m)?;
        d.set_item("vel_x", snap.vel_x)?;
        d.set_item("vel_y", snap.vel_y)?;
        d.set_item("speed", snap.speed)?;
        let position = PyDict::new_bound(py);
        position.set_item("x", snap.position[0])?;
        position.set_item("y", snap.position[1])?;
        d.set_item("position", position)?;
        d.set_item("angle", snap.angle)?;
        d.set_item("angle_vel", snap.angle_vel)?;
        d.set_item("thrust", snap.thrust)?;
        d.set_item("torque", snap.torque)?;
        d.set_item("time_alive", snap.time_alive)?;
        let lidard = PyDict::new_bound(py);
        lidard.set_item("right", lidars[0])?;
        lidard.set_item("right_down", lidars[1])?;
        lidard.set_item("down", lidars[2])?;
        lidard.set_item("left_down", lidars[3])?;
        lidard.set_item("left", lidars[4])?;
        d.set_item("lidars", lidard)?;
        d.set_item("best", snap.best)?;
        d.set_item("time_scale", snap.time_scale)?;
        d.set_item("best_depth_m", lane.max_depth)?;
        d.set_item("session", session_dict(py, lane)?)?;
        Ok(d.unbind())
    }

    fn session_dict(py: Python, lane: &Lane) -> PyResult<Py<PyDict>> {
        let s = lane.session_snapshot();
        let d = PyDict::new_bound(py);
        d.set_item("best", s.best)?;
        d.set_item("avg", s.avg)?;
        d.set_item("runs", s.runs)?;
        d.set_item("avg_time_s", s.avg_time_s)?;
        d.set_item("best_time_s", s.best_time_s)?;
        d.set_item("last_run_time_s", s.last_run_time_s)?;
        Ok(d.unbind())
    }

    fn info_dict(py: Python, lane: &Lane) -> PyResult<Py<PyDict>> {
        let d = PyDict::new_bound(py);
        d.set_item("best", lane.global_best)?;
        d.set_item("max_depth_m", lane.max_depth)?;
        d.set_item("time_scale", lane.time_scale)?;
        d.set_item("session", session_dict(py, lane)?)?;
        Ok(d.unbind())
    }

    /// Single Rocket Landing lane. Deterministic cave; `seed` is accepted for
    /// gym compatibility and ignored (the cave never changes).
    #[pyclass]
    pub struct RocketEnv {
        lane: Lane,
        time_scale: f64,
        reward_mode: String,
        last_thrust: bool,
        last_torque: f64,
    }

    #[pymethods]
    impl RocketEnv {
        #[new]
        #[pyo3(signature = (time_scale=1.0, reward_mode="depth"))]
        fn new(time_scale: f64, reward_mode: &str) -> PyResult<Self> {
            if time_scale < MIN_TIME_SCALE || time_scale > MAX_TIME_SCALE {
                return Err(pyo3::exceptions::PyValueError::new_err(
                    format!("time_scale must be in [{MIN_TIME_SCALE}, {MAX_TIME_SCALE}]"),
                ));
            }
            Ok(Self {
                lane: Lane::new(0, 0),
                time_scale,
                reward_mode: reward_mode.to_string(),
                last_thrust: false,
                last_torque: 0.0,
            })
        }

        /// Reset to spawn. Returns observation (dict).
        fn reset(&mut self) -> PyResult<PyObject> {
            self.lane.reset_rocket();
            self.last_thrust = false;
            self.last_torque = 0.0;
            Python::with_gil(|py| Ok(lane_dict(py, &self.lane, false, 0.0)?.into()))
        }

        /// Step the simulation.
        /// `action` — [thrust (0/1), torque (-1..1)].
        /// Returns (obs, reward, terminated, truncated, info).
        fn step(&mut self, action: Vec<f64>) -> PyResult<(PyObject, f64, bool, bool, PyObject)> {
            if action.len() < 2 {
                return Err(pyo3::exceptions::PyValueError::new_err(
                    "action must be [thrust, torque]",
                ));
            }
            let thrust = action[0] > 0.5;
            let torque = action[1].clamp(-1.0, 1.0);
            self.last_thrust = thrust;
            self.last_torque = torque;

            let (reward, terminated) =
                self.lane.step(thrust, torque, self.time_scale, &self.reward_mode);
            let truncated = self.lane.time_alive >= 400.0; // 400 s cap

            Python::with_gil(|py| {
                let obs = lane_dict(py, &self.lane, thrust, torque)?;
                let info = info_dict(py, &self.lane)?;
                Ok((obs.into(), reward, terminated, truncated, info.into()))
            })
        }

        #[getter]
        fn state(&self) -> PyResult<PyObject> {
            Python::with_gil(|py| Ok(lane_dict(py, &self.lane, self.last_thrust, self.last_torque)?.into()))
        }

        /// Gym-style metadata: observation is a dict, so expose the keys.
        #[staticmethod]
        fn observation_space_keys() -> Vec<String> {
            ["lane", "alive", "score", "depth_m", "vel_x", "vel_y", "speed",
             "position", "angle", "angle_vel", "thrust", "torque", "time_alive",
             "lidars", "best", "time_scale", "best_depth_m", "session"]
                .into_iter().map(String::from).collect()
        }
    }

    /// Snapshot of one lane (used by both backends).
    fn lane_snap_to_dict(py: Python, lane: u32, alive: bool, score: i64, depth_m: f64,
                         vel_x: f64, vel_y: f64, pos_x: f64, pos_y: f64,
                         angle: f64, thrust: bool, torque: f64,
                         time_alive: f64, best: u64) -> PyResult<Py<PyDict>> {
        let d = PyDict::new_bound(py);
        d.set_item("lane", lane)?;
        d.set_item("alive", alive)?;
        d.set_item("score", score)?;
        d.set_item("depth_m", depth_m)?;
        d.set_item("vel_x", vel_x)?;
        d.set_item("vel_y", vel_y)?;
        d.set_item("speed", vel_x.hypot(vel_y))?;
        let position = PyDict::new_bound(py);
        position.set_item("x", pos_x)?;
        position.set_item("y", pos_y)?;
        d.set_item("position", position)?;
        d.set_item("angle", angle)?;
        d.set_item("angle_vel", 0.0f64)?;
        d.set_item("thrust", thrust)?;
        d.set_item("torque", torque)?;
        d.set_item("time_alive", time_alive)?;
        let lidard = PyDict::new_bound(py);
        lidard.set_item("right", 280.0f64)?;
        lidard.set_item("right_down", 280.0f64)?;
        lidard.set_item("down", 280.0f64)?;
        lidard.set_item("left_down", 280.0f64)?;
        lidard.set_item("left", 280.0f64)?;
        d.set_item("lidars", lidard)?;
        d.set_item("best", best)?;
        Ok(d.unbind())
    }

    /// Batch of N parallel lanes. `backend` = "cpu" (rayon) or "gpu" (wgpu,
    /// feature `gpu`). All lanes share the same deterministic cave.
    #[pyclass]
    pub struct BatchEnv {
        cpu: Option<Batch>,
        gpu: Option<crate::gpu::GpuBatch>,
        time_scale: f64,
        reward_mode: String,
    }

    #[pymethods]
    impl BatchEnv {
        #[new]
        #[pyo3(signature = (n_lanes=8, backend="cpu", time_scale=1.0, reward_mode="depth"))]
        fn new(n_lanes: usize, backend: &str, time_scale: f64, reward_mode: &str) -> PyResult<Self> {
            if time_scale < MIN_TIME_SCALE || time_scale > MAX_TIME_SCALE {
                return Err(pyo3::exceptions::PyValueError::new_err(
                    format!("time_scale must be in [{MIN_TIME_SCALE}, {MAX_TIME_SCALE}]"),
                ));
            }
            match backend {
                "cpu" => Ok(Self { cpu: Some(Batch::new(n_lanes, 0)), gpu: None, time_scale, reward_mode: reward_mode.to_string() }),
                "gpu" => Ok(Self { cpu: None, gpu: Some(gpu_init(n_lanes as u32, time_scale as f32).map_err(pyo3::exceptions::PyRuntimeError::new_err)?), time_scale, reward_mode: reward_mode.to_string() }),
                other => Err(pyo3::exceptions::PyValueError::new_err(format!("unknown backend '{other}', expected 'cpu' or 'gpu'"))),
            }
        }

        fn reset(&mut self) {
            if let Some(b) = &mut self.cpu {
                b.reset_many();
            } else if let Some(g) = &mut self.gpu {
                g.reset_lanes(self.time_scale as f32);
            }
        }

        /// Step every lane. `actions` — list of [thrust, torque], one per lane.
        /// Returns (observations, rewards, terminated) — lists aligned with lanes.
        fn step(&mut self, actions: Vec<Vec<f64>>) -> PyResult<(PyObject, Vec<f64>, Vec<bool>)> {
            if let Some(b) = &mut self.cpu {
                let act: Vec<(bool, f64)> = actions.iter()
                    .map(|a| (a.get(0).map(|v| *v > 0.5).unwrap_or(false), a.get(1).map(|v| v.clamp(-1.0, 1.0)).unwrap_or(0.0)))
                    .collect();
                let (snaps, rewards, dones) = b.step_many(&act, self.time_scale, &self.reward_mode);
                let py = Python::with_gil(|py| -> PyResult<PyObject> {
                    let list = PyList::empty_bound(py);
                    for (s, &(thrust, torque)) in snaps.iter().zip(act.iter()) {
                        let d = lane_snap_to_dict(py, s.lane, s.alive, s.score, s.depth_m,
                                                  s.vel_x, s.vel_y, s.position[0], s.position[1],
                                                  s.angle, thrust, torque, s.time_alive, s.best)?;
                        list.append(d)?;
                    }
                    Ok(list.into())
                })?;
                Ok((py, rewards, dones))
            } else if let Some(g) = &mut self.gpu {
                let act: Vec<GpuInput> = actions.iter()
                    .map(|a| GpuInput {
                        thrust: if a.get(0).map(|v| *v > 0.5).unwrap_or(false) { 1.0 } else { 0.0 },
                        torque: a.get(1).map(|v| v.clamp(-1.0, 1.0)).unwrap_or(0.0) as f32,
                    })
                    .collect();
                g.set_inputs(&act);
                g.step();
                let lanes = g.read_lanes();
                g.unmap();
                let (rewards, dones, obs) = Python::with_gil(|py| -> PyResult<(Vec<f64>, Vec<bool>, PyObject)> {
                    let mut rewards = Vec::with_capacity(lanes.len());
                    let mut dones = Vec::with_capacity(lanes.len());
                    let list = PyList::empty_bound(py);
                    for (i, l) in lanes.iter().enumerate() {
                        let thrust = act.get(i).map(|a| a.thrust > 0.5).unwrap_or(false);
                        let torque = act.get(i).map(|a| a.torque as f64).unwrap_or(0.0);
                        // approximate depth-per-tick reward; GPU doesn't send prev depth
                        rewards.push(l.cur_depth as f64);
                        dones.push(l.alive < 0.5);
                        let d = lane_snap_to_dict(py, i as u32, l.alive > 0.5, l.cur_depth as i64,
                                                  l.cur_depth as f64, l.vel_x as f64, l.vel_y as f64,
                                                  l.pos_x as f64, l.pos_y as f64,
                                                  l.angle.to_degrees() as f64, thrust, torque,
                                                  l.time_alive as f64, 0)?;
                        list.append(d)?;
                    }
                    Ok((rewards, dones, list.into()))
                })?;
                Ok((obs, rewards, dones))
            } else {
                unreachable!()
            }
        }

        #[getter]
        fn lanes(&self) -> usize {
            self.cpu.as_ref().map(|b| b.lanes.len()).unwrap_or_else(|| self.gpu.as_ref().map(|g| g.n_lanes as usize).unwrap_or(0))
        }
    }

    /// Run the TAS beam search and return a dict with the ideal tape.
    /// `beam_width` — candidates per tick; `max_ticks` — cap (60 Hz).
    /// Result: `{final_depth_m, ticks, survived, tape: [[thrust: bool, torque: float], ...]}`.
    #[pyfunction]
    #[pyo3(signature = (beam_width=64, max_ticks=2700, wall_margin=14.0, wall_penalty=0.002, speed_weight=0.0, goal_depth_m=None))]
    fn solve_ideal_run(py: Python, beam_width: usize, max_ticks: u32, wall_margin: f64, wall_penalty: f64, speed_weight: f64, goal_depth_m: Option<f64>) -> PyResult<PyObject> {
        let cfg = crate::tas::TasSolveConfig { beam_width, max_ticks, wall_margin, wall_penalty, speed_weight, goal_depth_m };
        let res = crate::tas::solve(cfg);
        let d = PyDict::new_bound(py);
        d.set_item("final_depth_m", res.final_depth_m)?;
        d.set_item("ticks", res.ticks)?;
        d.set_item("survived", res.survived)?;
        let tape = PyList::empty_bound(py);
        for &(thrust, torque) in &res.tape {
            let row = PyList::empty_bound(py);
            row.append(thrust)?;
            row.append(torque)?;
            tape.append(row)?;
        }
        d.set_item("tape", tape)?;
        Ok(d.into())
    }

    /// Optimize a seed tape (forward-replace passes, O(len²) body steps).
    /// `rounds` — number of improvement passes over the whole tape.
    /// Result: {final_depth_m, ticks, survived, tape}.
    #[pyfunction]
    #[pyo3(signature = (seed_tape, rounds=2))]
    fn optimize_tape(py: Python, seed_tape: Vec<(bool, f64)>, rounds: u32) -> PyResult<PyObject> {
        let res = crate::tas::optimize_tape(&seed_tape, rounds);
        let d = PyDict::new_bound(py);
        d.set_item("final_depth_m", res.final_depth_m)?;
        d.set_item("ticks", res.ticks)?;
        d.set_item("survived", res.survived)?;
        let tape = PyList::empty_bound(py);
        for &(thrust, torque) in &res.tape {
            let row = PyList::empty_bound(py);
            row.append(thrust)?;
            row.append(torque)?;
            tape.append(row)?;
        }
        d.set_item("tape", tape)?;
        Ok(d.into())
    }

    /// Replay a tape and report its outcome: `{final_depth_m, survived}`.
    #[pyfunction]
    fn evaluate_tape(py: Python, tape: Vec<(bool, f64)>) -> PyResult<PyObject> {
        let (depth, survived) = crate::tas::evaluate(&tape);
        let d = PyDict::new_bound(py);
        d.set_item("final_depth_m", depth)?;
        d.set_item("survived", survived)?;
        Ok(d.into())
    }

    /// Python module entry point.
    #[pymodule]
    fn rocket_landing_env(_py: Python, m: &Bound<PyModule>) -> PyResult<()> {
        m.add_class::<RocketEnv>()?;
        m.add_class::<BatchEnv>()?;
        m.add_function(wrap_pyfunction!(solve_ideal_run, m)?)?;
        m.add_function(wrap_pyfunction!(evaluate_tape, m)?)?;
        m.add_function(wrap_pyfunction!(optimize_tape, m)?)?;
        m.add("VERSION", env!("CARGO_PKG_VERSION"))?;
        m.add("PX_PER_METER", PX_PER_METER)?;
        Ok(())
    }
}

#[cfg(not(feature = "python"))]
pub mod batch { pub struct Batch; impl Batch { pub fn new(_n: usize, _best: u64) -> Self { Self } pub fn reset_many(&mut self) {} pub fn step_many(&mut self, _: &[(bool, f64)], _: f64, _: &str) -> (Vec<crate::env::LaneSnapshot>, Vec<f64>, Vec<bool>) { (Vec::new(), Vec::new(), Vec::new()) } } }

pub use crate::batch::Batch;
pub use crate::env::{Lane, LaneSnapshot, SessionSnapshot};
#[cfg(feature = "gpu")]
pub use crate::gpu::GpuBatch;
pub use crate::tas::{TasResult, TasSolveConfig};
