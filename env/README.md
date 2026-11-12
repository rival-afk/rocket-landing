# rocket-landing-env

Rust/PyO3 environment for **Rocket Landing** — a deterministic cave faller — with
near-perfect reimplementation of the Godot 4 physics + game logic. Gym-style
batch API, CPU (rayon) and GPU (wgpu compute) backends.

Lives in the `env/` folder of `rival-afk/rocket-landing` (next to `game/` and
`ai/`). The game itself is `game/`; the training stack is `ai/`.

## Status

- **Physics**: semi-implicit Euler (v then x), gravity 980 px/s², thrust 1500
  along body up, angular velocity set directly to ±4.0 rad/s (torque.gd
  semantics), continuous collision shape (CAST_SHAPE) for the rocket shape
  (20×24 RectangleShape2D at (0,-2)). Wall collision is *lethal on touch*, as
  in the game — so analytic OBB-vs-corridor checks drive the kill rule instead
  of an impulse solver (which GodotPhysics2D would use but we don't need).
- **Cave**: exact formula port of `game/cave.gd` — knots every 256 px, offsets
  `(hash(k)*2-1)*175`, half-width `60 + hash(k+1000)*55`, linear interpolation
  (sharp corners), spawn-safety ramp `|y|/768`. Deterministic: same cave on
  every run. Verified identical to the GDScript output (see `cargo test`).
- **Scoring**: signed depth `(y - spawn_y)/50` — grows below spawn, shrinks
  (goes negative) above it. `max_depth` is the historical max (records).
- **Multi-game**: `BatchEnv(N, backend="cpu"|"gpu")` — independent lanes, same
  cave; CPU backend parallelises with rayon; GPU backend launches one WGSL
  compute kernel per tick with one invocation per lane.

## Install

```bash
maturin build --release
pip install --force-reinstall --no-deps target/wheels/rocket_landing_env-1.1.0-*.whl
```

## Usage

```python
import rocket_landing_env as rl

env = rl.RocketEnv()                    # single lane
obs = env.reset()                       # dict: depth_m, vel_*, lidars, position, angle, ...
obs, reward, terminated, truncated, info = env.step([1.0, 0.0])  # action = [thrust, torque in -1..1]

bench = rl.BatchEnv(512, backend="gpu")  # or "cpu"
out = bench.step([[1.0, 0.0]] * 512)     # (obs, rewards, terminated) — lists per lane
print(out[0][3]["lidars"])
```

Reward modes (`reward_mode=...`): `"depth"` (Δdepth, default), `"survival"`
(+1 per tick alive), `"depth_clipped"` (Δdepth clamped to ±0.2),
`"death"` (Δdepth, −100 on death).

## API parity with `game/` HTTP API

Every observation dict mirrors the `/state?lane=N` JSON payload of the game's
HTTP API: `lane`, `alive`, `score` (signed), `depth_m`, `vel_x`, `vel_y`,
`speed`, `position{x,y}`, `angle`, `angle_vel`, `thrust`, `torque`,
`time_alive`, `lidars{right,right_down,down,left_down,left}` (distances in px,
280 = clear), plus `best`, `time_scale`, `best_depth_m`, `session`.

## Notable deviations from the Godot build (honest list)

1. **No impulse solver.** GodotPhysics2D resolves contacts with an iterative
   impulse solver; since walls are lethal on touch, we use an analytic
   OBB-vs-corridor test. Dead/alive at tick N may differ by ~one tick from
   the game at exactly-grazed contacts.
2. **sin() ULP differences** between libm (CPU) and GPU drivers make wall
   x-coordinates differ by ~1e-12; the cave is visually identical, not
   bitwise identical.
3. **GPU doesn't raycast lidars** — the GPU kernel steps physics only and
   reports `lidars=280` (clear). Use the CPU backend for lidar observations.
4. **time_scale** multiplies dt (not the tick rate), same as the game's
   `Engine.time_scale`.
5. **best file** is written next to the process working dir; the game writes
   `user://rocket_landing_best.txt`.

## Tests

```bash
cargo test --release
```

38 unit tests cover cave determinism, hash range, corridor sanity, physics
fall/climb, scoring (signed depth, max tracking), session stats.
