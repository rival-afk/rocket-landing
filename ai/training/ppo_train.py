# -*- coding: utf-8 -*-
"""
PPO (PyTorch) для Rocket Landing — НАСТОЯЩЕЕ RL, не нейроэволюция.

- Два независимых лика, оба на GPU (cuda), на своих lane (тег "cpu" оставлен для совместимости чекпоинтов).
- Действия дискретные (6): тяга off/on × руль -1/0/+1.
- Reward v5: ГЛАВНОЕ — удаление от объектов (min лидара); + вертикальный нос;
  +-vy (вниз) / -vy (вверх); - подъём; - |vx| и |vy|. Время не учитывается (эпизод режется по 600
  тиков — техпредохранитель, это не часть награды).
- Чекпоинты в training/ppo/: {dev}_last.pt / {dev}_best.pt + ppo_log.csv
- Возобновляется с *_last.pt при наличии.
"""
import json
import math
import os
import csv
import time
import random
import urllib.request
from collections import deque

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.distributions import Categorical

HOST = "http://127.0.0.1:8080"
TARGET_LANES = 8
GPU_LANES = 4
TIME_SCALE = 1.0
CRASH_PENALTY = -2.0   # штраф за краш

TICK_CAP = 600          # тех. предохранитель на эпизод (не награда!)
GAMMA = 0.99
LAM = 0.95
CLIP = 0.2
EPOCHS = 4
MINIBATCH = 256
LR = 3e-4
VF_COEF = 0.5
ENT_COEF = 0.01
BUFFER_STEPS = 2048     # сумма тиков по всем ликам между апдейтами
SAVE_EVERY = 1          # итераций между снапшотами last.pt
BEST_WINDOW = 20        # размер окна среднего reward для выбора best.pt
SEED = 1234

CLEAR_W = 0.8         # ГЛАВНОЕ: награда за удаление от объектов (min лидара / 280), 0..0.8
NOSE_W = 0.3          # награда за вертикальный нос (cos угла), 0..0.3
VY_W = 0.8            # +vy (вниз) награда, -vy (вверх) штраф, пропорционально, на весь размах
SPD_W = 0.4           # штраф за |vx|+|vy| (растёт с обеими), до -0.8
SPD_REF = 900.0       # px/s — нормировка скоростного штрафа

INFINITY_CAP_S = 75.0   # тех. предохранитель на поколение (wall-clock)

HERE = os.path.dirname(os.path.abspath(__file__))
PPO_DIR = os.path.join(HERE, "ppo")
LOG_F = os.path.join(PPO_DIR, "ppo_log.csv")
os.makedirs(PPO_DIR, exist_ok=True)

random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)

N_IN = 13
ACTIONS = [(False, -1.0), (False, 0.0), (False, 1.0),
           (True, -1.0), (True, 0.0), (True, 1.0)]

# ---------- network ----------
class ActorCritic(nn.Module):
    def __init__(self, n_in=N_IN, n_act=len(ACTIONS), hidden=64):
        super().__init__()
        self.trunk = nn.Sequential(
            nn.Linear(n_in, hidden), nn.Tanh(),
            nn.Linear(hidden, hidden), nn.Tanh(),
        )
        self.pi = nn.Linear(hidden, n_act)
        self.v = nn.Linear(hidden, 1)

    def forward(self, x):
        h = self.trunk(x)
        return self.pi(h), self.v(h).squeeze(-1)

# ---------- HTTP ----------
def http_get(path, timeout=5):
    return json.loads(urllib.request.urlopen(HOST + path, timeout=timeout).read().decode())

def http_post(path, payload, timeout=5):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(HOST + path, data=data, headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode())

def http_delete(path, timeout=5):
    req = urllib.request.Request(HOST + path, method="DELETE")
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode())

def existing_lane_ids():
    return [l["lane"] for l in http_get("/state")["lanes"]]

def ensure_lanes(n):
    h = http_get("/health")
    while h["lanes"] < n:
        http_post("/spawn", {})
        time.sleep(0.2)
        h = http_get("/health")
    # лишние не удаляем: работаем с первыми n существующими
    return existing_lane_ids()[:n]

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

def clip(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)

def obs_from_state(st):
    lid = st["lidars"]
    pos = st["position"]
    ang = math.radians(float(st.get("angle", 0.0)))
    return np.array([
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
        clip(float(st.get("angle_vel", 0.0)) / 5.0, -3.0, 3.0),
        clip(float(st.get("speed", 0.0)) / 900.0, 0.0, 3.0),
    ], dtype=np.float32)

def reward_tick(st):
    """v5: ГЛАВНОЕ — удаление от объектов (min лидара); + вертикальный нос;
    +-vy (вниз) / -vy (вверх); - полёт вверх; - |vx| и |vy|; - подъём; время НЕ учитывается."""
    vy = float(st["vel_y"])
    vx = float(st["vel_x"])
    lid = st["lidars"]
    clear = clip(min(lid[k] for k in ("right", "right_down", "down", "left_down", "left")) / 280.0, 0.0, 1.0)
    ang_rad = math.radians(float(st.get("angle", 0.0)))
    upright = clip(math.cos(ang_rad), 0.0, 1.0)
    r = CLEAR_W * clear + NOSE_W * upright
    r += VY_W * clip(vy / SPD_REF, -1.0, 1.0)
    r -= SPD_W * (abs(vy) + abs(vx)) / SPD_REF
    return r

# ---------- one learner (one device, subset of lanes) ----------
class Learner:
    def __init__(self, device, lane_ids, tag):
        self.device = torch.device(device)
        self.lane_ids = list(lane_ids)
        self.tag = tag
        self.net = ActorCritic().to(self.device)
        self.opt = torch.optim.Adam(self.net.parameters(), lr=LR)
        # per-lane episode state
        self.ep_ticks = {l: 0 for l in self.lane_ids}
        self.ep_reward = {l: 0.0 for l in self.lane_ids}
        self.ep_max_depth = {l: 0.0 for l in self.lane_ids}
        # rollout buffer
        self.buf = []  # list of dicts
        self.ep_rewards_recent = deque(maxlen=BEST_WINDOW)
        self.ep_depths_recent = deque(maxlen=BEST_WINDOW)
        self.deaths = 0
        self.truncations = 0
        self.iter_deaths = 0
        self.iter_truncations = 0
        self.best_mean_reward = -1e9
        self.iter_idx = 0
        self.total_steps = 0
        self.last_path = os.path.join(PPO_DIR, f"{self.tag}_last.pt")
        self.best_path = os.path.join(PPO_DIR, f"{self.tag}_best.pt")
        self.load_last()

    def load_last(self):
        if os.path.exists(self.last_path):
            try:
                ck = torch.load(self.last_path, map_location=self.device)
                self.net.load_state_dict(ck["model"])
                self.opt.load_state_dict(ck["opt"])
                self.iter_idx = ck.get("iter", 0)
                self.total_steps = ck.get("total_steps", 0)
                self.best_mean_reward = ck.get("best_mean_reward", -1e9)
                print(f"[{self.tag}] resumed from {self.last_path} iter={self.iter_idx}", flush=True)
            except Exception as e:
                print(f"[{self.tag}] warn: cannot resume ({e}), starting fresh", flush=True)

    def save(self, best=False):
        ck = {"model": self.net.state_dict(), "opt": self.opt.state_dict(),
              "iter": self.iter_idx, "total_steps": self.total_steps,
              "best_mean_reward": self.best_mean_reward,
              "arch": [N_IN, 64, 64, len(ACTIONS)], "tag": self.tag}
        torch.save(ck, self.last_path)
        if best:
            torch.save(ck, self.best_path)

    def respawn(self):
        for l in self.lane_ids:
            respawn_lane(l)
            self.ep_ticks[l] = 0
            self.ep_reward[l] = 0.0
            self.ep_max_depth[l] = 0.0

    def act_batch(self, states):
        obs = np.stack([obs_from_state(s) for s in states]).astype(np.float32)
        x = torch.from_numpy(obs).to(self.device)
        with torch.no_grad():
            logits, values = self.net(x)
            dist = Categorical(logits=logits)
            actions = dist.sample()
            logps = dist.log_prob(actions)
        return x, actions, logps, values

    def store_step(self, obs_x, act, logp, val, reward, done, lane):
        self.buf.append({"obs": obs_x.detach().cpu(), "action": int(act.detach().cpu()),
                         "logp": float(logp.detach().cpu()), "value": float(val.detach().cpu()),
                         "reward": float(reward), "done": bool(done), "lane": int(lane)})
        self.total_steps += 1

    def update(self):
        if len(self.buf) < 64:
            self.buf.clear()
            return None
        # GAE по каждому lane отдельно
        advs = [0.0] * len(self.buf)
        rets = [0.0] * len(self.buf)
        by_lane = {}
        for i, t in enumerate(self.buf):
            by_lane.setdefault(t["lane"], []).append(i)
        for lane, idxs in by_lane.items():
            gae = 0.0
            next_value = 0.0
            for i in reversed(idxs):
                t = self.buf[i]
                nt = 0.0 if t["done"] else 1.0
                delta = t["reward"] + GAMMA * next_value * nt - t["value"]
                gae = delta + GAMMA * LAM * nt * gae
                advs[i] = gae
                rets[i] = gae + t["value"]
                # V(s_i) всегда валиден (состояние существовало) — безусловно
                next_value = t["value"]
        obs = torch.stack([t["obs"] for t in self.buf]).to(self.device)
        actions = torch.tensor([t["action"] for t in self.buf], dtype=torch.long, device=self.device)
        old_logps = torch.tensor([t["logp"] for t in self.buf], dtype=torch.float32, device=self.device)
        adv = torch.tensor(advs, dtype=torch.float32, device=self.device)
        ret = torch.tensor(rets, dtype=torch.float32, device=self.device)
        adv = (adv - adv.mean()) / (adv.std() + 1e-8)
        n = len(self.buf)
        idx = torch.randperm(n, device=self.device)
        stats = {"pg_loss": 0.0, "vf_loss": 0.0, "ent": 0.0, "approx_kl": 0.0}
        nb = 0
        for _ in range(EPOCHS):
            for start in range(0, n, MINIBATCH):
                mb = idx[start:start + MINIBATCH]
                logits, values = self.net(obs[mb])
                dist = Categorical(logits=logits)
                logps = dist.log_prob(actions[mb])
                ratio = torch.exp(logps - old_logps[mb])
                s1 = ratio * adv[mb]
                s2 = torch.clamp(ratio, 1 - CLIP, 1 + CLIP) * adv[mb]
                pg_loss = -torch.min(s1, s2).mean()
                vf_loss = F.mse_loss(values, ret[mb])
                ent = dist.entropy().mean()
                approx_kl = (old_logps[mb] - logps).mean().item()
                loss = pg_loss + VF_COEF * vf_loss - ENT_COEF * ent
                self.opt.zero_grad()
                loss.backward()
                nn.utils.clip_grad_norm_(self.net.parameters(), 0.5)
                self.opt.step()
                stats["pg_loss"] += float(pg_loss.detach())
                stats["vf_loss"] += float(vf_loss.detach())
                stats["ent"] += float(ent.detach())
                stats["approx_kl"] += approx_kl
                nb += 1
        self.buf.clear()
        self.iter_idx += 1
        for k in stats:
            stats[k] /= max(1, nb)
        stats["iter"] = self.iter_idx
        return stats

    def finish_episode(self, lane, reward, depth, truncated):
        self.ep_rewards_recent.append(reward)
        self.ep_depths_recent.append(depth)
        if truncated:
            self.truncations += 1
            self.iter_truncations += 1
        else:
            self.deaths += 1
            self.iter_deaths += 1

    def mean_ep_reward(self):
        return float(np.mean(self.ep_rewards_recent)) if self.ep_rewards_recent else 0.0

    def mean_ep_depth(self):
        return float(np.mean(self.ep_depths_recent)) if self.ep_depths_recent else 0.0

# ---------- env stepping (round-robin по ликам / устройствам) ----------
def run_forever(learners):
    owner_of = {}
    for lrn in learners:
        for lane in lrn.lane_ids:
            owner_of[lane] = lrn
    for lrn in learners:
        lrn.respawn()
    states = {l: None for l in owner_of}
    err_count = 0
    last_respawn = time.time()
    log_exists = os.path.exists(LOG_F)
    with open(LOG_F, "a", newline="", encoding="utf-8") as logf:
        w = csv.writer(logf)
        if not log_exists:
            w.writerow(["iter", "timestamp", "device", "steps", "mean_ep_reward", "mean_ep_depth",
                        "pg_loss", "vf_loss", "entropy", "approx_kl", "elapsed_s", "deaths", "truncations"])
        while True:
            # plan: lane -> (action_tuple, store_info | None)
            plan = {}
            for lane, lrn in owner_of.items():
                if states[lane] is None:
                    plan[lane] = (ACTIONS[1], None)  # (False, 0)
            for lrn in learners:
                live = [l for l in lrn.lane_ids if states[l] is not None]
                if live:
                    xs, acts, logps, vals = lrn.act_batch([states[l] for l in live])
                    for i, lane in enumerate(live):
                        a_idx = int(acts[i].item())
                        plan[lane] = (ACTIONS[a_idx], (lrn, xs[i], acts[i], logps[i], vals[i]))
            # отправка /control — последовательно (параллельные соединения медленнее!)
            for lane, (ac, info) in plan.items():
                body = {"lane": lane, "thrust": bool(ac[0]), "torque": float(ac[1])}
                try:
                    r = http_post("/control", body, timeout=5)
                    err_count = 0
                except Exception:
                    err_count += 1
                    r = None
                    if err_count > 300:
                        raise RuntimeError("too many API errors - is the game closed?")
                if r is None:
                    continue
                states[lane] = r
                reward = reward_tick(r)
                done = not r.get("alive", True)
                if done:
                    reward += CRASH_PENALTY
                lrn_owner = owner_of[lane]
                if info is not None:
                    _, xi, ai, lp, vl = info
                    lrn_owner.store_step(xi, ai, lp, vl, reward, done, lane)
                depth = float(r.get("depth_m", 0.0))
                lrn_owner.ep_ticks[lane] += 1
                lrn_owner.ep_reward[lane] += reward
                lrn_owner.ep_max_depth[lane] = max(lrn_owner.ep_max_depth[lane], depth)
                cap_hit = lrn_owner.ep_ticks[lane] >= TICK_CAP
                if done or cap_hit:
                    lrn_owner.finish_episode(lane, lrn_owner.ep_reward[lane], lrn_owner.ep_max_depth[lane],
                                             truncated=(not done))
                    states[lane] = None
                    respawn_lane(lane)
                    lrn_owner.ep_ticks[lane] = 0
                    lrn_owner.ep_reward[lane] = 0.0
                    lrn_owner.ep_max_depth[lane] = 0.0
            # апдейт, когда буфер полон
            for lrn in learners:
                if len(lrn.buf) >= BUFFER_STEPS:
                    t1 = time.time()
                    stats = lrn.update()
                    lrn.save(best=False)
                    if stats is not None:
                        mean_r = lrn.mean_ep_reward()
                        is_best = mean_r > lrn.best_mean_reward and len(lrn.ep_rewards_recent) >= BEST_WINDOW
                        if is_best:
                            lrn.best_mean_reward = mean_r
                            lrn.save(best=True)
                        w.writerow([stats["iter"], time.strftime("%Y-%m-%d %H:%M:%S"), lrn.tag,
                                    lrn.total_steps, f"{mean_r:.3f}", f"{lrn.mean_ep_depth():.2f}",
                                    f"{stats['pg_loss']:.4f}", f"{stats['vf_loss']:.4f}",
                                    f"{stats['ent']:.4f}", f"{stats['approx_kl']:.5f}",
                                    f"{time.time() - t1:.1f}", lrn.iter_deaths, lrn.iter_truncations])
                        logf.flush()
                        d_ct, t_ct = lrn.iter_deaths, lrn.iter_truncations
                        lrn.iter_deaths = lrn.iter_truncations = 0
                        print(f"[{lrn.tag}] iter {stats['iter']}: mean_rew={mean_r:.2f} "
                              f"depth={lrn.mean_ep_depth():.2f} ent={stats['ent']:.3f} "
                              f"kl={stats['approx_kl']:.4f} best={lrn.best_mean_reward:.2f} "
                              f"deaths={d_ct} trunc={t_ct}", flush=True)
            # страховка: никто не замораживается навечно (форс-респавн раз в N минут)
            if time.time() - last_respawn > INFINITY_CAP_S * 4:
                print("watchdog: force respawn all", flush=True)
                for lrn in learners:
                    lrn.respawn()
                for l in owner_of:
                    states[l] = None
                last_respawn = time.time()

def main():
    cuda_ok = torch.cuda.is_available()
    lanes = ensure_lanes(TARGET_LANES)
    set_time_scale(TIME_SCALE)
    print(f"lanes: {lanes}, cuda={cuda_ok}, time_scale={TIME_SCALE}", flush=True)
    learners = []
    if cuda_ok:
        # все расчёты — на GPU (оба лика); тег "cpu" оставлен для совместимости чекпоинтов
        learners.append(Learner("cuda", lanes[:GPU_LANES], "gpu"))
        learners.append(Learner("cuda", lanes[GPU_LANES:], "cpu"))
    else:
        print("warn: CUDA недоступна — всё на CPU", flush=True)
        learners.append(Learner("cpu", lanes, "cpu"))
    print("learners:", [(l.tag, l.lane_ids) for l in learners], flush=True)
    run_forever(learners)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("stopped by user", flush=True)
    except Exception as e:
        print("FATAL:", e, flush=True)
        raise
