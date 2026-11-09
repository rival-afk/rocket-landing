class_name TASSearchCoop
extends RefCounted

const TASSearch = preload("res://tas_search.gd")
const TASSearchGPU = preload("res://tas_gpu_search.gd")

# Параллельный TAS-поиск: главный луч (GPU compute, если устройство его умеет,
# иначе CPU) + независимый CPU-поток с более широким лучом. Оба пишут свои
# SoA-пулы независимо; победитель (лучший рекорд, при равенстве — меньшее
# время) выбирается в finish(). Никакого ручного слияния деревьев не нужно:
# пещера детерминирована, поэтому сравнение сводится к глубине и тикам.
#
# Индикация в меню честная: если local RenderingDevice недоступен
# (headless/GLES3), работает «CPU ×2», GPU не имитируется.

var beam_main := 24
var beam_worker := 32
var max_ticks := 2700

var _main: TASSearch
var _worker: TASSearch
var _thread: Thread
var _shared := {}
var _finished := false

func _init(p_beam_main := 24, p_beam_worker := 32, p_max_ticks := 2700) -> void:
	beam_main = p_beam_main
	beam_worker = p_beam_worker
	max_ticks = p_max_ticks
	_shared = {"stop": false, "w_done": false, "w_prog": {}, "w_tape": {}}

	# GPU, если железо позволяет; иначе — второй CPU-луч
	var probe := TASSearchGPU.new()
	probe.begin(beam_main, max_ticks)
	if probe.gpu_disabled:
		_main = TASSearch.new()
		_main.begin(beam_main, max_ticks)
	else:
		_main = probe

	_worker = TASSearch.new()
	_thread = Thread.new()
	_thread.start(_worker_run)

func _worker_run() -> void:
	var ws := _worker
	ws.begin(beam_worker, max_ticks)
	while true:
		if bool(_shared.get("stop", false)):
			break
		if ws.done:
			break
		ws.step(4)
		_shared["w_prog"] = ws.progress()
	_shared["w_tape"] = ws.best_tape()
	_shared["w_done"] = true

func backend_label() -> String:
	if _main is TASSearchGPU and not _main.gpu_disabled:
		return "GPU (compute) + CPU-поток"
	return "CPU ×2 параллельно (GPU недоступен)"

func main_step(n: int) -> void:
	if _finished or _main == null:
		return
	_main.step(n)

func all_done() -> bool:
	return _main != null and _main.done and bool(_shared.get("w_done", false))

func progress() -> Dictionary:
	var mp := _main.progress() if _main != null else {}
	var wp: Dictionary = _shared.get("w_prog", {})
	var m_depth := float(mp.get("best_depth_m", 0.0))
	var w_depth := float(wp.get("best_depth_m", 0.0))
	var m_time := float(mp.get("best_time_s", 0.0))
	var w_time := float(wp.get("best_time_s", 0.0))
	var deeper_time := w_time if w_depth >= m_depth else m_time
	return {
		"main_tick": int(mp.get("tick", 0)),
		"worker_tick": int(wp.get("tick", 0)),
		"explored": int(mp.get("explored", 0)) + int(wp.get("explored", 0)),
		"collisions": int(mp.get("collisions", 0)) + int(wp.get("collisions", 0)),
		"best_depth_m": maxf(m_depth, w_depth),
		"best_time_s": deeper_time,
		"main_backend": "gpu" if (_main is TASSearchGPU and not _main.gpu_disabled) else "cpu",
		"worker_backend": "cpu",
		"done": _main != null and _main.done,
		"done_reason": str(mp.get("done_reason", "")),
	}

# Останавливает обоих, ждёт воркера, выбирает победителя и возвращает сводку.
func finish() -> Dictionary:
	if _finished:
		return {}
	_finished = true
	_shared["stop"] = true
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()

	var m_prog := _main.progress()
	var m_tape := _main.best_tape()
	var w_tape: Dictionary = _shared.get("w_tape", {})
	var w_prog: Dictionary = _shared.get("w_prog", {})

	var m_depth := float(m_prog.get("best_depth_m", 0.0))
	var w_depth := float(w_prog.get("best_depth_m", 0.0))
	var m_time := float(m_prog.get("best_time_s", 0.0))
	var w_time := float(w_prog.get("best_time_s", 0.0))

	var winner := "GPU" if (_main is TASSearchGPU and not _main.gpu_disabled) else "CPU"
	var tape := m_tape
	if not w_tape.is_empty() and (w_depth > m_depth or (is_equal_approx(w_depth, m_depth) and w_time < m_time)):
		tape = w_tape
		winner = "CPU (поток)"
	elif w_tape.is_empty():
		winner += " (воркер без результата)"

	var explored := int(m_prog.get("explored", 0)) + int(w_prog.get("explored", 0))
	var collisions := int(m_prog.get("collisions", 0)) + int(w_prog.get("collisions", 0))

	# освобождаем GPU-устройство
	if _main is TASSearchGPU:
		(_main as TASSearchGPU).close()

	return {
		"winner": winner,
		"tape": tape,
		"explored": explored,
		"collisions": collisions,
		"best_depth_m": maxf(m_depth, w_depth),
		"best_time_s": float(tape.get("best_time_s", minf(m_time, w_time))),
		"best_tick": int(tape.get("ticks", 0)),
	}
