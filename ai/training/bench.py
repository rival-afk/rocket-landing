# -*- coding: utf-8 -*-
"""Бенчмарк Rocket Landing: latency API при разном числе lane и time_scale.
Меряем только живые (полные) лидарные рейкасты, поэтому перед замером респавним все игры.
Выход: таблица CSV + печать. В конце не трогаем конфигурацию (ts=2.0 ставим обратно)."""
import json
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

HOST = 'http://127.0.0.1:8080'
START_LANES = 16           # сколько есть сейчас
MAX_LANES = 48
STEP = 8
TS_LIST = [1.0, 2.0, 4.0, 8.0]
N_REQ = 48

def get(path, timeout=10):
    return json.loads(urllib.request.urlopen(HOST + path, timeout=timeout).read().decode())

def post(path, payload, timeout=10):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(HOST + path, data=data, headers={'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode())

def delete_lane(n):
    req = urllib.request.Request(f'{HOST}/lane?lane={n}', method='DELETE')
    try:
        urllib.request.urlopen(req, timeout=10).read()
        return True
    except Exception:
        return False

def ensure_lanes(n):
    h = get('/health')
    while h['lanes'] < n:
        post('/spawn', {})
        time.sleep(0.15)
        h = get('/health')
    # удалим лишние (кроме последней), если их больше надо
    ids = [l['lane'] for l in get('/state')['lanes']]
    while len(ids) > n:
        victim = max(ids)
        if delete_lane(victim):
            ids.remove(victim)
        else:
            break
    return [l['lane'] for l in get('/state')['lanes']]

def set_ts(s):
    try:
        post('/speed', {'scale': s})
    except Exception as e:
        print('  warn set_ts', e, flush=True)

def respawn_all(ids):
    for i in ids:
        try:
            post('/respawn', {'lane': i}, timeout=10)
        except Exception:
            pass

def dead_count(ids):
    try:
        lanes = get('/state')['lanes']
        return sum(1 for l in lanes if not l['alive']), len(lanes)
    except Exception:
        return -1, -1

def bench_round(ids, parallel_workers=12):
    ids = list(ids)
    import random
    random.shuffle(ids)
    # последовательный проход
    t0 = time.time()
    for i in ids[:N_REQ]:
        get(f'/state?lane={i}')
    seq_ms = (time.time() - t0) / len(ids[:N_REQ]) * 1000
    # параллельный проход (12 воркеров как в тренажёре-не-используется, но пусть будет)
    sample = (ids * 4)[:N_REQ]
    t0 = time.time()
    with ThreadPoolExecutor(parallel_workers) as ex:
        list(ex.map(lambda i: get(f'/state?lane={i}'), sample))
    par_ms = (time.time() - t0) / len(sample) * 1000
    return seq_ms, par_ms

results = []
print('capacity test: lanes x time_scale', flush=True)
try:
    # сначала докладываем до MAX_LANES один раз, замеряя по пути
    cur = ensure_lanes(START_LANES)
    cur = [l['lane'] for l in get('/state')['lanes']]
    print('start lanes:', len(cur), flush=True)
    lane_counts = list(range(START_LANES, MAX_LANES + 1, STEP))
    for target in lane_counts:
        ids = ensure_lanes(target)
        ids = [l['lane'] for l in get('/state')['lanes']]
        for ts in TS_LIST:
            set_ts(ts)
            time.sleep(0.5)
            respawn_all(ids)
            time.sleep(0.3)
            d, tot = dead_count(ids)
            seq_ms, par_ms = bench_round(ids)
            line = (target, ts, round(seq_ms, 2), round(par_ms, 2))
            results.append(line)
            print('lanes=%d ts=%.1f seq=%.2f ms/req par=%.2f ms/req dead=%d/%d' %
                  (target, ts, seq_ms, par_ms, d, tot), flush=True)
    # обратно в строй
    set_ts(2.0)
    print('restored time_scale=2.0', flush=True)
finally:
    with open(r'C:\Users\stude\OneDrive\Рабочий стол\ivanovich\rocket-ai\training\bench_results.txt', 'w', encoding='utf-8') as f:
        f.write('lanes,time_scale,seq_ms_per_req,par_ms_per_req\n')
        for r in results:
            f.write('%d,%.1f,%.2f,%.2f\n' % r)
    print('saved training/bench_results.txt', flush=True)
