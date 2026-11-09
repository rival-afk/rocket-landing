# tas_headless.gd — расчёт TAS без GUI (Linux/CI, машин без дисплея).
#
# Запуск из корня репо:
#   godot --headless --path game -s tas_headless.gd -- [опции]
#   godot --path game -s tas_headless.gd -- [опции]     # с дисплеем: GPU-compute, если Vulkan есть
#
# Опции (после `--`):
#   --beam-main=192    луч главного (GPU/CPU) экземпляра
#   --beam-worker=192  луч второго (CPU-поток) экземпляра
#   --max-ticks=2700   лимит тиков (60 Гц; 2700 = 45 с игрового времени)
#   --out=user://tas.json   куда сохранить ленту
#   --quiet            не печатать прогресс каждые 5 с
#
# По окончании печатает сводку (победитель, рассмотрено путей, лучшая глубина)
# и пишет ленту в --out. Выход: 0 — лента найдена, 1 — нет.
#
# В headless локальный RenderingDevice недоступен (dummy-драйвер), поэтому
# работает честный fallback «CPU ×2» — как и в меню, GPU не имитируется.

extends SceneTree

const TASSearchCoop = preload("res://tas_coop.gd")

var _coop = null
var _out_path := "user://tas.json"
var _quiet := false
var _last_report_msec := 0
var _started_msec := 0

func _initialize() -> void:
	var beam_main := 192
	var beam_worker := 192
	var max_ticks := 2700
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--beam-main="):
			beam_main = int(arg.trim_prefix("--beam-main="))
		elif arg.begins_with("--beam-worker="):
			beam_worker = int(arg.trim_prefix("--beam-worker="))
		elif arg.begins_with("--max-ticks="):
			max_ticks = int(arg.trim_prefix("--max-ticks="))
		elif arg.begins_with("--out="):
			_out_path = arg.trim_prefix("--out=")
		elif arg == "--quiet":
			_quiet = true
	print("TAS headless: beam_main=%d beam_worker=%d max_ticks=%d out=%s" % [beam_main, beam_worker, max_ticks, _out_path])
	_started_msec = Time.get_ticks_msec()
	_coop = TASSearchCoop.new(beam_main, beam_worker, max_ticks)
	print("TAS headless: движок: %s" % _coop.backend_label())

func _process(_delta: float) -> bool:
	_coop.main_step(4)
	var now := Time.get_ticks_msec()
	if not _quiet and now - _last_report_msec >= 5000:
		_last_report_msec = now
		var p: Dictionary = _coop.progress()
		print("TAS headless: тик %d/%d (worker %d) · глубина %.2f м · рассмотрено %d путей · пересечений %d" % [
			int(p.main_tick), _coop.max_ticks, int(p.worker_tick),
			float(p.best_depth_m), int(p.explored), int(p.collisions)])
	if not _coop.all_done():
		return false
	var result: Dictionary = _coop.finish()
	var tape: Dictionary = result.get("tape", {})
	if tape.is_empty():
		printerr("TAS headless: не найдено ни одного выжившего пути")
		quit(1)
		return true
	var f := FileAccess.open(_out_path, FileAccess.WRITE)
	if f == null:
		printerr("TAS headless: не могу открыть %s на запись (код %d)" % [_out_path, FileAccess.get_open_error()])
		quit(1)
		return true
	f.store_string(JSON.stringify(tape))
	f.close()
	var wall_s := (Time.get_ticks_msec() - _started_msec) / 1000.0
	print("TAS headless: готово за %.1f с · победитель: %s" % [wall_s, result.get("winner", "?")])
	print("TAS headless: рассмотрено %d путей, пересечений со стенами %d" % [int(result.get("explored", 0)), int(result.get("collisions", 0))])
	print("TAS headless: лучший путь — рекорд %.2f м за %.1f с (%d тиков), лента -> %s" % [
		float(result.get("best_depth_m", 0.0)), float(result.get("best_time_s", 0.0)),
		int(result.get("best_tick", 0)), _out_path])
	quit(0)
	return true
