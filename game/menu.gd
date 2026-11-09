class_name RocketMenu
extends CanvasLayer

# Меню Rocket Landing. Показывается при обычном (не API, не headless) запуске:
#   «Играть» — закрыть меню и продолжить игру (если сцена всё же мёртвa —
#              перезагрузить её и начать заново);
#   «TAS»    — экран TAS: расчёт идеального забега перебором путей в 60 Гц
#              (GPU и CPU параллельно, если доступен Vulkan-compute),
#              остановка с сохранением в user://tas.json, загрузка готовой
#              ленты из файла и проверка её реальным воспроизведением в игре.
# Статичный флаг _session_dismissed переживает reload_current_scene, чтобы
# меню не всплывало заново после смерти в solo-режиме.
#
# Любой запрос к HTTP API (например, от тренажёра) автоматически закрывает
# меню и снимает паузу — игра, запущенная «через API», меню не показывает.

const TASSearchCoop = preload("res://tas_coop.gd")

static var _session_dismissed := false

const AMBER := Color(1.0, 0.8, 0.35)
const TEXT := Color(0.9, 0.9, 0.94)
const DIM := Color(0.6, 0.6, 0.68)
const OK_GREEN := Color(0.45, 1.0, 0.55)
const ERR_RED := Color(1.0, 0.45, 0.4)
const PANEL_BG := Color(0.08, 0.08, 0.115, 0.97)
const PANEL_BORDER := Color(0.38, 0.38, 0.48)
const BTN_BG := Color(0.13, 0.13, 0.18, 0.95)
const BTN_HOVER := Color(0.19, 0.19, 0.27, 0.95)
const BTN_PRESSED := Color(0.24, 0.24, 0.33, 0.97)

var game_ref: Node = null

var _screen := "main"           # hidden | main | tas | result
var _main_panel: PanelContainer
var _tas_panel: PanelContainer
var _result_panel: PanelContainer
var _verdict_label: Label
var _result_detail: Label
var _state_label: Label
var _progress_label: Label
var _stats_label: Label
var _engine_label: Label
var _tape_label: Label
var _progress_bar: ProgressBar
var _run_button: Button
var _save_button: Button
var _verify_button: Button

var _backdrop: ColorRect

var _coop = null                # TASSearchCoop
var _last_stats := {}
var _loaded_tape := {}
var _loaded_from := ""
var _verify_watching := false

func _ready() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	if _session_dismissed:
		visible = false
		_screen = "hidden"
		return
	get_tree().paused = true
	_show_screen("main")

func _process(_delta: float) -> void:
	_tick_search()
	_poll_verify()

# --- публичное API для game.gd ---

# Скрыть меню из-за внешней API-активности (обучение через HTTP).
func note_api_activity() -> void:
	_session_dismissed = true
	if _screen == "hidden":
		return
	_close_to_game()

# --- переходы ---

func _show_screen(which: String) -> void:
	_screen = which
	_main_panel.visible = which == "main"
	_tas_panel.visible = which == "tas"
	_result_panel.visible = which == "result"
	_backdrop.visible = true
	visible = true
	if _set_touch_visible(false):
		pass

func _close_to_game() -> void:
	_screen = "hidden"
	visible = false
	get_tree().paused = false
	_set_touch_visible(true)

func _set_touch_visible(v: bool) -> bool:
	if game_ref != null and game_ref.has_method("_set_touch_visible"):
		game_ref._set_touch_visible(v)
		return true
	return false

# --- кнопки ---

func _on_play_pressed() -> void:
	# если единственная игра мертва (например, после проверки TAS) — начать заново
	if game_ref != null and game_ref.lanes.size() == 1 and not game_ref.lanes[0].alive:
		get_tree().paused = false
		get_tree().reload_current_scene()
		return
	_close_to_game()

func _on_tas_pressed() -> void:
	_refresh_tape_label()
	_show_screen("tas")

func _on_back_pressed() -> void:
	_show_screen("main")

func _on_result_to_menu_pressed() -> void:
	_show_screen("main")

func _on_result_again_pressed() -> void:
	_on_verify_pressed()

# --- TAS: запуск/остановка расчёта ---

func _on_run_pressed() -> void:
	if _coop != null:
		_stop_and_save("остановлено вручную")
		return
	_start_search()

func _start_search() -> void:
	_coop = TASSearchCoop.new(192, 192, 2700)
	_last_stats = {}
	_state_label.text = "Идёт перебор путей…"
	_progress_label.text = "тик 0 · глубина 0.00 м"
	_stats_label.text = "рассмотрено путей: 0 · пересечений со стенами: 0"
	_engine_label.text = "движок: " + _coop.backend_label()
	_progress_bar.max_value = _coop.max_ticks
	_progress_bar.value = 0
	_run_button.text = "Остановить и сохранить"
	_save_button.disabled = true
	_verify_button.disabled = true

func _stop_and_save(reason: String) -> void:
	if _coop == null:
		return
	var result: Dictionary = _coop.finish()
	_coop = null
	_last_stats = result
	var tape: Dictionary = result.get("tape", {})
	if tape.is_empty():
		_state_label.text = "Не найдено ни одного выжившего пути (%s)" % reason
		_run_button.text = "Запустить расчёт"
		return
	_loaded_tape = tape
	_loaded_from = "tas-search"
	_inject_tape_into_game(tape)
	var err := _save_tape(tape)
	_state_label.text = "Готово (%s). Лента сохранена в user://tas.json" % reason if err == OK else "Лента собрана, но файл не записался (ошибка %d)" % err
	_set_final_stats(result)
	_refresh_tape_label()
	_run_button.text = "Запустить расчёт"
	_save_button.disabled = false
	_verify_button.disabled = false

func _tick_search() -> void:
	if _coop == null:
		return
	_coop.main_step(2)
	var p: Dictionary = _coop.progress()
	_progress_bar.value = float(p.main_tick)
	_state_label.text = "Идёт перебор путей… тик %d / %d" % [int(p.main_tick), _coop.max_ticks]
	_progress_label.text = "тик %d · глубина %.2f м · время %.1f с" % [int(p.main_tick), p.best_depth_m, p.best_time_s]
	_stats_label.text = "рассмотрено путей: %d · пересечений со стенами: %d (худший итог: %s)" % [int(p.explored), int(p.collisions), p.done_reason if p.done else "…"]
	if p.main_backend != p.worker_backend:
		pass
	_engine_label.text = "движок: " + _coop.backend_label() + " · CPU-поток тик %d" % int(p.worker_tick)
	if _coop.all_done():
		_stop_and_save("готово")

func _set_final_stats(result: Dictionary) -> void:
	_stats_label.text = "рассмотрено путей: %d · пересечений со стенами: %d" % [int(result.get("explored", 0)), int(result.get("collisions", 0))]
	_progress_label.text = "лучший путь: рекорд %.2f м · время %.1f с (%d тиков)" % [float(result.get("best_depth_m", 0.0)), float(result.get("best_time_s", 0.0)), int(result.get("best_tick", 0))]
	_engine_label.text = "победитель: %s" % result.get("winner", "?")

# --- TAS: сохранение / загрузка / проверка ---

func _save_tape(tape: Dictionary) -> int:
	var path: String = game_ref.TAS_PATH if game_ref != null else "user://tas.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(tape))
	return OK

func _on_save_pressed() -> void:
	var tape := _loaded_tape
	if tape.is_empty():
		_state_label.text = "Нечего сохранять: сначала расчёт или загрузка ленты"
		return
	var err := _save_tape(tape)
	if err == OK:
		_state_label.text = "Сохранено: user://tas.json · %d тиков · рекорд %.2f м" % [int(tape.get("ticks", 0)), float(tape.get("final_depth_m", 0.0))]
	else:
		_state_label.text = "Ошибка сохранения (код %d)" % err

func _on_load_pressed() -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.filters = PackedStringArray(["*.json ; Лента TAS (*.json)"])
	dlg.title = "Загрузить TAS"
	add_child(dlg)
	dlg.file_selected.connect(_on_file_selected)
	dlg.popup_centered(Vector2(720, 480))
	dlg.close_requested.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)

func _on_file_selected(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_state_label.text = "Не удалось открыть файл (код %d)" % FileAccess.get_open_error()
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary) or not data.has("inputs") or not (data["inputs"] is Array):
		_state_label.text = "Файл не похож на ленту TAS: нужен JSON с массивом inputs"
		return
	var inputs := []
	for i in range(data["inputs"].size()):
		var inp: Variant = data["inputs"][i]
		if not (inp is Dictionary):
			_state_label.text = "Лента битая: тик %d не объект" % i
			return
		var torque: float = clampf(float(inp.get("torque", 0.0)), -1.0, 1.0)
		var thrust: bool = bool(inp.get("thrust", false))
		inputs.append({"thrust": thrust, "torque": torque})
	var samples: Array = data.get("samples", [])
	_loaded_tape = {
		"version": int(data.get("version", 1)),
		"created": str(data.get("created", "")),
		"engine": str(data.get("engine", "file")),
		"final_depth_m": float(data.get("final_depth_m", 0.0)),
		"ticks": inputs.size(),
		"inputs": inputs,
		"samples": samples,
		"source": "file",
	}
	_loaded_from = path
	_inject_tape_into_game(_loaded_tape)
	_state_label.text = "Загружено: %s" % path
	_refresh_tape_label()
	_save_button.disabled = false
	_verify_button.disabled = false

func _inject_tape_into_game(tape: Dictionary) -> void:
	if game_ref == null:
		return
	var lane = game_ref._lane_by_id(0)
	if lane == null:
		return
	lane.tas.rec_inputs = tape.get("inputs", [])
	lane.tas.rec_samples = tape.get("samples", [])
	lane.tas.final_depth_m = float(tape.get("final_depth_m", 0.0))

func _on_verify_pressed() -> void:
	if game_ref == null:
		return
	var out: Dictionary = game_ref._tas_verify(0)
	if out.has("error"):
		_state_label.text = "Проверка не запущена: %s" % out["error"]
		return
	# прячем меню и запускаем реальное воспроизведение в игре
	_verify_watching = true
	_screen = "hidden"
	visible = false
	get_tree().paused = false
	_set_touch_visible(false)

func _poll_verify() -> void:
	if not _verify_watching:
		return
	if _tas_mode() == "verify":
		return
	# режим verify закончился — читаем вердикт и показываем экран результата
	var st: Dictionary = game_ref._tas_status(0)
	var verdict: String = str(st.get("last_result", ""))
	if verdict == "" or verdict == "verifying":
		return
	_verify_watching = false
	_show_result(verdict, st)

func _tas_mode() -> String:
	if game_ref == null:
		return "idle"
	var lane = game_ref._lane_by_id(0)
	if lane == null:
		return "idle"
	return str(lane.tas.get("mode", "idle"))

func _show_result(verdict: String, st: Dictionary) -> void:
	var pass_run := verdict.begins_with("PASS")
	_verdict_label.text = "ПРОЙДЕНО" if pass_run else "ПРОВАЛ"
	_verdict_label.add_theme_color_override("font_color", OK_GREEN if pass_run else ERR_RED)
	var detail := verdict
	var tsize := int(st.get("tape_ticks", 0))
	var err_pos := float(st.get("max_err_pos_px", 0.0))
	if pass_run:
		detail = "Ракета пережила всю ленту (%d тиков) без касания стен.\nрасхождение: %.4f px · тиков проверено: %d" % [tsize, err_pos, int(st.get("ticks_checked", 0))]
	_result_detail.text = detail
	get_tree().paused = true
	_show_screen("result")

# --- метки/рендер ---

func _refresh_tape_label() -> void:
	if not _loaded_tape.is_empty():
		_tape_label.text = "лента: %d тиков · рекорд %.2f м · %s" % [int(_loaded_tape.get("ticks", 0)), float(_loaded_tape.get("final_depth_m", 0.0)), _loaded_from]
		_save_button.disabled = false
		_verify_button.disabled = false
	elif game_ref != null and FileAccess.file_exists(game_ref.TAS_PATH):
		_tape_label.text = "лента: не загружена («Проверить» возьмёт user://tas.json)"
		_verify_button.disabled = false
	else:
		_tape_label.text = "лента: нет (нужен расчёт или загрузка)"

# --- построение UI ---

func _styled_button(text: String, height: int, font_size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, height)
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", TEXT)
	b.flat = false
	var normal := StyleBoxFlat.new()
	normal.bg_color = BTN_BG
	normal.set_corner_radius_all(9)
	normal.border_color = PANEL_BORDER
	normal.set_border_width_all(1)
	normal.content_margin_left = 16
	normal.content_margin_right = 16
	normal.content_margin_top = 8
	normal.content_margin_bottom = 8
	var hover := normal.duplicate()
	hover.bg_color = BTN_HOVER
	hover.border_color = AMBER
	var pressed := normal.duplicate()
	pressed.bg_color = BTN_PRESSED
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", normal.duplicate())
	b.add_theme_stylebox_override("disabled", normal.duplicate())
	return b

func _panel_root() -> PanelContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.set_corner_radius_all(14)
	sb.border_color = PANEL_BORDER
	sb.set_border_width_all(1)
	sb.content_margin_left = 26
	sb.content_margin_right = 26
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size = Vector2(480, 0)
	return panel

func _build_ui() -> void:
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0.02, 0.02, 0.04, 0.72)
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	# --- главное меню ---
	_main_panel = _panel_root()
	center.add_child(_main_panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_main_panel.add_child(vbox)

	var title := Label.new()
	title.text = "ROCKET LANDING"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", AMBER)
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "спуск по процедурной пещере · чем глубже, тем лучше"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 11)
	subtitle.add_theme_color_override("font_color", DIM)
	vbox.add_child(subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)

	var play_btn := _styled_button("Играть", 56, 22)
	play_btn.pressed.connect(_on_play_pressed)
	vbox.add_child(play_btn)

	var tas_btn := _styled_button("TAS · идеальный забег", 56, 18)
	tas_btn.pressed.connect(_on_tas_pressed)
	vbox.add_child(tas_btn)

	var footer := Label.new()
	var ver := "dev"
	var commit := ""
	var best := 0
	if game_ref != null:
		ver = game_ref.VERSION
		commit = game_ref.COMMIT
		best = game_ref.best
	footer.text = "v%s (%s) · лучший результат: %d м" % [ver, commit, best]
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_theme_font_size_override("font_size", 10)
	footer.add_theme_color_override("font_color", DIM)
	vbox.add_child(footer)

	# --- экран TAS ---
	_tas_panel = _panel_root()
	_tas_panel.visible = false
	center.add_child(_tas_panel)
	var tas_vbox := VBoxContainer.new()
	tas_vbox.add_theme_constant_override("separation", 8)
	_tas_panel.add_child(tas_vbox)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	tas_vbox.add_child(head)
	var back_btn := _styled_button("←", 44, 20)
	back_btn.custom_minimum_size = Vector2(52, 44)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back_btn.pressed.connect(_on_back_pressed)
	head.add_child(back_btn)
	var tas_title := Label.new()
	tas_title.text = "TAS — идеальный забег"
	tas_title.add_theme_font_size_override("font_size", 19)
	tas_title.add_theme_color_override("font_color", AMBER)
	tas_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tas_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(tas_title)

	_state_label = Label.new()
	_state_label.text = "Готов к расчёту."
	_state_label.add_theme_font_size_override("font_size", 12)
	_state_label.add_theme_color_override("font_color", TEXT)
	tas_vbox.add_child(_state_label)

	_progress_label = Label.new()
	_progress_label.text = "тик — · глубина —"
	_progress_label.add_theme_font_size_override("font_size", 13)
	_progress_label.add_theme_color_override("font_color", TEXT)
	tas_vbox.add_child(_progress_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0
	_progress_bar.max_value = 2700
	_progress_bar.value = 0
	_progress_bar.custom_minimum_size = Vector2(0, 18)
	_progress_bar.show_percentage = false
	tas_vbox.add_child(_progress_bar)

	_stats_label = Label.new()
	_stats_label.text = "рассмотрено путей: 0 · пересечений со стенами: 0"
	_stats_label.add_theme_font_size_override("font_size", 11)
	_stats_label.add_theme_color_override("font_color", DIM)
	tas_vbox.add_child(_stats_label)

	_engine_label = Label.new()
	_engine_label.text = "движок: —"
	_engine_label.add_theme_font_size_override("font_size", 10)
	_engine_label.add_theme_color_override("font_color", DIM)
	tas_vbox.add_child(_engine_label)

	_tape_label = Label.new()
	_tape_label.text = "лента: нет"
	_tape_label.add_theme_font_size_override("font_size", 11)
	_tape_label.add_theme_color_override("font_color", AMBER if game_ref != null else TEXT)
	tas_vbox.add_child(_tape_label)

	tas_vbox.add_child(HSeparator.new())

	_run_button = _styled_button("Запустить расчёт", 48, 17)
	_run_button.pressed.connect(_on_run_pressed)
	tas_vbox.add_child(_run_button)

	_save_button = _styled_button("Сохранить в файл (user://tas.json)", 44, 15)
	_save_button.disabled = true
	_save_button.pressed.connect(_on_save_pressed)
	tas_vbox.add_child(_save_button)

	var load_btn := _styled_button("Загрузить из файла…", 44, 15)
	load_btn.pressed.connect(_on_load_pressed)
	tas_vbox.add_child(load_btn)

	_verify_button = _styled_button("Проверить (воспроизвести в игре)", 44, 15)
	_verify_button.disabled = true
	_verify_button.pressed.connect(_on_verify_pressed)
	tas_vbox.add_child(_verify_button)

	var note := Label.new()
	note.text = "Перебор: на каждом тике (60 Гц) все 6 комбинаций (−, ←, →, ▲, ▲+←, ▲+→); столкновения со стенами считаются и ветвь отбрасывается. Побеждает путь с лучшим рекордом и временем."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 9)
	note.add_theme_color_override("font_color", DIM)
	tas_vbox.add_child(note)

	# --- экран результата проверки ---
	_result_panel = _panel_root()
	_result_panel.visible = false
	center.add_child(_result_panel)
	var res_vbox := VBoxContainer.new()
	res_vbox.add_theme_constant_override("separation", 12)
	res_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_result_panel.add_child(res_vbox)

	var res_title := Label.new()
	res_title.text = "ПРОВЕРКА TAS"
	res_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	res_title.add_theme_font_size_override("font_size", 14)
	res_title.add_theme_color_override("font_color", DIM)
	res_vbox.add_child(res_title)

	_verdict_label = Label.new()
	_verdict_label.text = "—"
	_verdict_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_verdict_label.add_theme_font_size_override("font_size", 42)
	res_vbox.add_child(_verdict_label)

	_result_detail = Label.new()
	_result_detail.text = ""
	_result_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_detail.add_theme_font_size_override("font_size", 13)
	_result_detail.add_theme_color_override("font_color", TEXT)
	res_vbox.add_child(_result_detail)

	var again_btn := _styled_button("Ещё раз проверить", 48, 17)
	again_btn.pressed.connect(_on_result_again_pressed)
	res_vbox.add_child(again_btn)

	var to_menu_btn := _styled_button("В меню", 48, 17)
	to_menu_btn.pressed.connect(_on_result_to_menu_pressed)
	res_vbox.add_child(to_menu_btn)
