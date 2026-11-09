extends RigidBody2D

@export var thrust_power := 1500
@export var torque_power := 10000.0
@export var max_angular_velocity := 5.0  # рад/с, ограничение скорости вращения

# Виртуальное управление через API (устанавливается game.gd).
# Если api_torque == 0 и api_thrust == false — работает клавиатура.
var api_thrust := false
var api_torque := 0.0  # -1 = влево, 0 = нет, +1 = вправо

func _physics_process(_delta: float) -> void:
	# Вращение
	var rotation_dir := Input.get_axis("ui_left", "ui_right")
	if api_torque != 0.0:
		rotation_dir = api_torque
	if rotation_dir != 0.0:
		angular_velocity = rotation_dir * 4.0  # рад/с
	else:
		angular_velocity = 0.0

	# Тяга
	if Input.is_action_pressed("ui_up") or api_thrust:
		apply_central_force(Vector2.UP.rotated(rotation) * thrust_power)
