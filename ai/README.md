# rocket-landing / ai — обучение нейросети играть в Rocket Landing

Обучение нейросети играть в [Rocket Landing](../game) (ракетный пролёт через
пещеру) через встроенный HTTP API игры. Папка самодостаточная: код, скрипты,
чекпоинты, результаты.

## Текущие результаты (2026-11-09)

- **PPO** (главная ветка): итерации 89 (gpu) / 85 (cpu) с последнего рестарта
  чекпоинтов; best mean reward ≈ **58.97 / 59.11**, против ~5–7 в начале дня —
  сеть уверенно держится в пещере (см. `training/ppo/ppo_log.csv`,
  `docs/img/chart_ppo.png`).
- **GA** (ранняя эволюционная версия, numpy): рекорд **52.92 м** за 241
  поколение (`training/log.csv`, `docs/img/chart_ga.png`).
- **TAS**: идеальный забег **59.60 м, 2279 тиков**, лента проверена в реальной
  физике игры — PASS (`tas/tape.json`, `../docs/TAS.md`).

## Запуск обучения

### Linux (этот репозиторий)

```bash
# 1) игра headless с HTTP API (порт 8080)
godot --headless --path game -- --spawn=8 &

# 2) обучение (CUDA); ~40 итераций за ~30 минут
../ai-venv/bin/python training/ppo_train.py
```

### Windows (как было изначально)

1. Запусти игру в окне (`--headless` не используется):
   ```powershell
   RocketLanding.exe -- --spawn=8
   ```
2. Сеть считается на GPU:
   ```powershell
   & .\.venv\Scripts\python.exe .\training\ppo_train.py
   ```
3. Прогресс: `training\ppo\ppo_log.csv` —
   `mean_ep_reward`, `mean_ep_depth`, `entropy`, `deaths` / `truncations`.

Остановка — `Ctrl+C` (чекпоинты сохраняются каждую итерацию; при следующем
запуске обучение возобновляется с `*_last.pt`). Для полного цикла замени
`--spawn=8` и `TIME_SCALE` в `ppo_train.py` под себя.

## Структура

- `training/ppo_train.py` — PPO (PyTorch 2.6+CUDA в `../ai-venv`), действия
  дискретные (6), награда: удаление от объектов (min лидара) + вертикальный нос +
  знаковый vy (вниз — плюс) − |vx|/|vy| − краш 2.0.
- `training/train.py` — ранняя эволюционная версия (GA, numpy), для сравнения.
- `training/bench.py` — бенчмарк пропускной способности API
  (мс/запрос при разных lanes × time_scale).
- `training/*.json` — лучшие чекпоинты GA (`best.v1-52m.backup.json` =
  историческая запись 52.92 м).
- `training/ppo/*.pt` — последние и лучшие веса PPO (best — по mean reward
  за 20 эпизодов).
- `tas/tape.json` — TAS-лента: 59.60 м, 2279 тиков (расчёт
  `game/tas_headless.gd`, beam 96/128, проверка `/tas/verify` — PASS,
  `max_err=0.65 px`; подробности — `../docs/TAS.md`).

## Результаты

| Путь | Что |
|---|---|
| `training/bench_results.txt` | latency vs lanes × time_scale |
| `training/ppo/*.pt` | финальные и промежуточные веса нейросети |
| `training/ppo/ppo_log.csv` | итерации обучения PPO |
| `training/log.csv` | то же для GA-версии |
| `tas/tape.json` | идеальный забег (проверенная TAS-лента) |

## Заметки

- Игра детерминирована; модель TAS откалибрована по трассировке движка
  (см. `../docs/TAS.md`): linear_damp=0.1, angular_damp=1.0 — без них любая
  лента расходится за несколько сотен тиков.
- API отвечает ~7 мс на запрос последовательно; параллельные — медленнее
  (см. bench_results.txt). Для управляющих агентов держите `time_scale = 1.0`.
