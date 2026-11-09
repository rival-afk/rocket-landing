class_name TASSearch
extends RefCounted

# TAS-поиск: перебор всех возможных путей развития событий на каждом тике
# (60 Гц). Действия — 6 комбинаций: "−", "←", "→", "▲", "▲+←", "▲+→"
# (пусто / вращение влево / вращение вправо / тяга / тяга+влево / тяга+вправо).
#
# Полный перебор без ограничений растёт как 6^тики, поэтому на каждом тике
# оставляем BEAM лучших состояний (по близости к дну пещеры с учётом
# отклонения от центра коридора) и отбрасываем состояния, в которых ракета
# пересекается со стеной. Пещера детерминирована, формулы повторяют cave.gd
# один в один, физика — движок (см. _integrate), поэтому траектории
# предсказуемы и воспроизводимы.
#
# Цель: найти путь с максимальным рекордом (глубина, м) и минимальным временем.
# На выходе — лента TAS (inputs/samples) в том же формате, что пишет _tas_save,
# только samples пустые: verify для этой ленты проверяет выживание + инварианты
# (сравнение траекторий смысла не имеет — лента не записывалась в живой симуляции).

const TICK := 1.0 / 60.0
const GRAVITY := 980.0
const THRUST_ACCEL := 1500.0
const ANGULAR_VEL := 4.0      # rad/с при torque=±1 (как в torque.gd)
# Движок (Godot physics 2D, 4.x) сам гасит скорости каждый тик ДО применения
# сил: physics/2d/default_linear_damp=0.1, default_angular_damp=1.0.
# Без этого модель систематически перелетает по vy и rot за несколько сотен тиков.
const LINEAR_DAMP := 0.1      # vx, vy *= (1 - LINEAR_DAMP * TICK) — до сил
const ANGULAR_DAMP := 1.0     # ω *= (1 - ANGULAR_DAMP * TICK) — до интеграции угла
const ROCKET_HALF_W := 12.0   # половина ширины + 2 px запаса (коллизия 20x24)
const ROCKET_HALF_H := 14.0   # половина высоты + 2 px запаса

# те же константы, что в cave.gd — пещера обязана совпадать бит-в-бит
const MAX_SHIFT := 175.0
const MIN_HALF := 60.0
const HALF_VAR := 55.0
const KNOT := 256.0
const SOFTEN_Y := 3.0 * KNOT  # плавный выход из стартовой точки
const STEP := 16.0          # шаг точек ломаной стены (как cave.gd STEP)

const ACTIONS := [
	{"name": "-",   "thrust": false, "torque": 0.0},
	{"name": "←",   "thrust": false, "torque": -1.0},
	{"name": "→",   "thrust": false, "torque": 1.0},
	{"name": "▲",   "thrust": true,  "torque": 0.0},
	{"name": "▲+←", "thrust": true,  "torque": -1.0},
	{"name": "▲+→", "thrust": true,  "torque": 1.0},
]

const MAX_NODES := 1500000    # потолок памяти: дальше автостоп

var beam_width := 24
var max_ticks := 2700         # 45 с игрового времени

# --- пул узлов (SoA), узел = одно достигнутое состояние ---
var _px := PackedFloat32Array()
var _py := PackedFloat32Array()
var _pvx := PackedFloat32Array()
var _pvy := PackedFloat32Array()
var _prot := PackedFloat32Array()
var _parent := PackedInt32Array()
var _action := PackedInt32Array()

var _beam: Array[int] = []
var _actions_path := []       # не хранится — восстанавливается обходом родителей

var tick := 0
var explored := 0             # сколько состояний вообще сгенерировано
var collisions := 0           # сколько ветвей отброшено из-за пересечения со стеной
var done := false
var done_reason := ""         # "cap" | "all_dead" | "max_ticks" | "cancelled"

var best_node := -1
var best_y := 0.0
var best_tick := 0

var cancel_requested := false
var _gpu_fallback := false   # true → GPU-источник отказался, дальше считаем на CPU
var dbg_log := false         # отладка: печатать размер луча каждый тик

func begin(p_beam_width: int, p_max_ticks: int) -> void:
	beam_width = maxi(4, p_beam_width)
	max_ticks = maxi(60, p_max_ticks)
	_px = PackedFloat32Array([0.0])
	_py = PackedFloat32Array([0.0])
	_pvx = PackedFloat32Array([0.0])
	_pvy = PackedFloat32Array([0.0])
	_prot = PackedFloat32Array([0.0])
	_parent = PackedInt32Array([-1])
	_action = PackedInt32Array([-1])
	_beam = [0]
	tick = 0
	explored = 0
	collisions = 0
	done = false
	done_reason = ""
	best_node = 0
	best_y = 0.0
	best_tick = 0
	cancel_requested = false
	_gpu_fallback = false

func cancel() -> void:
	cancel_requested = true

# Продвигает перебор на n тиков (60 Гц). Вызывать каждый _process, пока !done.
func step(n_ticks: int) -> void:
	for _i in range(n_ticks):
		if done:
			return
		if cancel_requested:
			done = true
			done_reason = "cancelled"
			return
		var cand := {}
		var children: Variant = _generate_children(_beam)
		if children == null:
			# GPU-источник детей не сработал — повторяем тик на CPU
			_gpu_fallback = true
			children = _generate_children_cpu(_beam)
		for c in children:
			explored += 1
			if c[8] >= 0.5:
				collisions += 1
				continue
			var key := "%d,%d,%d,%d,%d" % [roundi(c[0] * 2.0), roundi(c[1] * 2.0), roundi(c[2]), roundi(c[3]), roundi(c[4] * 8.0)]
			if cand.has(key):
				continue
			cand[key] = [c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]]
		var arr: Array = cand.values()
		arr.sort_custom(func(a, b): return a[7] > b[7])
		if arr.is_empty():
			done = true
			done_reason = "all_dead"
			return
		if dbg_log:
			print("tick=%d beam_in=%d cand=%d coll_total=%d" % [tick, _beam.size(), arr.size(), collisions])
		var picked := _select_beam(arr, beam_width)
		var new_beam: Array[int] = []
		for i in range(picked.size()):
			var c: Array = picked[i]
			_px.append(c[0]); _py.append(c[1]); _pvx.append(c[2]); _pvy.append(c[3]); _prot.append(c[4])
			_parent.append(c[5]); _action.append(c[6])
			var node_idx := _px.size() - 1
			new_beam.append(node_idx)
			if c[1] > best_y:
				best_y = c[1]
				best_node = node_idx
				best_tick = tick + 1
		if _px.size() >= MAX_NODES:
			done = true
			done_reason = "cap"
			_beam = new_beam
			tick += 1
			return
		_beam = new_beam
		tick += 1
		if tick >= max_ticks:
			done = true
			done_reason = "max_ticks"

# По умолчанию — CPU-генерация. GPU-подкласс переопределяет и может
# вернуть null, если GPU не сработал (тогда step() сам повторит на CPU).
# Формат кандидата: [nx, ny, nvx, nvy, nrot, parent_node, action_idx, score, hit(0/1)]
func _generate_children(beam_ids: Array[int]) -> Variant:
	return _generate_children_cpu(beam_ids)

func _generate_children_cpu(beam_ids: Array[int]) -> Array:
	var out := []
	for nid in beam_ids:
		var px := _px[nid]
		var py := _py[nid]
		var pvx := _pvx[nid]
		var pvy := _pvy[nid]
		var prot := _prot[nid]
		for ai in range(ACTIONS.size()):
			var a: Dictionary = ACTIONS[ai]
			var r := _integrate(px, py, pvx, pvy, prot, a.thrust, a.torque)
			var nx: float = r[0]
			var ny: float = r[1]
			var nvx: float = r[2]
			var nvy: float = r[3]
			var nrot: float = r[4]
			out.append([nx, ny, nvx, nvy, nrot, nid, ai, _score(nx, ny, nvx, nvy), 1.0 if _hits_rock(nx, ny, nrot) else 0.0])
	return out

# Интегратор повторяет Godot 2D physics бит-в-бит (проверено трассировкой):
#   v *= (1 - LINEAR_DAMP * TICK)  →  v += (gravity [+ thrust]) * TICK  →  pos += v * TICK
#   ω (из torque.gd) *= (1 - ANGULAR_DAMP * TICK)  →  rot += ω * TICK
func _integrate(x: float, y: float, vx: float, vy: float, rot: float, thrust: bool, torque: float) -> Array:
	vx *= 1.0 - LINEAR_DAMP * TICK
	vy *= 1.0 - LINEAR_DAMP * TICK
	vy += GRAVITY * TICK
	if thrust:
		# Vector2.UP.rotated(rot) = (sin(rot), -cos(rot))
		vx += sin(rot) * THRUST_ACCEL * TICK
		vy += -cos(rot) * THRUST_ACCEL * TICK
	x += vx * TICK
	y += vy * TICK
	rot += torque * ANGULAR_VEL * (1.0 - ANGULAR_DAMP * TICK) * TICK
	return [x, y, vx, vy, rot]

# 9 контрольных точек ракеты (центр + углы + середины рёбер повёрнутого
# прямоугольника) с запасом 2 px — касание стены засчитывается раньше, чем
# реальный kill-polygon. Иначе лента, «чисто» прошедшая модель, в реальной
# физике цепляет стену ребром между углами.
func _hits_rock(x: float, y: float, rot: float) -> bool:
	var c := cos(rot)
	var s := sin(rot)
	var pts := PackedVector2Array()
	pts.append(Vector2(x, y))
	for sx: float in [-1.0, 0.0, 1.0]:
		for sy: float in [-1.0, 0.0, 1.0]:
			if sx == 0.0 and sy == 0.0:
				continue
			var lx: float = sx * ROCKET_HALF_W
			var ly: float = sy * ROCKET_HALF_H
			pts.append(Vector2(x + lx * c - ly * s, y + lx * s + ly * c))
	for p in pts:
		if _hits_point(p.x, p.y):
			return true
	return false

# Стена в cave.gd — ломаная по точкам каждые STEP px (ровно тот же полигон,
# что у kill-Area2D), а НЕ гладкий коридор. В местах излома стена чуть
# ближе, чем smooth-кривая, и 2 px запаса полуширины ракеты это перекрывают
# не всегда — поэтому проверяем именно ломаную (бит-в-бит с игрой).
func _hits_point(px: float, py: float) -> bool:
	var y0: float = floorf(py / STEP) * STEP
	var t: float = (py - y0) / STEP
	var c0 := cave_center(y0)
	var c1 := cave_center(y0 + STEP)
	var h0 := cave_half(y0)
	var h1 := cave_half(y0 + STEP)
	if px <= lerpf(c0 - h0, c1 - h1, t):
		return true
	if px >= lerpf(c0 + h0, c1 + h1, t):
		return true
	return false

# оценка пригодности ветви: глубже = лучше; штраф за отклонение от центра
# (с небольшим упреждающим весом) и ГЛАВНОЕ — за скорость падения выше
# ~235 px/s: в стену упирается весь одинаковый по vy луч разом, поэтому
# ветви с торможением должны выживать (см. TAS_TGT_FALL_VY у бота).
func _score(x: float, y: float, vx: float, vy: float) -> float:
	var score := y
	score -= _corridor_off2(x, y) * 60.0
	score -= _corridor_off2(x, y + 240.0) * 90.0
	score -= absf(vx) * 0.15
	score -= maxf(0.0, vy - 235.0) * 0.22
	return score

func _corridor_off2(x: float, y: float) -> float:
	var c := cave_center(y)
	var h := cave_half(y)
	var off := absf(x - c) / maxf(h, 1.0)
	return off * off

# Диверсифицированный отбор: по одной лучшей ветви из каждой x-ячейки коридора
# (равномерное покрытие), затем добор по score. Жадный топ-K схлопывает луч
# в почти одинаковые состояния — так он вымирает задолго до конца забега.
func _select_beam(arr: Array, width: int) -> Array:
	var picked: Array = []
	var used := {}
	for c in arr:  # arr отсортирован по убыванию score
		# диверсификация: x-ячейка + полоса скорости падения (по vy)
		var bucket := int(floorf(float(c[0]) / 48.0)) + int(floorf(float(c[3]) / 60.0)) * 100
		if not used.has(bucket):
			used[bucket] = true
			picked.append(c)
		if picked.size() >= width:
			return picked
	for c in arr:
		if not picked.has(c):
			picked.append(c)
		if picked.size() >= width:
			break
	return picked

# --- пещера: бит-в-бит с cave.gd ---
func _cave_hash(n: float) -> float:
	var s := sin(n * 127.1 + 311.7) * 43758.5453
	return s - floor(s)

func _knot_offset(k: float) -> float:
	if k == 0.0:
		return 0.0
	return (_cave_hash(k) * 2.0 - 1.0) * MAX_SHIFT

func _knot_half(k: float) -> float:
	return MIN_HALF + _cave_hash(k + 1000.0) * HALF_VAR

func cave_center(y: float) -> float:
	var k := floorf(y / KNOT)
	var t := (y - k * KNOT) / KNOT
	var v := lerpf(_knot_offset(k), _knot_offset(k + 1.0), t)
	return v * clampf(absf(y) / SOFTEN_Y, 0.0, 1.0)

func cave_half(y: float) -> float:
	var k := floorf(y / KNOT)
	var t := (y - k * KNOT) / KNOT
	return lerpf(_knot_half(k), _knot_half(k + 1.0), t)

func best_depth_m() -> float:
	return maxf(0.0, best_y) / 50.0

func best_time_s() -> float:
	return float(best_tick) / 60.0

func progress() -> Dictionary:
	return {
		"tick": tick,
		"explored": explored,
		"collisions": collisions,
		"beam": _beam.size(),
		"nodes": _px.size(),
		"best_depth_m": snappedf(best_depth_m(), 0.01),
		"best_time_s": snappedf(best_time_s(), 0.01),
		"done": done,
		"done_reason": done_reason,
	}

# Лента по лучшему найденному пути. Тот же формат, что пишет _tas_save,
# samples пустые — verify будет проверять выживание + инварианты.
func best_tape() -> Dictionary:
	var actions: Array[int] = []
	var n := best_node
	while n > 0:
		actions.append(_action[n])
		n = _parent[n]
	actions.reverse()
	var inputs := []
	for ai in actions:
		var a: Dictionary = ACTIONS[ai]
		inputs.append({"thrust": a.thrust, "torque": a.torque})
	return {
		"version": 1,
		"created": Time.get_datetime_string_from_system(),
		"engine": "tas-search",
		"spawn_y": 0.0,
		"final_depth_m": best_depth_m(),
		"ticks": inputs.size(),
		"best_time_s": best_time_s(),
		"inputs": inputs,
		"samples": [],
		"source": "search",
		"stats": {
			"explored": explored,
			"collisions": collisions,
			"beam_width": beam_width,
			"ticks": tick,
			"done_reason": done_reason,
		},
	}
