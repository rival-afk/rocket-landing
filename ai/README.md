# rocket-landing / ai — обучение нейросети играть в Rocket Landing

Обучение нейросети играть в [Rocket Landing](../game) (ракетный пролёт через
пещеру) через встроенный HTTP API игры. Папка самодостаточная: код, скрипты,
чекпоинты, результаты.

## Запуск обучения

1. Запусти игру в окне (`--headless` не используется):
   ```powershell
   RocketLanding.exe -- --spawn=8
   ```
2. Сеть считается на GPU (в `.venv` уже стоит `torch 2.15.0+cu132`):
   ```powershell
   & .\.venv\Scripts\python.exe .\training\ppo_train.py
   ```
3. Прогресс: `training\ppo\ppo_log.csv` —
   `mean_ep_reward`, `mean_ep_depth`, `entropy`, `deaths` / `truncations`.

## Структура

- `training/ppo_train.py` — PPO (PyTorch 2.15+CUDA), действия дискретные (6),
  награда: удаление от объектов (min лидара) + вертикальный нос + знаковый vy
  (вниз — плюс) − |vx|/|vy| − краш 2.0.
- `training/train.py` — ранняя эволюционная версия (GA, numpy), для сравнения.
- `training/bench.py` — бенчмарк пропускной способности API
  (мс/запрос при разных lanes × time_scale).
- `training/*.json` — лучшие чекпоинты GA (`best.v1-52m.backup.json` =
  историческая запись 52.92 м).
- `training/ppo/*.pt` — последние и лучшие веса PPO (best — по mean reward
  за 20 эпизодов).

## Результаты

| Путь | Что |
|---|---|
| `training/bench_results.txt` | latency vs lanes × time_scale |
| `training/ppo/*.pt` | финальные и промежуточные веса нейросети |
| `training/ppo/ppo_log.csv` | итерации обучения PPO |
| `training/log.csv` | то же для GA-версии |

## Заметки

- Игра детерминирована, поэтому TAS-оптимизация (идеальная трасса ввода)
  ищется локальным поиском и RL поверх неё.
- API отвечает ~7 мс на запрос последовательно; параллельные — медленнее.
