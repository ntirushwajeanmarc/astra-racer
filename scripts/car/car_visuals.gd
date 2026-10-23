class_name CarVisuals
extends Node3D
# Everything about the car you can see: spinning and steering wheels, weight
# transfer under braking and cornering, tyre smoke, skid marks and the boost
# flame. Driven entirely from the car's own state, so it can never disagree with
# the physics.

const TYRE_WIDTH := 0.30

var wheels: Array[Node3D] = []
var wheel_rest: Array[Vector3] = []
var wheel_radius := 0.34
var exhaust := Vector3(0.0, 0.5, 1.7)
var model_root: Node3D
var skid_marks: SkidMarks

var _spin := [0.0, 0.0, 0.0, 0.0]
var _tilt := Vector3.ZERO
var _smoke: GPUParticles3D
var _flame: MeshInstance3D
var _last_rear := [Vector3.ZERO, Vector3.ZERO]
var _rear_valid := false


func setup(p_model_root: Node3D, p_wheels: Array[Node3D], p_rest: Array[Vector3],
		p_radius: float, p_skid: SkidMarks,
		p_exhaust := Vector3(0.0, 0.5, 1.7)) -> void:
	model_root = p_model_root
	wheels = p_wheels
	wheel_rest = p_rest
	wheel_radius = p_radius
	skid_marks = p_skid
	exhaust = p_exhaust
	_build_smoke()
	_build_flame()


func _build_smoke() -> void:
	_smoke = GPUParticles3D.new()
	_smoke.name = "TyreSmoke"
	_smoke.amount = 28
	_smoke.lifetime = 0.85
	_smoke.local_coords = false
	_smoke.emitting = false
	_smoke.draw_pass_1 = _smoke_quad()
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0, 1, 0)
	process.spread = 32.0
	process.initial_velocity_min = 0.8
	process.initial_velocity_max = 2.6
	process.gravity = Vector3(0, 0.9, 0)
	process.scale_min = 0.5
	process.scale_max = 1.4
	process.color = Color(0.86, 0.86, 0.88, 0.30)
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.4
	process.angular_velocity_min = -60.0
	process.angular_velocity_max = 60.0
	_smoke.process_material = process
	add_child(_smoke)


func _smoke_quad() -> Mesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.95, 0.95)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = _radial_texture(64)
	quad.material = material
	return quad


func _radial_texture(size: int) -> ImageTexture:
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var half := float(size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(float(x) - half, float(y) - half).length() / half
			var a := clampf(1.0 - d, 0.0, 1.0)
			image.set_pixel(x, y, Color(1, 1, 1, a * a))
	return ImageTexture.create_from_image(image)


func _build_flame() -> void:
	_flame = MeshInstance3D.new()
	_flame.name = "BoostFlame"
	var mesh := SphereMesh.new()
	mesh.radius = 0.16
	mesh.height = 0.9
	_flame.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.62, 0.18)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.45, 0.08)
	material.emission_energy_multiplier = 3.5
	_flame.material_override = material
	_flame.visible = false
	add_child(_flame)


func update(car: Car, delta: float) -> void:
	if delta <= 0.0:
		return
	_update_wheels(car, delta)
	_update_body(car, delta)
	_update_effects(car, delta)


func _update_wheels(car: Car, delta: float) -> void:
	# Negative: the front wheels point right when the car is steering right.
	var steer_visual := -car.steer_state * 0.52
	for i in wheels.size():
		var wheel := wheels[i]
		if wheel == null or not is_instance_valid(wheel):
			continue
		_spin[i] = fmod(_spin[i] + car.forward_speed / maxf(0.05, wheel_radius) * delta, TAU)
		var is_front := i < 2
		wheel.rotation = Vector3(_spin[i], steer_visual if is_front else 0.0, 0.0)


func _update_body(car: Car, delta: float) -> void:
	if model_root == null:
		return
	# Weight transfer: squat under power, dive under braking, lean out of the
	# corner. Small angles - this is feel, not a physics model.
	var accel_long := (car.controls.throttle - car.controls.brake) * 0.045
	if car.boosting:
		accel_long += 0.03
	var lean := clampf(car.lateral_speed / 12.0, -1.0, 1.0) * 0.05
	var target := Vector3(accel_long, 0.0, lean)
	_tilt = _tilt.lerp(target, clampf(9.0 * delta, 0.0, 1.0))
	model_root.rotation = _tilt


func _update_effects(car: Car, delta: float) -> void:
	var slip := car.clutter()
	var speed := absf(car.forward_speed)
	var sliding := slip > 0.12 and speed > 3.0
	if _smoke != null:
		_smoke.emitting = sliding
		if sliding:
			# Between the rear tyres, taken from where the wheels actually are.
			_smoke.position = Vector3(0.0, 0.18, (wheel_rest[2].z + wheel_rest[3].z) * 0.5)
	if _flame != null:
		_flame.visible = car.boosting
		if car.boosting:
			_flame.position = exhaust
			var stretch := 1.0 + 0.9 * absf(sin(Time.get_ticks_msec() * 0.02))
			_flame.scale = Vector3(0.7, stretch, 0.7)
	if skid_marks == null:
		return
	# Skid marks from the rear tyres, drawn between this frame's contact point and
	# the last one so they follow the car's path.
	var rear := 0
	for i in wheel_rest.size():
		if i == 2 or i == 3:
			rear = i
			var local := wheel_rest[i] + Vector3(0, 0.06, 0)
			var world := car.to_global(local)
			if _rear_valid and (sliding or car.controls.handbrake) and speed > 2.0:
				var last: Vector3 = _last_rear[i - 2]
				if last.distance_to(world) > 0.05 and last.distance_to(world) < 4.0:
					skid_marks.add_segment(last, world, TYRE_WIDTH)
			_last_rear[i - 2] = world
	_rear_valid = true
