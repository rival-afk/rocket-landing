extends Node2D

# Бесконечная процедурная пещера вниз.
# Коридор — ломаная через узлы каждые KNOT px: смещение узлов и ширина
# считаются хешем от индекса узла, промежуточные точки — линейная
# интерполяция, поэтому на узлах всегда острые углы.
# Всё детерминированно: пещера одинаковая из запуска в запуск.
# lane_offset сдвигает всю пещеру по x (нужно для параллельных игр).

const SEG_H := 256.0        # высота одного сегмента, px (один узел на сегмент)
const KNOT := 256.0         # расстояние между узлами ломаной
const STEP := 16.0          # шаг точек вдоль стены, px (делитель KNOT)
const FAR := 1100.0         # ширина «каменного» массива за стеной
const LOOKAHEAD := 1600.0   # на сколько ниже камеры генерировать
const BEHIND := 700.0       # на сколько выше камеры ещё держим сегменты

const MAX_SHIFT := 175.0    # макс. горизонтальное смещение коридора на узел (извилистее)
const MIN_HALF := 60.0      # мин. полуширина коридора (уже)
const HALF_VAR := 55.0      # разброс полуширины

const ROCK_COLOR := Color(0.24, 0.17, 0.13)
const RIM_COLOR := Color(0.37, 0.28, 0.21)
const VIEW_W := 1700.0        # ширина GPU-квада стен
const VIEW_H := 2100.0        # высота GPU-квада стен (покрывает экран)
const KNOT_TEX_W := 32        # узлов в таблице для шейдера

@export var lane_offset := 0.0

# Кому сообщать о касании стены (game.gd). Если не задан — перезагрузка сцены.
var killer_callback: Callable = Callable()

var segments: Dictionary = {}
var rocket: Node2D
var reloading := false
var _last_knot := -1000000000

# GPU-отрисовка стен: один ColorRect с canvas_item шейдером + таблица узлов
var wall_rect: ColorRect
var knot_img: Image
var knot_tex: ImageTexture
var knot_base := -1000000000

func _ready() -> void:
	if rocket == null:
		rocket = get_node_or_null("../Rocket")
	_build_wall_shader()
	_update_segments()
	_update_wall_tex()

func _physics_process(_delta: float) -> void:
	# шейдер-квад едет за ракетой каждый кадр (отрисовка на GPU)
	if wall_rect != null and rocket != null:
		wall_rect.global_position = Vector2(-VIEW_W / 2.0, rocket.global_position.y - VIEW_H * 0.5)
	_update_segments()
	_update_wall_tex()

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
		knot_img.set_pixel(i, 0, Color(off, knot_half(k), 0.0))
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

func _update_segments() -> void:
	if rocket == null:
		return
	var y := rocket.global_position.y
	# узлы меняются раз в SEG_H — между узлами окно генерации не трогаем
	var knot := int(floor(y / SEG_H))
	if knot == _last_knot:
		return
	_last_knot = knot
	var i0 := int(floor((y - BEHIND) / SEG_H))
	var i1 := int(floor((y + LOOKAHEAD) / SEG_H))
	for i in range(i0, i1 + 1):
		if not segments.has(i):
			segments[i] = _build_segment(i)
	for i in segments.keys():
		if i < i0 - 1 or i > i1 + 1:
			segments[i].queue_free()
			segments.erase(i)

func _build_segment(i: int) -> StaticBody2D:
	var seg := StaticBody2D.new()
	seg.name = "CaveSegment_%d" % i
	seg.collision_layer = 2   # стены только на слое 2 (для лидаров и столкновений ракеты)
	seg.collision_mask = 0
	var y0 := i * SEG_H
	var y1 := y0 + SEG_H
	var edge_left := _edge_points(y0, y1, true)
	var edge_right := _edge_points(y0, y1, false)
	_add_side(seg, edge_left, true, y0, y1)
	_add_side(seg, edge_right, false, y0, y1)

	# Детектор касания стен ракетой (kill plane)
	_add_killer(seg, edge_left, true, y0, y1)
	_add_killer(seg, edge_right, false, y0, y1)

	add_child(seg)
	return seg

func _side_polygon(edge: PackedVector2Array, is_left: bool, y0: float, y1: float) -> PackedVector2Array:
	var poly := PackedVector2Array(edge)
	if is_left:
		poly.append(Vector2(lane_offset - FAR, y1))
		poly.append(Vector2(lane_offset - FAR, y0))
	else:
		poly.append(Vector2(lane_offset + FAR, y1))
		poly.append(Vector2(lane_offset + FAR, y0))
	return poly

func _edge_points(y0: float, y1: float, is_left: bool) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var y := y0
	while y < y1:
		pts.append(Vector2(left_x(y) if is_left else right_x(y), y))
		y += STEP
	# гарантируем точное попадание в узел (острый угол)
	pts.append(Vector2(left_x(y1) if is_left else right_x(y1), y1))
	return pts

func _add_side(seg: StaticBody2D, edge: PackedVector2Array, is_left: bool, y0: float, y1: float) -> void:
	var poly := _side_polygon(edge, is_left, y0, y1)
	# визуал теперь рисует GPU-шейдер (cave_walls.gdshader) — здесь только коллизия
	var col := CollisionPolygon2D.new()
	col.polygon = poly
	seg.add_child(col)

func _add_killer(seg: StaticBody2D, edge: PackedVector2Array, is_left: bool, y0: float, y1: float) -> void:
	var area := Area2D.new()
	area.collision_layer = 0
	area.collision_mask = 1  # только ракеты (слой 1)
	area.body_entered.connect(_on_wall_touched)
	var col := CollisionPolygon2D.new()
	col.polygon = _side_polygon(edge, is_left, y0, y1)
	area.add_child(col)
	seg.add_child(area)

func _on_wall_touched(body: Node2D) -> void:
	if killer_callback.is_valid():
		killer_callback.call(body)
		return
	if reloading:
		return
	reloading = true
	# reload_current_scene() во время физического колбэка запрещён — откладываем
	get_tree().call_deferred("reload_current_scene")
