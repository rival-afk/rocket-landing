extends Node2D

# Бесконечная процедурная пещера вниз.
# Коридор — аналитическая функция глубины y (узлы каждые KNOT px, линейная
# интерполяция между ними, хеш от номера узла). Всё детерминированно.
# Никаких сегментов/статик-тел не создаётся — пещера бесконечна,
# потребление памяти постоянно независимо от глубины.
# lane_offset сдвигает всю пещеру по x (для параллельных игр).

const KNOT := 256.0         # расстояние между узлами ломаной
const MAX_SHIFT := 175.0    # макс. горизонтальное смещение коридора на узел
const MIN_HALF := 60.0      # мин. полуширина коридора
const HALF_VAR := 55.0      # разброс полуширины

const ROCK_COLOR := Color(0.24, 0.17, 0.13)
const RIM_COLOR := Color(0.37, 0.28, 0.21)
const VIEW_W := 1700.0        # ширина GPU-квада стен
const VIEW_H := 2100.0        # высота GPU-квада стен (покрывает экран)
const KNOT_TEX_W := 32        # узлов в таблице для шейдера

@export var lane_offset := 0.0

# Кому сообщать о касании стены (game.gd). Если не задан — перезагрузка сцены.
var killer_callback: Callable = Callable()

var rocket: Node2D
var reloading := false

# GPU-отрисовка стен: один ColorRect с canvas_item шейдером + таблица узлов
var wall_rect: ColorRect
var knot_img: Image
var knot_tex: ImageTexture
var knot_base := -1000000000

func _ready() -> void:
	if rocket == null:
		rocket = get_node_or_null("../Rocket")
	_build_wall_shader()
	_update_wall_tex()

func _physics_process(_delta: float) -> void:
	# шейдер-квад едет за ракетой каждый кадр (отрисовка на GPU)
	if wall_rect != null and rocket != null:
		wall_rect.global_position = Vector2(-VIEW_W / 2.0, rocket.global_position.y - VIEW_H * 0.5)
	_update_wall_tex()

	# аналитическая проверка столкновения (никаких статик-тел — память не растёт)
	if rocket != null:
		if _obb_outside_corridor(rocket):
			_kill_rocket()

func _build_wall_shader() -> void:
	if wall_rect != null:
		return
	knot_img = Image.create(KNOT_TEX_W, 1, false, Image.FORMAT_RGF)
	knot_tex = ImageTexture.create_from_image(knot_img)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://cave_walls.gdshader")
	mat.set_shader_parameter("knot_tex", knot_tex)
	mat.set_shader_parameter("knot_start", 0.0)
	wall_rect = ColorRect.new()
	wall_rect.name = "WallShader"
	wall_rect.size = Vector2(VIEW_W, VIEW_H)
	wall_rect.material = mat
	wall_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(wall_rect)
	wall_rect.show_behind_parent = false
	move_child(wall_rect, 0)   # под ракету

func _update_wall_tex() -> void:
	# таблица узлов пересобирается только при смещении окна
	if rocket == null or wall_rect == null:
		return
	var y := rocket.global_position.y
	var base := int(floor(y / KNOT)) - 2
	if base == knot_base:
		return
	knot_base = base
	for i in range(KNOT_TEX_W):
		var k := float(base + i)
		var off := 0.0 if k == 0.0 else (cave_hash(k) * 2.0 - 1.0) * MAX_SHIFT
		knot_img.set_pixel(i, 0, Color(off + lane_offset, knot_half(k), 0.0))
	knot_tex.update(knot_img)
	wall_rect.material.set_shader_parameter("knot_start", float(base))

# ВНИМАНИЕ: не называть функцию `hash` — unqualified вызов `hash(...)` внутри
# класса резолвится в нативную Object.hash(), а не в эту функцию.
func cave_hash(n: float) -> float:
	var s := sin(n * 127.1 + 311.7) * 43758.5453
	return s - floor(s)

func knot_offset(k: float) -> float:
	if k == 0.0:
		return 0.0  # старт строго по центру
	return (cave_hash(k) * 2.0 - 1.0) * MAX_SHIFT

func knot_half(k: float) -> float:
	return MIN_HALF + cave_hash(k + 1000.0) * HALF_VAR

func center_at(y: float) -> float:
	var k := floorf(y / KNOT)
	var t := (y - k * KNOT) / KNOT
	var v := lerpf(knot_offset(k), knot_offset(k + 1.0), t)
	# плавный выход из стартовой точки, чтобы ракета не упёрлась в стену на старте
	return v * clampf(absf(y) / (3.0 * KNOT), 0.0, 1.0)

func half_at(y: float) -> float:
	var k := floorf(y / KNOT)
	var t := (y - k * KNOT) / KNOT
	return lerpf(knot_half(k), knot_half(k + 1.0), t)

func left_x(y: float) -> float:
	return center_at(y) - half_at(y) + lane_offset

func right_x(y: float) -> float:
	return center_at(y) + half_at(y) + lane_offset

func point_in_corridor(px: float, py: float) -> bool:
	var c := center_at(py) + lane_offset
	return px >= c - half_at(py) and px <= c + half_at(py)

# Аналитический лидар: маршируем луч до упора в стену (или max_dist),
# затем уточняем границу бисекцией. Точность ~0.1 px, без физтел.
# dir должен быть НЕ нулевым вектором; длина возвращаемого расстояния в px.
func corridor_ray_distance(origin: Vector2, dir: Vector2, max_dist: float) -> float:
	var d := dir.normalized()
	var step := 2.0
	var t := step
	var last_inside := 0.0
	while t <= max_dist:
		if not point_in_corridor(origin.x + d.x * t, origin.y + d.y * t):
			# уточняем границу бисекцией на [last_inside, t]
			var lo := last_inside
			var hi := t
			for _i in range(10):
				var mid := (lo + hi) * 0.5
				if point_in_corridor(origin.x + d.x * mid, origin.y + d.y * mid):
					lo = mid
				else:
					hi = mid
			return (lo + hi) * 0.5
		last_inside = t
		t += step
	# не уперлись — проверяем конечную точку
	if not point_in_corridor(origin.x + d.x * max_dist, origin.y + d.y * max_dist):
		var lo := last_inside
		var hi := max_dist
		for _i in range(10):
			var mid := (lo + hi) * 0.5
			if point_in_corridor(origin.x + d.x * mid, origin.y + d.y * mid):
				lo = mid
			else:
				hi = mid
		return (lo + hi) * 0.5
	return max_dist

# Аналитическая проверка: выходит ли OBB ракеты за коридор (касание породы).
# Форма 20×24 (см. rocket.tscn), центр коллайдера на (0, -2) от корня.
# Центр OBB бывает строго внутри коридора, пока рот в стене, поэтому сэмплируем
# периметр (5 точек на каждую из 4 сторон).
func _obb_outside_corridor(r: Node2D) -> bool:
	var rad := r.rotation
	var pos := r.global_position
	var center := pos + Vector2(0.0, -2.0).rotated(rad)
	var hw := 10.0
	var hh := 12.0
	var u := Vector2(hw, 0.0).rotated(rad)   # полу-ось по локальной X
	var v := Vector2(0.0, hh).rotated(rad)   # полу-ось по локальной Y
	# 4 угла
	for i in range(4):
		var sx := 1.0 if (i == 1 or i == 2) else -1.0
		var sy := 1.0 if (i >= 2) else -1.0
		if not point_in_corridor((center + u * sx + v * sy).x, (center + u * sx + v * sy).y):
			return true
	# четверти сторон (между углами)
	for frac: float in [0.25, 0.5, 0.75]:
		var a: float = lerp(-1.0, 1.0, frac)
		var samples: Array[Vector2] = [center + u + v * a, center - u + v * a, center + u * a + v, center + u * a - v]
		for p: Vector2 in samples:
			if not point_in_corridor(p.x, p.y):
				return true
	return false

func _kill_rocket() -> void:
	if killer_callback.is_valid():
		killer_callback.call(rocket)
		return
	if reloading:
		return
	reloading = true
	# reload_current_scene() во время физического колбэка запрещён — откладываем
	get_tree().call_deferred("reload_current_scene")
