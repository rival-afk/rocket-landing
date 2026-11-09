extends Node2D

# Rocket Landing: логика счёта, HTTP API, параллельные игры (swarm).
# Каждая параллельная игра = свой SubViewport со своим World2D: своя физика,
# своя пещера (одинаковая, детерминированная), своя камера и своя панель
# данных на экране. Окно делится сеткой по числу игр.
#
# API-хост (api_host.gd) живёт ДОЧЕРНИМ УЗЛОМ /root и переживает перезагрузку
# сцены: во время перезагрузки API отвечает 503 + Retry-After вместо сброса
# соединения. Клиенты: ретрайте через ~500 мс, отказов быть не должно.
#
# API (по умолчанию на 127.0.0.1:8080, порт меняется аргументом --port=N):
# см. API_README.md — полное описание всех эндпоинтов.

const VERSION := "1.1.0"     # перезаписывается build-скриптом
const COMMIT := "dev"        # перезаписывается build-скриптом
const BUILD_DATE := ""       # перезаписывается build-скриптом

const LIDAR_RANGE := 280.0
const BEST_PATH := "user://rocket_landing_best.txt"
const MAX_TIME_SCALE := 20.0
const SV_W := 480
const SV_H := 270
const SV_MIN_H := 90        # мин. высота кадра игры
const HUD_HZ_MS := 100      # HUD перерисовываем не чаще ~10 раз в сек
const LANE_COLORS := [
	Color(1.0, 0.75, 0.25),
	Color(0.35, 0.85, 1.0),
	Color(1.0, 0.45, 0.75),
	Color(0.55, 1.0, 0.45),
	Color(0.75, 0.6, 1.0),
	Color(1.0, 0.55, 0.35),
]

var lanes: Array = []
var next_lane_id := 0       # ids лейнов никогда не переиспользуются
var best := 0
static var _shot_deadline := -1
static var _shot_path := ""
static var _spawn_extra := 0
static var _version_printed := false
static var _api_banner_printed := false
static var _api_timing := false
var api_host: Node = null
var _menu: Node = null
var _touch: Node = null

# кэш готовых JSON-ответов на /state (одно и то же в пределах физтика)
var _state_cache_tick := -1
var _state_cache_all := ""
var _state_cache_lane := {}
var _api_req_count := 0
var _api_req_ms := 0.0
var _api_poll_ms := 0.0
var _api_next_print := 0

var _physics_tick := 0
var _hud_last_msec := 0
var _grid_layer: CanvasLayer
var _grid: GridContainer
var _port_busy_layer: CanvasLayer = null
var _stats_panel: PanelContainer = null
var _stats_rows := {}          # lane_id -> Dictionary{title:Label, stats:Label}
var _stats_footer_top: Label = null
var _stats_footer_sub: Label = null
var _stats_visible_applied := false

func _ready() -> void:
	var port := 8080
	var quit_if_port_busy := false
	var user_args := OS.get_cmdline_user_args()
	for arg in user_args + OS.get_cmdline_args():
		if arg.begins_with("--port="):
			port = int(arg.split("=")[1])
		elif arg == "--quit-if-port-busy":
			quit_if_port_busy = true
		elif arg == "--api-timing":
			_api_timing = true
		elif arg.begins_with("--spawn="):
			_spawn_extra = int(arg.split("=")[1])

	if not _version_printed:
		_version_printed = true
		print("Rocket Landing %s (%s)%s" % [VERSION, COMMIT, (" built " + BUILD_DATE) if BUILD_DATE != "" else ""])

	best = _load_best()

	# Корневая сетка экрана для параллельных игр
	_grid_layer = CanvasLayer.new()
	_grid_layer.layer = 10
	add_child(_grid_layer)
	# Обёртка: слева сетка игр, справа — сессионная статистика (видна в swarm)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.offset_left = 6
	margin.offset_top = 6
	margin.offset_right = -6
	margin.offset_bottom = -6
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid_layer.add_child(margin)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	margin.add_child(hbox)

	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(_grid)
	_stats_panel = _create_stats_panel()
	hbox.add_child(_stats_panel)

	# Первая игра (lane 0)
	_create_lane()
	# Доп. игры по аргументу --spawn=N
	for i in _spawn_extra:
		_create_lane()
	_relayout_grid()

	# Персистентный API-хост (переживает reload сцены)
	api_host = _get_api_host()
	api_host.game = self
	var err: int = api_host.start(port)
	if not _api_banner_printed:
		_api_banner_printed = true
		if err != OK:
			print("Rocket Landing API: порт %d занят (код %d) — API отключено, игра работает как обычно" % [port, err])
			_show_port_busy_banner(port)
		else:
			print("Rocket Landing API: http://127.0.0.1:%d" % port)

	if quit_if_port_busy and err != OK:
		get_tree().quit()
		return

	# Меню — только при обычном запуске (не API, не headless, не --shot).
	# --api: запуск «через API» (тренажёр): меню не показываем вовсе.
	# Любой запрос к API также автоматически закрывает меню (см. _handle_request).
	if DisplayServer.get_name() != "headless":
		var suppressed := false
		for arg in user_args + OS.get_cmdline_args():
			if arg == "--api" or arg == "--shot":
				suppressed = true
		if not suppressed:
			_menu = preload("res://menu.gd").new()
			_menu.game_ref = self
			add_child(_menu)
		# Сенсорное управление — только в Android-сборке
		_touch = preload("res://touch.gd").new()
		add_child(_touch)

	# debug-флаг: --shot <path.png> — снять кадр через 1.5 сек и выйти.
	for i in user_args.size():
		if user_args[i] == "--shot" and i + 1 < user_args.size():
			_shot_path = user_args[i + 1]
			_shot_deadline = Time.get_ticks_msec() + 1500

func _exit_tree() -> void:
	# сцена умерла (reload) — хост начинает отвечать 503, пока новая не поднимется
	if api_host != null:
		api_host.game = null

func _get_api_host() -> Node:
	# autoload RocketApiHost создаётся до главной сцены и переживает reload
	return get_tree().root.get_node_or_null("RocketApiHost")

func _show_port_busy_banner(port: int) -> void:
	# заметное системное уведомление внутри игры: API отключён
	if _port_busy_layer != null:
		return
	_port_busy_layer = CanvasLayer.new()
	_port_busy_layer.layer = 30
	add_child(_port_busy_layer)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	margin.offset_left = 8
	margin.offset_bottom = -8
	margin.offset_top = -44
	_port_busy_layer.add_child(margin)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.45, 0.08, 0.08, 0.9)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", sb)
	margin.add_child(panel)
	var lbl := Label.new()
	lbl.text = "API отключено: порт %d занят — игра идёт без внешнего управления" % port
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(1, 0.8, 0.8))
	panel.add_child(lbl)

func _physics_process(_delta: float) -> void:
	_physics_tick += 1
	for lane in lanes:
		if lane.tas.mode != "idle":
			_tas_tick(lane)
		if lane.alive:
			var r: Node2D = lane.rocket
			# знаковая глубина: ниже спавна — плюс, выше спавна — минус
			var depth: float = (r.global_position.y - lane.spawn_y) / 50.0
			lane.cur_depth = depth
			if depth > lane.max_depth:
				lane.max_depth = depth  # исторический максимум (для рекордов)
		# лидары/угол пересчитываем через раз (30 Гц) — экономия на рейкастах
		if _physics_tick % 2 == 0 or lane.cache_tick == -1:
			_refresh_lane_cache(lane)

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _hud_last_msec >= HUD_HZ_MS:
		_hud_last_msec = now
		_update_hud()

func _poll_shot() -> void:
	if _shot_deadline > 0 and Time.get_ticks_msec() >= _shot_deadline and _shot_path != "":
		var img := get_viewport().get_texture().get_image()
		if img != null:
			img.save_png(_shot_path)
			print("shot saved to ", _shot_path)
		else:
			print("shot failed: viewport texture unavailable")
		get_tree().quit()

# ---------- лейны (параллельные игры) ----------

func _grid_cols(n: int) -> int:
	if n <= 1:
		return 1
	if n <= 4:
		return 2
	if n <= 9:
		return 3
	return 4

# ---------- сессионная статистика (справа, только swarm) ----------

func _create_stats_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.visible = false
	panel.custom_minimum_size = Vector2(236, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.08, 0.92)
	sb.set_corner_radius_all(10)
	sb.border_color = Color(0.35, 0.35, 0.45)
	sb.set_border_width_all(1)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "SESSION"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.35))
	vbox.add_child(title)

	var sub := Label.new()
	sub.text = "рекорд и среднее за эту сессию"
	sub.add_theme_font_size_override("font_size", 9)
	sub.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	vbox.add_child(sub)

	vbox.add_child(HSeparator.new())

	# прокрутка — на случай >20 игр
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 8)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	_stats_rows_node = rows

	vbox.add_child(HSeparator.new())

	_stats_footer_top = Label.new()
	_stats_footer_top.text = "TOP —   AVG —"
	_stats_footer_top.add_theme_font_size_override("font_size", 13)
	_stats_footer_top.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0, 0.95))
	vbox.add_child(_stats_footer_top)

	_stats_footer_sub = Label.new()
	_stats_footer_sub.text = "лучшее T — · ср. T — · runs 0"
	_stats_footer_sub.add_theme_font_size_override("font_size", 10)
	_stats_footer_sub.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	vbox.add_child(_stats_footer_sub)

	return panel

var _stats_rows_node: VBoxContainer

func _relayout_grid() -> void:
	_grid.columns = _grid_cols(lanes.size())
	# в swarm-режиме (2+ игры) убираем ВСЕ метрики внутри ячеек
	var show_metrics := lanes.size() == 1
	# и показываем панель сессионной статистики справа
	var show_stats := lanes.size() >= 2
	if _stats_panel != null and _stats_panel.visible != show_stats:
		_stats_panel.visible = show_stats
	for lane in lanes:
		var cell: Control = lane.cell
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var h: Dictionary = lane.hud
		h.metrics.visible = show_metrics
	_rebuild_stats_rows()

# Пересоздаёт строки статистики под текущие lanes (вызывается из _relayout_grid)
func _rebuild_stats_rows() -> void:
	if _stats_rows_node == null:
		return
	for child in _stats_rows_node.get_children():
		_stats_rows_node.remove_child(child)
		child.queue_free()
	_stats_rows.clear()
	for lane in lanes:
		var h: Dictionary = lane.hud
		var color: Color = h.color
		var cell := HBoxContainer.new()
		cell.add_theme_constant_override("separation", 8)
		var dot := Label.new()
		dot.text = "●"
		dot.custom_minimum_size = Vector2(12, 0)
		dot.add_theme_font_size_override("font_size", 12)
		dot.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 1)
		var row1 := HBoxContainer.new()
		row1.add_theme_constant_override("separation", 6)
		var title := Label.new()
		title.text = "GAME %d" % lane.id
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.add_theme_font_size_override("font_size", 11)
		title.add_theme_color_override("font_color", color)
		var best_lbl := Label.new()
		best_lbl.text = "BEST —"
		best_lbl.add_theme_font_size_override("font_size", 11)
		best_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
		row1.add_child(title)
		row1.add_child(best_lbl)
		var stats_lbl := Label.new()
		stats_lbl.text = "AVG — · T 0.0 s · T⌀ — · T★ — · ×0"
		stats_lbl.add_theme_font_size_override("font_size", 9)
		stats_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
		col.add_child(row1)
		col.add_child(stats_lbl)
		cell.add_child(dot)
		cell.add_child(col)
		_stats_rows_node.add_child(cell)
		_stats_rows[lane.id] = {"dot": dot, "best": best_lbl, "line": stats_lbl}

# 10 Гц обновление панели сессионной статистики
func _update_swarm_stats() -> void:
	if _stats_panel == null or not _stats_panel.visible:
		return
	var now := Time.get_ticks_msec()

	var top := 0.0
	var sum_score := 0.0
	var sum_time := 0.0
	var runs := 0
	var best_time := 0.0
	for lane in lanes:
		var s: Dictionary = lane.session
		top = maxf(top, s["best"])
		sum_score += s["sum_score"]
		sum_time += s["sum_time"]
		runs += int(s["runs"])
		best_time = maxf(best_time, s["best_time"])

	for lane in lanes:
		if not _stats_rows.has(lane.id):
			continue
		var s: Dictionary = lane.session
		var r: Dictionary = _stats_rows[lane.id]
		var row_time := (now - int(s["spawn_msec"])) / 1000.0 if lane.alive else float(s["last_run_time"])
		if lane.alive:
			r.dot.text = "●"
			r.dot.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
		else:
			r.dot.text = "✖"
			r.dot.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
		r.best.text = "BEST %d м" % int(s["best"])
		var avg_score := (float(s["sum_score"]) / float(s["runs"])) if int(s["runs"]) > 0 else 0.0
		var avg_time := (float(s["sum_time"]) / float(s["runs"])) if int(s["runs"]) > 0 else 0.0
		var btime := float(s["best_time"])
		r.line.text = "AVG %.1f м · T %.1f s · T⌀ %.1f s · T★ %.1f s · ×%d" % [avg_score, row_time, avg_time, btime, int(s["runs"])]

	if runs > 0:
		var avg_all := sum_score / float(runs)
		var avg_t := sum_time / float(runs)
		_stats_footer_top.text = "TOP %d м   AVG %.1f м" % [int(top), avg_all]
		_stats_footer_sub.text = "лучшее T %.1f c · ср. T %.1f c · runs %d" % [best_time, avg_t, runs]
	else:
		_stats_footer_top.text = "TOP —   AVG —"
		_stats_footer_sub.text = "лучшее T — · ср. T — · runs 0"

# Создаёт одну параллельную игру: свой SubViewport + World2D + панель данных
func _create_lane() -> Dictionary:
	var id := next_lane_id
	next_lane_id += 1
	var color: Color = LANE_COLORS[id % LANE_COLORS.size()]

	# --- ячейка сетки ---
	var cell := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.08, 0.92)
	sb.set_corner_radius_all(8)
	sb.border_color = color
	sb.set_border_width_all(2)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 3
	sb.content_margin_bottom = 5
	cell.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	cell.add_child(vbox)

	# заголовок: номер игры (цвет) + статус + наклон
	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = "GAME %d" % id
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", color)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var status := Label.new()
	status.text = "● ALIVE"
	status.add_theme_font_size_override("font_size", 9)
	status.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
	head.add_child(title)
	head.add_child(status)
	vbox.add_child(head)

	# --- SubViewport с собственным миром ---
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	svc.custom_minimum_size = Vector2(0, SV_MIN_H)
	vbox.add_child(svc)

	var sv := SubViewport.new()
	sv.size = Vector2(SV_W, SV_H)
	sv.world_2d = World2D.new()
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.physics_object_picking = false
	svc.add_child(sv)

	var rocket: RigidBody2D = load("res://rocket.tscn").instantiate()
	rocket.position = Vector2.ZERO
	var cave := Node2D.new()
	cave.set_script(load("res://cave.gd"))
	cave.lane_offset = 0.0
	sv.add_child(rocket)
	sv.add_child(cave)

	# --- метрики (показываются только в solo; в swarm визуал чистый: кадр + статус) ---
	var metrics := VBoxContainer.new()
	metrics.add_theme_constant_override("separation", 2)
	vbox.add_child(metrics)

	var row_a := HBoxContainer.new()
	var score := Label.new()
	score.text = "0 м"
	score.add_theme_font_size_override("font_size", 16)
	score.add_theme_color_override("font_color", Color(1, 1, 1, 0.97))
	score.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ang_lbl := Label.new()
	ang_lbl.text = "ANG 0°"
	ang_lbl.add_theme_font_size_override("font_size", 10)
	ang_lbl.add_theme_color_override("font_color", Color(0.6, 0.9, 1.0, 0.95))
	var best_lbl := Label.new()
	best_lbl.text = "BEST %d м" % best
	best_lbl.add_theme_font_size_override("font_size", 8)
	best_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75, 0.9))
	row_a.add_child(score)
	row_a.add_child(ang_lbl)
	row_a.add_child(best_lbl)
	metrics.add_child(row_a)

	var h := {}
	h.vel_x = _bar_row(metrics, "VX", 9)
	h.vel_y = _bar_row(metrics, "VY", 9)
	h.l_right = _bar_row(metrics, "→", 8)
	h.l_rd = _bar_row(metrics, "↘", 8)
	h.l_down = _bar_row(metrics, "↓", 8)
	h.l_ld = _bar_row(metrics, "↙", 8)
	h.l_left = _bar_row(metrics, "←", 8)
	h.status = status
	h.score = score
	h.best = best_lbl
	h.ang = ang_lbl
	h.metrics = metrics
	h.panel_sb = sb
	h.color = color

	_grid.add_child(cell)

	var lane := {
		"id": id,
		"rocket": rocket,
		"cave": cave,
		"viewport": sv,
		"cell": cell,
		"hud": h,
		"alive": true,
		"max_depth": 0.0,
		"cur_depth": 0.0,
		"spawn_y": 0.0,
		"spawn_tick": _physics_tick,
		"dead_tick": -1,
		"cache_tick": -1,
		"cached": {},
		"session": {
			"best": 0.0,          # лучший счёт за сессию
			"sum_score": 0.0,     # сумма очков за все завершённые забеги
			"sum_time": 0.0,      # суммарное время всех завершённых забегов, с
			"runs": 0,            # число завершённых забегов (смертей/пересозданий)
			"best_time": 0.0,     # лучшее время забега, с
			"last_run_time": 0.0, # время последнего забега, с
			"spawn_msec": Time.get_ticks_msec(),
		},
		"tas": {
			"mode": "idle",      # idle | bot | bot_rec | verify
			"rec_inputs": [],    # записанные входы по тикам (от спавна)
			"rec_samples": [],   # сэмплы состояния каждые 4 тика (x, y, vx, vy, depth)
			"playback": 0,       # индекс воспроизводимой записи
			"max_err_pos": 0.0,
			"max_err_vel": 0.0,
			"ticks_checked": 0,
			"violations": [],
			"spawn_tick": -1,
			"last_result": "",
			"saved_path": "",
			"final_depth_m": 0.0,
			"recorded_ticks": 0,
		},
	}
	lanes.append(lane)

	cave.rocket = rocket
	var cid := id
	cave.killer_callback = func(body): _on_lane_killed(body, cid)

	# камера — теперь и ракета, и вся ячейка в дереве
	var cam := rocket.get_node_or_null("Camera") as Camera2D
	if cam != null:
		cam.zoom = Vector2(0.8, 0.8)
		cam.make_current()

	_relayout_grid()
	return lane

func _spawn_lane() -> Dictionary:
	return _create_lane()

func _respawn_lane(id: int) -> bool:
	var lane = _lane_by_id(id)
	if lane == null:
		return false
	var cid := id
	var sv: SubViewport = lane.viewport
	for child in sv.get_children():
		sv.remove_child(child)
		child.queue_free()

	var rocket: RigidBody2D = load("res://rocket.tscn").instantiate()
	rocket.position = Vector2.ZERO
	var cave := Node2D.new()
	cave.set_script(load("res://cave.gd"))
	sv.add_child(rocket)
	sv.add_child(cave)

	lane.rocket = rocket
	lane.cave = cave
	lane.alive = true
	lane.max_depth = 0.0
	lane.cur_depth = 0.0
	lane.spawn_y = 0.0
	lane.dead_tick = -1
	lane.spawn_tick = _physics_tick
	lane.cache_tick = -1
	lane.session["spawn_msec"] = Time.get_ticks_msec()
	lane.session["last_run_time"] = 0.0
	cave.rocket = rocket
	cave.killer_callback = func(body): _on_lane_killed(body, cid)

	var cam := rocket.get_node_or_null("Camera") as Camera2D
	if cam != null:
		cam.zoom = Vector2(0.8, 0.8)
		cam.make_current()

	if lane.viewport.render_target_update_mode == SubViewport.UPDATE_ONCE:
		lane.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	lane.hud.status.text = "● ALIVE"
	lane.hud.status.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
	lane.hud.panel_sb.border_color = lane.hud.color
	return true

func _delete_lane(id: int) -> bool:
	var lane = _lane_by_id(id)
	if lane == null:
		return false
	# cell освобождается сам вместе с SubViewport и миром
	lane.cell.queue_free()
	var idx := lanes.find(lane)
	if idx != -1:
		lanes.erase(lane)
	_relayout_grid()
	return true

func _lane_by_id(id: int) -> Variant:
	for lane in lanes:
		if lane.id == id:
			return lane
	return null

func _on_lane_killed(body: Node2D, id: int) -> void:
	var lane = _lane_by_id(id)
	if lane == null:
		return
	if body != lane.rocket or not lane.alive:
		return
	lane.dead_tick = _physics_tick
	lane.alive = false
	var score := int(lane.max_depth)

	# --- сессионная статистика по этому забегу ---
	var sess: Dictionary = lane.session
	var run_time: float = (Time.get_ticks_msec() - int(sess["spawn_msec"])) / 1000.0
	sess["last_run_time"] = run_time
	sess["best"] = maxf(sess["best"], lane.max_depth)
	sess["sum_score"] += lane.max_depth
	sess["sum_time"] += run_time
	sess["runs"] = int(sess["runs"]) + 1
	sess["best_time"] = maxf(sess["best_time"], run_time)

	if score > best:
		best = score
		_save_best()
	print("Lane %d: crashed at %d m" % [id, score])

	# подсветить ячейку красным, пометить статус, заморозить рендер этого кадра
	lane.hud.status.text = "✖ CRASHED"
	lane.hud.status.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	lane.hud.panel_sb.border_color = Color(0.85, 0.25, 0.25)
	lane.viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	if lanes.size() == 1 and not _tas_any_active():
		# solo-режим (одна игра) — полная перезагрузка сцены
		# (при активном TAS замораживаем, не перезагружаем: проверка должна увидеть падение)
		get_tree().call_deferred("reload_current_scene")
	else:
		# параллельные игры: замораживаем только эту (defer — колбэк из физики)
		lane.rocket.set_deferred("freeze", true)

# ---------- счёт / рекорд ----------

func _load_best() -> int:
	if FileAccess.file_exists(BEST_PATH):
		var f := FileAccess.open(BEST_PATH, FileAccess.READ)
		if f != null:
			return int(f.get_as_text().strip_edges())
	return 0

func _save_best() -> void:
	var f := FileAccess.open(BEST_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(str(best))

# ---------- лидары + кеш состояния на PHYSICS-тик ----------

func _lidar_distances(rocket: Node2D) -> Dictionary:
	var result := {}
	var map := {
		"right": "LidarRight",
		"right_down": "LidarRightDown",
		"down": "LidarDown",
		"left_down": "LidarLeftDown",
		"left": "LidarLeft",
	}
	for key in map.keys():
		var rc := rocket.get_node_or_null(map[key]) as RayCast2D
		var d := LIDAR_RANGE
		if rc != null and rc.is_colliding():
			d = rocket.global_position.distance_to(rc.get_collision_point())
		result[key] = snappedf(d, 0.1)
	return result

# Снимок сессионной статистики для /state
func _session_state(lane) -> Dictionary:
	var s: Dictionary = lane.session
	var runs := int(s["runs"])
	return {
		"best": snappedf(s["best"], 0.01),                      # лучший счёт за сессию
		"avg": snappedf(float(s["sum_score"]) / float(runs), 0.01) if runs > 0 else 0.0,
		"runs": runs,
		"avg_time_s": snappedf(float(s["sum_time"]) / float(runs), 0.01) if runs > 0 else 0.0,
		"best_time_s": snappedf(s["best_time"], 0.01),
		"last_run_time_s": snappedf(s["last_run_time"], 0.01),
	}

# Обновляется раз в физический кадр — дешёвые повторные запросы /state и /control
func _refresh_lane_cache(lane) -> void:
	if lane.cache_tick == _physics_tick:
		return
	lane.cache_tick = _physics_tick
	var r: Node2D = lane.rocket
	var vel := Vector2.ZERO
	var ang := 0.0
	var ang_vel := 0.0
	if r is RigidBody2D:
		vel = r.linear_velocity
		# наклон в градусах, 0 = вертикально вверх, (-180, 180]
		var a := rad_to_deg(r.rotation)
		ang = fposmod(a + 180.0, 360.0) - 180.0
		ang_vel = r.angular_velocity

	var end_tick := _physics_tick if lane.alive else int(lane.dead_tick)
	var time_alive := maxf(0.0, (end_tick - lane.spawn_tick) / float(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60)))

	# текущее применение ввода (кто управляет — клавиатура или API)
	var thrust_now := false
	var torque_now := 0.0
	if r is RigidBody2D:
		thrust_now = r.api_thrust if "api_thrust" in r else false
		torque_now = r.api_torque if "api_torque" in r else 0.0

	lane.cached = {
		"lane": lane.id,
		"alive": lane.alive,
		"score": int(lane.cur_depth),
		"depth_m": snappedf(lane.cur_depth, 0.01),
		"vel_x": snappedf(vel.x, 0.1),
		"vel_y": snappedf(vel.y, 0.1),
		"speed": snappedf(vel.length(), 0.1),
		"position": {"x": snappedf(r.global_position.x, 0.1), "y": snappedf(r.global_position.y, 0.1)},
		"angle": snappedf(ang, 0.1),            # градусы, 0 = вертикально, (-180, 180]
		"angle_vel": snappedf(ang_vel, 0.01),    # рад/с, + = по часовой
		"thrust": thrust_now,
		"torque": snappedf(torque_now, 0.01),
		"time_alive": snappedf(time_alive, 0.01),
		"lidars": _lidar_distances(r),
		"session": _session_state(lane),
	}

# Готовит кэш JSON-ответов /state ровно один раз на физтик
func _refresh_state_cache() -> void:
	if _physics_tick == _state_cache_tick and _state_cache_all != "":
		return
	var all := []
	var per_lane := {}
	for lane in lanes:
		var st := _lane_state(lane)
		all.append(st)
		per_lane[lane.id] = _resp(200, st)
	_state_cache_all = _resp(200, {"best": best, "time_scale": Engine.time_scale, "lanes": all})
	_state_cache_lane = per_lane
	_state_cache_tick = _physics_tick

func _invalidate_state_cache() -> void:
	_state_cache_tick = -1

func _lane_state(lane) -> Dictionary:
	if lane == null:
		return {"error": "lane not found"}
	# свежесть: не чаще, чем раз в 2 физтика — между ними отдаём кэш
	if lane.cache_tick == -1 or _physics_tick - lane.cache_tick >= 2:
		_refresh_lane_cache(lane)
	return lane.cached

# ---------- HTTP API ----------

func _poll_api() -> void:
	if api_host == null:
		return
	var host: Node = api_host
	var server: TCPServer = host.server
	if not server.is_listening():
		return
	while server.is_connection_available():
		var p: StreamPeerTCP = server.take_connection()
		p.set_no_delay(true)   # без Nagle — ответы сразу (важно для 30-Гц опроса тренера)
		host.peers[p] = ""
	for p: StreamPeerTCP in host.peers.keys():
		p.poll()
		# StreamPeerTCP.get_partial_data(n) -> [int error, PackedByteArray data]
		var res: Array = p.get_partial_data(65536)
		if res.size() == 2 and res[1] is PackedByteArray and res[1].size() > 0:
			host.peers[p] += (res[1] as PackedByteArray).get_string_from_utf8()
		var buf: String = host.peers[p]
		var header_end := buf.find("\r\n\r\n")
		if header_end == -1:
			if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				host.peers.erase(p)
			continue
		var content_length := 0
		for line in buf.substr(0, header_end).split("\r\n"):
			if line.to_lower().begins_with("content-length:"):
				content_length = int(line.split(":")[1].strip_edges())
		var body_start := header_end + 4
		if buf.length() < body_start + content_length:
			continue  # ждём тело
		var body := buf.substr(body_start)
		var t0 := Time.get_ticks_usec() if _api_timing else 0
		var response := _handle_request(buf, body)
		if _api_timing:
			_api_req_count += 1
			_api_req_ms += (Time.get_ticks_usec() - t0) / 1000.0
		p.put_data(response.to_utf8_buffer())
		p.disconnect_from_host()
		host.peers.erase(p)
	if _api_timing and _api_next_print > 0 and Time.get_ticks_msec() >= _api_next_print:
		print("api timing: %d requests in window, total %.3f ms, avg %.1f us/req" % [_api_req_count, _api_req_ms, (1000.0 * _api_req_ms / maxf(1.0, float(_api_req_count)))])
		_api_req_count = 0
		_api_req_ms = 0.0
		_api_next_print = Time.get_ticks_msec() + 5000
	elif _api_timing and _api_next_print == 0:
		_api_next_print = Time.get_ticks_msec() + 5000

func _parse_query(q: String) -> Dictionary:
	var out := {}
	for pair in q.split("&"):
		var kv := pair.split("=", true, 1)
		if kv.size() == 2:
			out[kv[0].uri_decode()] = kv[1].uri_decode()
		else:
			out[kv[0].uri_decode()] = ""
	return out

func _handle_request(head: String, body: String) -> String:
	_menu_note_api_activity()
	var first_line := head.split("\r\n")[0]
	var parts := first_line.split(" ")
	if parts.size() < 3:
		return _resp(400, {"error": "bad request line"})
	var method := parts[0].to_upper()
	var target := parts[1]

	var path := target
	var query := {}
	var qpos := target.find("?")
	if qpos != -1:
		path = target.substr(0, qpos)
		query = _parse_query(target.substr(qpos + 1))

	var json_body: Variant = null
	var trimmed := body.strip_edges()
	if trimmed != "":
		var json := JSON.new()
		if json.parse(trimmed) != OK:
			return _resp(400, {"error": "invalid JSON object expected"})
		if not (json.data is Dictionary):
			return _resp(400, {"error": "invalid JSON object expected"})
		json_body = json.data

	match method:
		"GET":
			match path:
				"/":
					return _resp(200, {
						"name": "rocket-landing",
						"version": VERSION,
						"docs": "API_README.md",
						"endpoints": ["/health", "/state", "/state?lane=N", "/control", "/speed", "/spawn", "/respawn", "/reset", "/lane", "/tas/start", "/tas/verify", "/tas/stop", "/tas/status"],
					})
				"/tas/status":
					if query.has("lane"):
						return _resp(200, _tas_status(int(query["lane"])))
					return _resp(200, _tas_status(0))
				"/health":
					return _resp(200, {"ok": true, "version": VERSION, "time_scale": Engine.time_scale, "lanes": lanes.size(), "best": best})
				"/state":
					_refresh_state_cache()  # лидары и так кэшируются на тик — кэшируем и готовую JSON-строку
					if query.has("lane"):
						var lane = _lane_by_id(int(query["lane"]))
						if lane == null:
							return _resp(404, {"error": "lane not found"})
						return _state_cache_lane.get(lane.id, _resp(200, _lane_state(lane)))
					return _state_cache_all
				_:
					return _resp(404, {"error": "not found"})
		"POST":
			match path:
				"/control":
					var b: Dictionary = json_body if json_body != null else {}
					var lane = _lane_by_id(int(b.get("lane", 0)))
					if lane == null:
						return _resp(404, {"error": "lane not found"})
					if b.has("thrust"):
						lane.rocket.api_thrust = bool(b["thrust"])
					if b.has("torque"):
						lane.rocket.api_torque = clampf(float(b["torque"]), -1.0, 1.0)
					# ответ = снимок состояния ПОСЛЕ применения ввода
					return _resp(200, _lane_state(lane))
				"/speed":
					var b: Dictionary = json_body if json_body != null else {}
					var s := clampf(float(b.get("scale", 1.0)), 0.05, MAX_TIME_SCALE)
					Engine.time_scale = s
					_invalidate_state_cache()
					return _resp(200, {"time_scale": s})
				"/spawn":
					var lane := _spawn_lane()
					_invalidate_state_cache()
					return _resp(200, {"lane": lane.id, "lanes": lanes.size()})
				"/respawn":
					var b: Dictionary = json_body if json_body != null else {}
					if not b.has("lane"):
						return _resp(400, {"error": "lane required"})
					if not _respawn_lane(int(b["lane"])):
						return _resp(404, {"error": "lane not found"})
					_invalidate_state_cache()
					return _resp(200, {"ok": true, "lane": int(b["lane"])})
				"/reset":
					var b: Dictionary = json_body if json_body != null else {}
					if b.has("lane"):
						if not _respawn_lane(int(b["lane"])):
							return _resp(404, {"error": "lane not found"})
						_invalidate_state_cache()
						return _resp(200, {"ok": true, "lane": int(b["lane"])})
					get_tree().call_deferred("reload_current_scene")
					return _resp(200, {"ok": true, "reloading": true})
				"/lane/delete":
					var b: Dictionary = json_body if json_body != null else {}
					if not b.has("lane"):
						return _resp(400, {"error": "lane required"})
					return _delete_lane_resp(int(b["lane"]))
				"/tas/start":
					var b: Dictionary = json_body if json_body != null else {}
					var out := _tas_start(int(b.get("lane", 0)))
					return _resp(404 if out.has("error") else 200, out)
				"/tas/verify":
					var b: Dictionary = json_body if json_body != null else {}
					var out := _tas_verify(int(b.get("lane", 0)))
					return _resp(404 if out.has("error") else 200, out)
				"/tas/stop":
					var b: Dictionary = json_body if json_body != null else {}
					var out := _tas_stop(int(b.get("lane", 0)))
					return _resp(404 if out.has("error") else 200, out)
				_:
					return _resp(404, {"error": "not found"})
		"DELETE":
			match path:
				"/lane":
					if not query.has("lane"):
						return _resp(400, {"error": "lane query parameter required (?lane=N)"})
					return _delete_lane_resp(int(query["lane"]))
				_:
					return _resp(404, {"error": "not found"})
		_:
			return _resp(405, {"error": "method not allowed"})

# --- меню / сенсор ---

func _menu_note_api_activity() -> void:
	if _menu != null and is_instance_valid(_menu):
		_menu.note_api_activity()

func _set_touch_visible(v: bool) -> void:
	if _touch != null and is_instance_valid(_touch):
		_touch.set_touch_visible(v)

func _tas_any_active() -> bool:
	for lane in lanes:
		if lane.tas.get("mode", "idle") != "idle":
			return true
	return false

func _delete_lane_resp(id: int) -> String:
	if lanes.size() <= 1:
		return _resp(400, {"error": "cannot delete the last lane"})
	if not _delete_lane(id):
		return _resp(404, {"error": "lane not found"})
	_invalidate_state_cache()
	return _resp(200, {"ok": true, "lane": id, "lanes": lanes.size()})

func _resp(code: int, obj: Dictionary) -> String:
	var status: String = ({200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"} as Dictionary).get(code, "OK")
	var body := JSON.stringify(obj)
	return "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [code, status, body.length(), body]

# ---------- TAS (идеальная запись и её проверка) ----------
# bot — автопилот: по аналитической формуле центра пещеры тянется к центру,
# держит скорость падения умеренной. bot_rec пишет запись входов. verify
# дословно воспроизводит записанное и побитово сравнивает траекторию.

const TAS_PATH := "user://tas.json"
const TAS_LOOKAHEAD := 340.0     # смотрим на 340 px вперёд по глубине
const TAS_TGT_FALL_VY := 210.0   # держать скорость падения не выше этого
const TAS_TORQUE_GAIN := 0.012
const TAS_VEL_DAMP := 0.006
const TAS_POS_TOL := 0.75        # px — допуск расхождения при проверке
const TAS_MAX_TICKS := 24000     # 400 s игрового времени — потолок записи

func _tas_tick(lane) -> void:
	var t: Dictionary = lane.tas
	var r: Node2D = lane.rocket
	var tick: int = _physics_tick - lane.spawn_tick   # тики от спавна
	match t.mode:
		"bot", "bot_rec":
			if not lane.alive:
				if t.mode == "bot_rec":
					_tas_save(lane)
				else:
					t.mode = "idle"
				return
			if tick >= TAS_MAX_TICKS:
				_tas_save(lane)   # слишком долго — фиксируем то, что есть
				return
			var inp := _tas_bot_input(lane)
			r.api_thrust = inp.thrust
			r.api_torque = inp.torque
			if t.mode == "bot_rec":
				t.rec_inputs.append({"thrust": inp.thrust, "torque": inp.torque})
				if tick >= 0 and tick % 4 == 0:
					_tas_sample(lane, tick)
		"verify":
			# шаг 1: физическое состояние на начало тика — проверяем инварианты
			var logic_err := _tas_check_logic(lane)
			if logic_err != "":
				_tas_record_violation(lane, tick, logic_err)
			if not lane.alive:
				_tas_finish_verify(lane, true, tick)
				return
			var i: int = int(t.playback)
			var inputs: Array = t.rec_inputs
			if i >= inputs.size():
				_tas_finish_verify(lane, false, tick)
				return
			# шаг 2: входные значения ленты обязаны быть в легальных пределах
			var inp: Dictionary = inputs[i]
			var tape_err := _tas_check_tape_tick(inp, i)
			if tape_err != "":
				_tas_record_violation(lane, i, tape_err)
			r.api_thrust = bool(inp.thrust)
			r.api_torque = clampf(float(inp.torque), -1.0, 1.0)
			if i % 4 == 0:
				var si: int = i / 4
				var samples: Array = t.rec_samples
				if si < samples.size():
					var s: Dictionary = samples[si]
					var rr := r as RigidBody2D
					var vel: Vector2 = rr.linear_velocity if rr != null else Vector2.ZERO
					var dp: float = Vector2(r.global_position.x - s.x, r.global_position.y - s.y).length()
					var dv: float = Vector2(vel.x - s.vx, vel.y - s.vy).length()
					t.max_err_pos = maxf(t.max_err_pos, dp)
					t.max_err_vel = maxf(t.max_err_vel, dv)
					t.ticks_checked += 1
			t.playback = i + 1

func _tas_bot_input(lane) -> Dictionary:
	var r: Node2D = lane.rocket
	if not (r is RigidBody2D):
		return {"thrust": false, "torque": 0.0}
	var rr := r as RigidBody2D
	var cave = lane.cave
	var y := rr.global_position.y
	# целимся в центр коридора чуть впереди по глубине
	var target: float = cave.center_at(y + TAS_LOOKAHEAD)
	var dx := target - rr.global_position.x
	var vx := rr.linear_velocity.x
	var torque := clampf(dx * TAS_TORQUE_GAIN - vx * TAS_VEL_DAMP, -1.0, 1.0)
	# тяга: не даём падать быстрее TAS_TGT_FALL_VY
	var thrust: bool = rr.linear_velocity.y > TAS_TGT_FALL_VY
	return {"thrust": thrust, "torque": torque}

# Проверка инвариантов игровой логики на тик воспроизведения.
# Возвращает "" если всё в порядке, иначе — описание нарушения.
func _tas_check_logic(lane) -> String:
	var r_node: Node2D = lane.rocket
	if not (r_node is RigidBody2D):
		return "rocket is not a RigidBody2D"
	var r := r_node as RigidBody2D
	var cave = lane.cave
	var pos: Vector2 = r.global_position
	var vel: Vector2 = r.linear_velocity

	# 1. никакого мусора в числах
	if is_nan(pos.x) or is_nan(pos.y) or is_nan(vel.x) or is_nan(vel.y):
		return "non-finite position/velocity"
	if is_inf(pos.x) or is_inf(pos.y) or is_inf(vel.x) or is_inf(vel.y):
		return "infinite position/velocity"

	# 2. ракета внутри коридора: |x - center(y)| < half(y)
	var c: float = cave.center_at(pos.y)
	var h: float = cave.half_at(pos.y)
	if absf(pos.x - c) >= h:
		return "rocket inside rock: y=%.1f x=%.1f corridor=[%.1f %.1f]" % [pos.y, pos.x, c - h, c + h]

	# 3. разумный потолок скорости (нет телепортации)
	if vel.length() > 5000.0:
		return "velocity out of bounds: %.1f px/s" % vel.length()

	# 4. угловая скорость в пределах, заданных torque.gd (+ запас)
	if absf(r.angular_velocity) > 6.0:
		return "angular velocity out of bounds: %.2f rad/s" % r.angular_velocity
	return ""

# Проверка одного тика записи: входы в легальных пределах
func _tas_check_tape_tick(inp: Dictionary, tick: int) -> String:
	var tq = inp.get("torque", 0.0)
	if not (tq is float or tq is int):
		return "tape tick %d: torque has wrong type" % tick
	var f := float(tq)
	if f < -1.0 or f > 1.0:
		return "tape tick %d: torque %.3f out of [-1, 1]" % [tick, f]
	if not (inp.get("thrust", false) is bool):
		return "tape tick %d: thrust has wrong type" % tick
	return ""

func _tas_record_violation(lane, tick: int, err: String) -> void:
	var t: Dictionary = lane.tas
	if t.violations.size() < 8:
		t.violations.append("t=%d: %s" % [tick, err])

func _tas_sample(lane, tick: int) -> void:
	var r: Node2D = lane.rocket
	if not (r is RigidBody2D):
		return
	var rr := r as RigidBody2D
	var t: Dictionary = lane.tas
	t.rec_samples.append({
		"t": tick,
		"x": rr.global_position.x,
		"y": rr.global_position.y,
		"vx": rr.linear_velocity.x,
		"vy": rr.linear_velocity.y,
		"depth": lane.cur_depth,
	})

func _tas_save(lane) -> void:
	var t: Dictionary = lane.tas
	t.recorded_ticks = t.rec_inputs.size()
	t.final_depth_m = lane.max_depth
	var dict := {
		"version": 1,
		"created": Time.get_datetime_string_from_system(),
		"engine": Engine.get_version_info().get("string", "unknown"),
		"spawn_y": 0.0,
		"final_depth_m": lane.max_depth,
		"ticks": t.rec_inputs.size(),
		"inputs": t.rec_inputs,
		"samples": t.rec_samples,
	}
	var f := FileAccess.open(TAS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(dict))
		t.saved_path = TAS_PATH
		t.last_result = "saved: %d ticks, depth %.2f m" % [t.rec_inputs.size(), lane.max_depth]
		print("TAS: saved ideal run -> %s (depth %.2f m, %d ticks)" % [TAS_PATH, lane.max_depth, t.rec_inputs.size()])
	else:
		t.last_result = "save failed"
	t.mode = "idle"

func _tas_start(lane_id: int) -> Dictionary:
	var lane = _lane_by_id(lane_id)
	if lane == null:
		return {"error": "lane not found"}
	if not _respawn_lane(lane_id):
		return {"error": "lane not found"}
	lane = _lane_by_id(lane_id)
	var t: Dictionary = lane.tas
	t.mode = "bot_rec"
	t.rec_inputs = []
	t.rec_samples = []
	t.playback = 0
	t.max_err_pos = 0.0
	t.max_err_vel = 0.0
	t.ticks_checked = 0
	t.violations = []
	t.last_result = "recording"
	return {"ok": true, "lane": lane_id, "mode": "bot_rec"}

func _tas_verify(lane_id: int) -> Dictionary:
	var lane = _lane_by_id(lane_id)
	if lane == null:
		return {"error": "lane not found"}
	# лента: сначала из памяти (последняя запись), иначе из файла
	var inputs: Array = lane.tas.rec_inputs
	var samples: Array = lane.tas.rec_samples
	var src := "memory"
	if inputs.is_empty() and FileAccess.file_exists(TAS_PATH):
		var parsed = JSON.parse_string(FileAccess.open(TAS_PATH, FileAccess.READ).get_as_text())
		if parsed is Dictionary:
			inputs = parsed.get("inputs", [])
			samples = parsed.get("samples", [])
			src = TAS_PATH
	if inputs.is_empty():
		return {"error": "no tape recorded yet (run /tas/start first)"}
	if not _respawn_lane(lane_id):
		return {"error": "lane not found"}
	lane = _lane_by_id(lane_id)
	var t: Dictionary = lane.tas
	t.mode = "verify"
	t.rec_inputs = inputs
	t.rec_samples = samples
	t.playback = 0
	t.max_err_pos = 0.0
	t.max_err_vel = 0.0
	t.ticks_checked = 0
	t.violations = []
	t.last_result = "verifying"
	return {"ok": true, "lane": lane_id, "tape_ticks": inputs.size(), "source": src}

func _tas_finish_verify(lane, died_early: bool, tick: int) -> void:
	var t: Dictionary = lane.tas
	# вердикт теперь = инварианты логики + выживание; сравнение траектории — метрика
	if died_early:
		t.last_result = "FAIL: rocket touched wall at tick %d (tape %d ticks)" % [tick, t.rec_inputs.size()]
	elif t.violations.size() > 0:
		t.last_result = "FAIL: logic violation: %s" % t.violations[0]
	elif t.max_err_pos > TAS_POS_TOL:
		t.last_result = "FAIL: replay diverged: max_err=%.4f px, max_err_vel=%.4f" % [t.max_err_pos, t.max_err_vel]
	else:
		var extra := ""
		if t.violations.size() > 0:
			extra = ", violations: " + "; ".join(t.violations)
		t.last_result = "PASS: tape replayed without touching walls, max_err=%.4f px, ticks=%d%s" % [t.max_err_pos, t.ticks_checked, extra]
	t.mode = "idle"
	print("TAS verify: ", t.last_result)

func _tas_stop(lane_id: int) -> Dictionary:
	var lane = _lane_by_id(lane_id)
	if lane == null:
		return {"error": "lane not found"}
	lane.tas.mode = "idle"
	lane.rocket.api_thrust = false
	lane.rocket.api_torque = 0.0
	return {"ok": true, "lane": lane_id, "mode": "idle"}

func _tas_status(lane_id: int) -> Dictionary:
	var lane = _lane_by_id(lane_id)
	if lane == null:
		return {"error": "lane not found"}
	var t: Dictionary = lane.tas
	return {
		"lane": lane_id,
		"mode": t.mode,
		"has_tape": t.rec_inputs.size() > 0 or FileAccess.file_exists(TAS_PATH),
		"tape_ticks": int(t.rec_inputs.size()),
		"final_depth_m": snappedf(t.final_depth_m, 0.01),
		"saved_path": t.saved_path,
		"last_result": t.last_result,
		"max_err_pos_px": snappedf(t.max_err_pos, 0.001),
		"max_err_vel": snappedf(t.max_err_vel, 0.001),
		"violations": t.violations,
	}

# ---------- HUD (полоски данных для каждой игры) ----------

func _bar_row(parent: Node, title: String, font_size: int) -> ProgressBar:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = title
	label.custom_minimum_size = Vector2(26, 0)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9, 0.85))
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = 0.0
	bar.custom_minimum_size = Vector2(60, 8)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.35, 0.78, 0.92, 1.0)
	fill.set_corner_radius_all(4)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(1, 1, 1, 0.09)
	back.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("fill", fill)
	bar.add_theme_stylebox_override("background", back)
	row.add_child(label)
	row.add_child(bar)
	parent.add_child(row)
	return bar

func _update_hud() -> void:
	for lane in lanes:
		var h: Dictionary = lane.hud
		if not h.metrics.visible:
			continue  # swarm-режим: метрики скрыты, обновлять нечего
		var r: Node2D = lane.rocket
		var vel := Vector2.ZERO
		var ang := 0.0
		if r is RigidBody2D:
			vel = r.linear_velocity
			var a := rad_to_deg(r.rotation)
			ang = fposmod(a + 180.0, 360.0) - 180.0

		h.score.text = "%+d м" % int(lane.cur_depth)
		h.best.text = "BEST %d м" % best
		h.ang.text = "ANG %d°" % roundi(ang)
		if lane.alive:
			h.status.text = "● ALIVE"

		h.vel_x.value = clampf(absf(vel.x) / 600.0, 0.0, 1.0)
		h.vel_y.value = clampf(absf(vel.y) / 600.0, 0.0, 1.0)

		# лидары — из кеша (обновляется каждый физический тик в _refresh_lane_cache)
		if lane.cached.has("lidars"):
			var lidars: Dictionary = lane.cached["lidars"]
			h.l_right.value = 1.0 - clampf(lidars["right"] / LIDAR_RANGE, 0.0, 1.0)
			h.l_rd.value = 1.0 - clampf(lidars["right_down"] / LIDAR_RANGE, 0.0, 1.0)
			h.l_down.value = 1.0 - clampf(lidars["down"] / LIDAR_RANGE, 0.0, 1.0)
			h.l_ld.value = 1.0 - clampf(lidars["left_down"] / LIDAR_RANGE, 0.0, 1.0)
			h.l_left.value = 1.0 - clampf(lidars["left"] / LIDAR_RANGE, 0.0, 1.0)
	# сессионная статистика справа — работает и в swarm, и в solo
	_update_swarm_stats()
