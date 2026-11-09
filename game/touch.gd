class_name RocketTouch
extends CanvasLayer

# Сенсорное управление для Android: ◀ / ▶ (вращение) слева внизу и большая
# «ТЯГА» справа. Держишь — действует; отпустил — перестало.
# Кнопки эмулируют действия ui_left / ui_right / ui_up, поэтому вся механика
# torque.gd работает без изменений.
#
# Виден только на Android и только когда игра идёт (меню/проверка TAS
# закрывают его через _set_touch_visible).
# Состояние синхронизируется по is_pressed() в _process — надёжно работает
# даже если палец соскользнул с кнопки (button_up в этот момент не приходит).

const BTN_SIZE := 150.0
const THRUST_W := 230.0
const THRUST_H := 190.0
const MARGIN := 26.0

var _btn_left: Button
var _btn_right: Button
var _btn_thrust: Button
var _held := {"ui_left": false, "ui_right": false, "ui_up": false}

func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_PAUSABLE
	if OS.get_name() != "Android":
		# не Android — слой не нужен в принципе
		visible = false
		return
	_build()
	visible = true

func _exit_tree() -> void:
	_release_all()

func _build() -> void:
	_btn_left = _touch_button("◀", 54)
	_btn_right = _touch_button("▶", 54)
	_btn_thrust = _touch_button("ТЯГА", 30)
	_btn_thrust.custom_minimum_size = Vector2(THRUST_W, THRUST_H)

	_btn_left.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_btn_left.position = Vector2(MARGIN, -BTN_SIZE - MARGIN)
	_btn_right.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_btn_right.position = Vector2(MARGIN * 2.0 + BTN_SIZE, -BTN_SIZE - MARGIN)
	_btn_thrust.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_btn_thrust.position = Vector2(-THRUST_W - MARGIN, -THRUST_H - MARGIN)
	add_child(_btn_left)
	add_child(_btn_right)
	add_child(_btn_thrust)

func _touch_button(text: String, font_size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(BTN_SIZE, BTN_SIZE)
	b.focus_mode = Control.FOCUS_NONE
	b.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.85))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.12, 0.17, 0.55)
	normal.border_color = Color(1.0, 1.0, 1.0, 0.35)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(int(BTN_SIZE * 0.32))
	var pressed := normal.duplicate()
	pressed.bg_color = Color(1.0, 0.78, 0.32, 0.45)
	pressed.border_color = Color(1.0, 0.85, 0.4, 0.95)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover", normal)
	b.add_theme_stylebox_override("focus", normal)
	return b

func _process(_delta: float) -> void:
	if OS.get_name() != "Android" or not visible:
		_release_all()
		return
	_sync("ui_left", _btn_left.is_pressed())
	_sync("ui_right", _btn_right.is_pressed())
	_sync("ui_up", _btn_thrust.is_pressed())

func set_touch_visible(v: bool) -> void:
	visible = v if OS.get_name() == "Android" else false
	if not visible:
		_release_all()

func _sync(action: String, held: bool) -> void:
	if held and not _held[action]:
		Input.action_press(action)
		_held[action] = true
	elif not held and _held[action]:
		Input.action_release(action)
		_held[action] = false

func _release_all() -> void:
	for action in _held.keys():
		if _held[action]:
			Input.action_release(action)
		_held[action] = false
