# TASSearchGPU — GPU-ускоренный перебор путей (всё остальное как в TASSearch).
# На каждом тике сжимает текущий луч (beam) × 6 действий одним compute-шейдером:
# интегрирует физику, считает пересечение со стенами (5 контрольных точек
# ракеты против коридора) и оценку ветви. CPU остаётся только дедупликация,
# сортировка и выбор лучших — они дешёвые.
#
# Условия работы GPU-пути:
#   - Vulkan-устройства с compute shaders (Android — почти все современные);
#   - RenderingServer.create_local_rendering_device() != null;
#   - скомпилированный res://tas_kernel.glsl.spv (собирается build-скриптом
#     из tas_kernel.glsl через glslangValidator, в репо лежит готовым).
# Если что-то не так — класс честно сообщает об этом через gpu_disabled,
# и step() прозрачно считает тик на CPU (см. TASSearch._gpu_fallback).
class_name TASSearchGPU
extends "res://tas_search.gd"

const SPV_PATH := "res://tas_kernel.glsl.spv"
const LOCAL_SIZE := 64
const OUT_FLOATS := 8   # nx, ny, nvx, nvy, nrot, hit(0/1), score, pad

var gpu_disabled := false
var gpu_error := ""

var _rd: RenderingDevice = null
var _shader: RID
var _pipeline: RID
var _ready := false

func begin(p_beam_width: int, p_max_ticks: int) -> void:
	super.begin(p_beam_width, p_max_ticks)
	gpu_error = ""
	_ensure_gpu()

# Явное освобождение RD (вызывает меню при выходе/остановке).
func close() -> void:
	_free_gpu()

func _ensure_gpu() -> bool:
	if _ready:
		return true
	if gpu_disabled:
		return false
	if RenderingServer == null:
		gpu_error = "no rendering server"
		gpu_disabled = true
		return false
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		gpu_error = "local RenderingDevice unavailable (headless or GLES3)"
		gpu_disabled = true
		return false
	if not FileAccess.file_exists(SPV_PATH):
		gpu_error = "kernel bytecode missing: " + SPV_PATH
		gpu_disabled = true
		_free_rd_only()
		return false
	var spirv := FileAccess.get_file_as_bytes(SPV_PATH)
	if spirv.is_empty():
		gpu_error = "kernel bytecode empty: " + SPV_PATH
		gpu_disabled = true
		_free_rd_only()
		return false
	var shader_res := RDShaderSPIRV.new()
	shader_res.bytecode_compute = spirv
	_shader = _rd.shader_create_from_spirv(shader_res)
	if _shader.is_valid() == false:
		gpu_error = "shader_create_from_spirv failed"
		gpu_disabled = true
		_free_rd_only()
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	_ready = true
	print("TASSearchGPU: compute shaders active")
	return true

func _free_rd_only() -> void:
	if _rd != null:
		_rd.free()
	_rd = null

func _free_gpu() -> void:
	if _rd == null:
		return
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
	_rd.free()
	_rd = null
	_ready = false

# Переопределяем генерацию детей: GPU вместо CPU. null → fallback на CPU в step().
func _generate_children(beam_ids: Array[int]) -> Variant:
	if gpu_disabled or _gpu_fallback:
		return _generate_children_cpu(beam_ids)
	if not _ensure_gpu():
		return null

	var n := beam_ids.size()
	if n == 0:
		return []
	var children_n := n * ACTIONS.size()

	# упаковка входа: [x, y, vx, vy, rot] * n
	var in_bytes := PackedFloat32Array()
	in_bytes.resize(n * 5)
	for i in range(n):
		var nid := beam_ids[i]
		in_bytes[i * 5 + 0] = _px[nid]
		in_bytes[i * 5 + 1] = _py[nid]
		in_bytes[i * 5 + 2] = _pvx[nid]
		in_bytes[i * 5 + 3] = _pvy[nid]
		in_bytes[i * 5 + 4] = _prot[nid]

	var in_arr_bytes := in_bytes.to_byte_array()
	var in_buf := _rd.storage_buffer_create(in_arr_bytes.size(), in_arr_bytes)
	var out_buf := _rd.storage_buffer_create(children_n * OUT_FLOATS * 4)
	var uniform_in := RDUniform.new()
	uniform_in.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_in.binding = 0
	uniform_in.add_id(in_buf)
	var uniform_out := RDUniform.new()
	uniform_out.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_out.binding = 1
	uniform_out.add_id(out_buf)
	var uniform_set := _rd.uniform_set_create([uniform_in, uniform_out], _shader, 0)

	var groups := int(ceil(children_n / float(LOCAL_SIZE)))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	var out_bytes := _rd.buffer_get_data(out_buf)
	_rd.free_rid(out_buf)
	_rd.free_rid(in_buf)

	var out := _bytes_to_floats(out_bytes)
	var children_n2 := int(out.size() / OUT_FLOATS)
	if children_n2 != children_n:
		gpu_error = "unexpected readback size: %d floats" % out.size()
		return null

	var children := []
	children.resize(children_n)
	for gid in range(children_n):
		var parent := gid / ACTIONS.size()
		var action := gid % ACTIONS.size()
		var o := gid * OUT_FLOATS
		children[gid] = [
			out[o + 0], out[o + 1], out[o + 2], out[o + 3], out[o + 4],
			beam_ids[parent], action, out[o + 6], out[o + 5],
		]
	return children

func _bytes_to_floats(bytes: PackedByteArray) -> PackedFloat32Array:
	var floats := PackedFloat32Array()
	floats.resize(bytes.size() / 4)
	for i in range(floats.size()):
		floats[i] = bytes.decode_float(i * 4)
	return floats
