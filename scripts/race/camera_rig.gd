class_name CameraRig
extends Node3D
# Chase/bonnet camera. Position is smoothed in world space but yaw is taken from
# a look-ahead point, so the camera leads into corners instead of staring at the
# back of the car. Field of view opens up with speed, and impacts shake it.

const OFFSETS := [
	Vector3(0.0, 3.5, 8.4),    # chase
	Vector3(0.0, 2.3, 6.1),    # close chase
	Vector3(0.0, 1.18, -0.42), # bonnet
]

@export var base_fov := 68.0
@export var max_fov := 86.0

var car: Car
var mode := 0
var look_back := false
var position_lag := 7.5
var _camera: Camera3D
var _shake := 0.0
var _current := Vector3.ZERO
var _initialised := false


func _ready() -> void:
	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.fov = base_fov
	_camera.near = 0.15
	_camera.far = 2200.0
	add_child(_camera)
	top_level = false


func follow(p_car: Car, p_mode := 0) -> void:
	if car != null and car.respawned.is_connected(_on_respawn):
		car.respawned.disconnect(_on_respawn)
	if car != null and car.impacted.is_connected(_on_impact):
		car.impacted.disconnect(_on_impact)
	car = p_car
	mode = clampi(p_mode, 0, OFFSETS.size() - 1)
	_initialised = false
	if car != null:
		car.respawned.connect(_on_respawn)
		car.impacted.connect(_on_impact)


func _on_respawn() -> void:
	_initialised = false


func _on_impact(strength: float) -> void:
	_shake = minf(1.5, _shake + clampf(strength / 18.0, 0.15, 1.2))


func _process(delta: float) -> void:
	if car == null or not is_instance_valid(car):
		return
	var basis := car.global_transform.basis
	var offset: Vector3 = OFFSETS[mode]
	if look_back:
		offset.z = -offset.z
	var wanted := car.global_position + basis * offset
	var up := basis.y

	if mode == 2 and not look_back:
		# Bonnet cam is rigid: no lag, or it feels like the camera is on a rope.
		global_position = wanted
		global_transform.basis = Basis(basis.x, basis.y, basis.z)
	else:
		if not _initialised:
			_current = wanted
			_initialised = true
		# Higher speed pulls the camera back a touch, which sells the speed.
		var speed := absf(car.forward_speed)
		_current = _current.lerp(wanted, clampf(position_lag * delta * (1.0 + speed / 90.0), 0.0, 1.0))
		global_position = _current
		var forward := -basis.z
		var look_at_point := car.global_position + forward * (7.0 + speed * 0.10) + up * 1.15
		if look_back:
			look_at_point = car.global_position - forward * 12.0 + up * 1.2
		look_at(look_at_point, up)

	if _shake > 0.001:
		_shake = maxf(0.0, _shake - delta * 2.6)
		var amp := _shake * 0.28
		_camera.h_offset = randf_range(-amp, amp)
		_camera.v_offset = randf_range(-amp, amp)
	else:
		_camera.h_offset = 0.0
		_camera.v_offset = 0.0

	var speed_ratio := clampf(absf(car.forward_speed) / maxf(car.max_speed, 1.0), 0.0, 1.2)
	var target_fov := lerpf(base_fov, max_fov, clampf(speed_ratio, 0.0, 1.0))
	if car.boosting:
		target_fov += 4.0
	_camera.fov = lerpf(_camera.fov, target_fov, clampf(4.0 * delta, 0.0, 1.0))


func cycle_mode() -> void:
	mode = (mode + 1) % OFFSETS.size()
	_initialised = false
