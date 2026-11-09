# -*- coding: utf-8 -*-
"""
Neuroevolution trainer for Rocket Landing (HTTP API, GUI mode).

- 8 parallel lanes act as the GA population.
- Small MLP: 9 inputs -> 24 tanh -> 2 outputs (thrust sigmoid, torque tanh).
- Fitness = max depth_m (score only grows while descending).
- Saves best genome + checkpoint every generation, snapshots every 25 gens.
- Resumes from checkpoint.json if present; runs forever otherwise.
"""
import json
import os
import sys
import time
import math
import csv
import urllib.request

HOST = "http://127.0.0.1:8080"
TARGET_LANES = 12
TIME_SCALE = 2.0
VY_MAX = 900.0        # px/s, для нормализации средней vy в логах
VY_TGT = 150.0        # px/s — пик «постепенного спуска»
VY_HI = 400.0         # px/s — спад награды от пика до нуля (быстрее — плохо)
NOSE_MIN = 0.25       # множитель носа при полностью горизонтальном носе
NOSE_SPAN = 0.75      # приращение за вертикальность (cos угла)
DESC_MIN = 0.15       # базовая часть за спуск при vy вне зоны
DESC_SPAN = 0.85      # приращение за постепенный спуск
TICK = 0.033            # ~30 Hz real-time control rounds
EPISODE_CAP_S = 75.0    # hard cap per generation
W_DECAY = 0.998  # затухание весов у потомков — против насыщения tanh/sigmoid
IMMIGRANTS = 1   # свежих случайных генома в поколение — поддержание разнообразия
ELITES = 2
HIDDEN = 24
N_IN = 13
OLD_N_IN = 9
OLD_PARAMS = OLD_N_IN * HIDDEN + HIDDEN + HIDDEN * 2 + 2  # v1 genome length (290)
SIGMA0 = 0.35
SIGMA_MIN = 0.08
SIGMA_MAX = 0.6
STAGNATION_LIMIT = 15   # gens without best-ever improvement -> bump sigma
SEED = 1234

HERE = os.path.dirname(os.path.abspath(__file__))
BEST_F = os.path.join(HERE, "best.json")
CHK_F = os.path.join(HERE, "checkpoint.json")
LOG_F = os.path.join(HERE, "log.csv")
SNAP_DIR = os.path.join(HERE, "snapshots")

import random
random.seed(SEED)

# ---------- tiny MLP (weights as flat list) ----------
W1_N = N_IN * HIDDEN
B1_N = HIDDEN
W2_N = HIDDEN * 2
B2_N = 2
N_PARAMS = W1_N + B1_N + W2_N + B2_N

def unpack(g):
    i = 0
    W1 = g[i:i + W1_N]; i += W1_N
    b1 = g[i:i + B1_N]; i += B1_N
    W2 = g[i:i + W2_N]; i += W2_N
    b2 = g[i:i + B2_N]; i += B2_N
    return W1, b1, W2, b2

def forward(g, x):
    W1, b1, W2, b2 = unpack(g)
    h = [0.0] * HIDDEN
    for j in range(HIDDEN):
        s = b1[j]
        base = j * N_IN
        for k in range(N_IN):
            s += W1[base + k] * x[k]
        h[j] = math.tanh(s)
    out = [0.0, 0.0]
    for j in range(2):
        s = b2[j]
        base = j * HIDDEN
        for k in range(HIDDEN):
            s += W2[base + k] * h[k]
        out[j] = s
    thrust = 1.0 / (1.0 + math.exp(-max(-60.0, min(60.0, out[0])))) > 0.5
    torque = math.tanh(out[1])
    return thrust, torque

def random_genome():
    g = []
    for _ in range(N_IN * HIDDEN):
        g.append(random.gauss(0.0, math.sqrt(2.0 / N_IN)))
    for _ in range(HIDDEN):
        g.append(0.0)
    for _ in range(HIDDEN * 2):
        g.append(random.gauss(0.0, math.sqrt(2.0 / HIDDEN)))
    for _ in range(2):
        g.append(0.0)
    return g

def crossover(a, b):
    return [a[i] if random.random() < 0.5 else b[i] for i in range(N_PARAMS)]

def mutate(g, sigma):
    return [v * W_DECAY + (random.gauss(0.0, sigma) if random.random() < 0.9 else 0.0) for v in g]

def clip(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)

def migrate_v1(g):
    """Zero-pad a v1 genome (9 inputs) to v2 (13 inputs): identical function."""
    if len(g) != OLD_PARAMS:
        return g
    g2 = []
    for j in range(HIDDEN):
        row = g[j * OLD_N_IN:(j + 1) * OLD_N_IN]
        g2.extend(row)
        g2.extend([0.0] * (N_IN - OLD_N_IN))
    off = OLD_N_IN * HIDDEN
    g2.extend(g[off:off + HIDDEN])          # b1
    off += HIDDEN
    g2.extend(g[off:off + HIDDEN * 2])      # W2
    off += HIDDEN * 2
    g2.extend(g[off:off + 2])               # b2
    return g2

def obs_from_state(st):
    lid = st["lidars"]
    pos = st["position"]
    ang = math.radians(st.get("angle", 0.0))
    return [
        lid["right"] / 280.0,
        lid["right_down"] / 280.0,
        lid["down"] / 280.0,
        lid["left_down"] / 280.0,
        lid["left"] / 280.0,
        clip(st["vel_x"] / 600.0, -3.0, 3.0),
        clip(st["vel_y"] / 900.0, -3.0, 3.0),
        clip(pos["x"] / 150.0, -3.0, 3.0),
        clip(st["depth_m"] / 100.0, 0.0, 3.0),
        math.sin(ang),
        math.cos(ang),
        clip(st.get("angle_vel", 0.0) / 5.0, -3.0, 3.0),
        clip(st.get("speed", 0.0) / 900.0, 0.0, 3.0),
    ]

# ---------- HTTP ----------
def http_get(path, timeout=5):
    return json.loads(urllib.request.urlopen(HOST + path, timeout=timeout).read().decode())

def http_post(path, payload, timeout=5):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(HOST + path, data=data, headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode())

def ensure_lanes(n):
    h = http_get("/health")
    while h["lanes"] < n:
        http_post("/spawn", {})
        time.sleep(0.2)
        h = http_get("/health")
    return h["lanes"]

def existing_lane_ids():
    st = http_get("/state")
    return [l["lane"] for l in st["lanes"]]

def set_time_scale(s):
    try:
        http_post("/speed", {"scale": s})
    except Exception as e:
        print("warn: set time_scale failed:", e, flush=True)

def respawn_lane(i):
    try:
        http_post("/respawn", {"lane": i}, timeout=10)
        return True
    except Exception as e:
        print("warn: respawn lane", i, "failed:", e, flush=True)
        return False

# ---------- episode ----------
def run_episode(pop, lanes):
    for lane in lanes:
        respawn_lane(lane)
    states = [None] * len(lanes)
    alive = [True] * len(lanes)
    max_depth = [0.0] * len(lanes)
    vy_sum = [0.0] * len(lanes)
    vy_ticks = [0] * len(lanes)
    err_count = 0
    reward_sum = [0.0] * len(lanes)
    upright_sum = [0.0] * len(lanes)
    t0 = time.time()
    while any(alive) and (time.time() - t0) < EPISODE_CAP_S:
        # build actions from last known states (first iteration: neutral)
        actions = []
        for idx in range(len(lanes)):
            if not alive[idx]:
                actions.append(None)
                continue
            st = states[idx]
            if st is None:
                actions.append({"lane": lanes[idx], "thrust": False, "torque": 0})
                continue
            x = obs_from_state(st)
            thrust, torque = forward(pop[idx], x)
            actions.append({"lane": lanes[idx], "thrust": bool(thrust), "torque": float(round(torque, 3))})
        results = []
        for a in actions:
            if a is None:
                results.append(None)
                continue
            try:
                results.append(http_post("/control", a, timeout=5))
            except Exception:
                results.append(None)
        for idx, r in enumerate(results):
            if r is None:
                err_count += 1
                continue
            states[idx] = r
            d = float(r.get("depth_m", 0.0))
            if d > max_depth[idx]:
                max_depth[idx] = d
            vy = float(r.get("vel_y", 0.0))
            vy_sum[idx] += abs(vy)
            vy_ticks[idx] += 1
            ang_rad = math.radians(float(r.get("angle", 0.0)))
            upright = clip(math.cos(ang_rad), 0.0, 1.0)
            if vy <= 0.0:
                desc_score = 0.0
            elif vy < VY_TGT:
                desc_score = vy / VY_TGT
            else:
                desc_score = max(0.0, 1.0 - (vy - VY_TGT) / VY_HI)
            reward_sum[idx] += (NOSE_MIN + NOSE_SPAN * upright) * (DESC_MIN + DESC_SPAN * desc_score)
            upright_sum[idx] += upright
            if not r.get("alive", True):
                alive[idx] = False
        if err_count > 300:
            raise RuntimeError("too many API errors - is the game closed?")
        time.sleep(TICK)
    # награда ТОЛЬКО за: низкая vy + постепенный спуск вниз + вертикальный нос.
    # время не учитывается (но тех. предохранитель EPISODE_CAP_S остаётся,
    # иначе зависший в воздухе агент заморозит поколение навсегда).
    fits = list(reward_sum)
    avg_vys = [vy_sum[i] / max(1, vy_ticks[i]) for i in range(len(lanes))]
    avg_upr = [upright_sum[i] / max(1, vy_ticks[i]) for i in range(len(lanes))]
    return fits, max_depth, avg_vys, avg_upr

# ---------- GA ----------
def evolve(pop, fits, sigma):
    order = sorted(range(len(pop)), key=lambda i: fits[i], reverse=True)
    ranked = [pop[i] for i in order]
    ranked_fits = [fits[i] for i in order]
    new_pop = [list(ranked[i]) for i in range(min(ELITES, len(ranked)))]  # elites
    while len(new_pop) < len(pop):
        def pick():
            i, j = random.sample(range(len(pop)), 2)
            return pop[i] if fits[i] >= fits[j] else pop[j]
        child = crossover(pick(), pick())
        child = mutate(child, sigma)
        new_pop.append(child)
    # иммиграция: последнюю ячейку заменяем случайным геномом
    if IMMIGRANTS > 0 and len(new_pop) >= IMMIGRANTS:
        for _ in range(IMMIGRANTS):
            new_pop[-1 - _] = random_genome()
    return new_pop, ranked_fits

def main():
    print("ensuring game API + lanes...", flush=True)
    ensure_lanes(TARGET_LANES)
    set_time_scale(TIME_SCALE)
    lanes = existing_lane_ids()[:TARGET_LANES]
    print(f"using lanes: {lanes}, time_scale={TIME_SCALE}", flush=True)

    gen = 0
    sigma = SIGMA0
    best_ever = {"fitness": -1.0, "genome": None, "gen": -1}
    pop = [random_genome() for _ in lanes]

    if os.path.exists(CHK_F):
        try:
            with open(CHK_F, "r", encoding="utf-8") as f:
                chk = json.load(f)
            pop = [migrate_v1(g) for g in chk["population"]]
            gen = chk.get("gen", 0)
            sigma = chk.get("sigma", SIGMA0)
            be = chk.get("best_ever", best_ever)
            if be.get("genome") is not None:
                be["genome"] = migrate_v1(be["genome"])
            best_ever = be
            print(f"resumed from checkpoint: gen={gen} sigma={sigma:.3f} best={best_ever['fitness']:.2f}", flush=True)
        except Exception as e:
            print("warn: checkpoint unreadable, starting fresh:", e, flush=True)
    elif os.path.exists(BEST_F):
        try:
            with open(BEST_F, "r", encoding="utf-8") as f:
                b = json.load(f)
            pop[0] = migrate_v1(b["genome"])
            best_ever = {"fitness": b["fitness"], "genome": migrate_v1(b["genome"]), "gen": b.get("gen", -1)}
            print(f"seeded from best.json fitness={b['fitness']:.2f}", flush=True)
        except Exception as e:
            print("warn: best.json unreadable:", e, flush=True)

    # population size must match lanes: pad with fresh migrants, keep elites first
    target = len(lanes)
    if len(pop) < target:
        pop = pop + [random_genome() for _ in range(target - len(pop))]
    elif len(pop) > target:
        pop = pop[:target]

    stagnant = 0
    log_exists = os.path.exists(LOG_F)
    with open(LOG_F, "a", newline="", encoding="utf-8") as logf:
        w = csv.writer(logf)
        if not log_exists:
            w.writerow(["gen", "timestamp", "best", "mean", "worst", "sigma", "best_ever", "elapsed_s",
                        "raw_best_m", "mean_vy", "mean_upright"])
        while True:
            t0 = time.time()
            fits, raw_depths, avg_vys, avg_upr = run_episode(pop, lanes)
            mean_fit = sum(fits) / len(fits)
            raw_best = max(raw_depths)
            mean_vy = sum(avg_vys) / len(avg_vys)
            gen += 1
            prev_best_ever = best_ever["fitness"]
            elite_idx = max(range(len(fits)), key=lambda i: fits[i])
            if fits[elite_idx] > best_ever["fitness"]:
                best_ever = {"fitness": fits[elite_idx], "genome": list(pop[elite_idx]), "gen": gen,
                             "raw_depth": raw_depths[elite_idx]}
                with open(BEST_F, "w", encoding="utf-8") as f:
                    json.dump({"fitness": best_ever["fitness"], "gen": gen, "genome": best_ever["genome"],
                               "raw_depth": raw_depths[elite_idx],
                               "n_params": N_PARAMS, "arch": [N_IN, HIDDEN, 2]}, f)
                stagnant = 0
                print(f"gen {gen}: NEW BEST {fits[elite_idx]:.2f} (raw {raw_depths[elite_idx]:.2f} m)", flush=True)
            else:
                stagnant += 1
                if stagnant >= STAGNATION_LIMIT:
                    sigma = min(SIGMA_MAX, sigma * 1.3)
                    stagnant = 0
                    print(f"gen {gen}: stagnation -> sigma {sigma:.3f}", flush=True)

            pop, _ = evolve(pop, fits, sigma)
            sigma = max(SIGMA_MIN, sigma * 0.995)

            chk = {"gen": gen, "sigma": sigma, "population": pop, "best_ever": best_ever,
                   "last_fits": fits, "last_raw_depths": raw_depths, "last_avg_vys": avg_vys}
            tmp = CHK_F + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(chk, f)
            os.replace(tmp, CHK_F)
            if gen % 25 == 0:
                with open(os.path.join(SNAP_DIR, f"gen_{gen:05d}.json"), "w", encoding="utf-8") as f:
                    json.dump(chk, f)
            elapsed = time.time() - t0
            w.writerow([gen, time.strftime("%Y-%m-%d %H:%M:%S"), f"{max(fits):.2f}",
                        f"{mean_fit:.2f}", f"{min(fits):.2f}", f"{sigma:.4f}",
                        f"{best_ever['fitness']:.2f}", f"{elapsed:.1f}",
                        f"{raw_best:.2f}", f"{mean_vy:.1f}"])
            logf.flush()
            print(f"gen {gen}: best={max(fits):.2f} mean={mean_fit:.2f} raw_best={raw_best:.2f}m "
                  f"mean_vy={mean_vy:.0f} sigma={sigma:.3f} "
                  f"best_ever={best_ever['fitness']:.2f} ({elapsed:.1f}s)", flush=True)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("stopped by user", flush=True)
    except Exception as e:
        print("FATAL:", e, flush=True)
        sys.exit(1)
