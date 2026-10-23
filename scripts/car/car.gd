class_name Car
extends CharacterBody3D
# Arcade car physics. Not a full tyre model: a bicycle-model yaw rate clamped by
# a lateral grip budget, plus world-space velocity whose sideways component is
# only removed as fast as the tyres can manage. That single choice is what makes
# the car slide when you ask too much of it and drift under handbrake, while
# staying predictable enough to drive on a keyboard.
#
# Everything geometric - collider, wheelbase, wheel positions, ride height - is
# read off the Kenney GLB's own named wheel nodes at spawn, so the car cannot
# drifts out of sync with the art, and the art carries the car's direction in its
# silhouette: see scripts/car/f1_body.gd.

signal impacted(strength: float)
signal respawned

const AI_COLOURS := ["white", "green", "orange", "white", "green", "orange", "white"]

# Collision layers, defined in one place: scripts/core/layers.gd. The car is on
# CARS; its body hits the WORLD, the OBSTACLE and the other cars; and the ground
# rays below are masked to the WORLD alone.
#
# That last difference is the load-bearing one. A barrier is a closed ribbon with
# a top face, and anything the rays can see is a surface `_apply_ground` will park
# the car on - it is a placement, not a force, so nothing stops it. A ray that
# caught the top of a wall told the car the ground was a metre and a half higher
# than it was, the car was placed up there, and its other rays then found the wall
# as well: it ratcheted up and ended balanced on the barrier with its wheels
# hanging down either side, which is a car submerged in a road separator. The
# same is true of a building and of a tree trunk, which is why they are on
# OBSTACLE too.

# --- straight-line performance ---
@export var max_speed := 62.0            # m/s, ~223 km/h; drag settles it near 195
@export var reverse_max_speed := 11.0
@export var engine_force := 16.0         # m/s^2 at a standstill
@export var boost_force := 27.0
@export var brake_force := 32.0
@export var drag := 0.0021               # quadratic, sets the top speed
@export var rolling_resistance := 1.1

# --- grip and steering ---
@export var grip_lateral := 25.0         # m/s^2 of sideways friction available
@export var grip_handbrake := 7.5
@export var grip_offtrack := 13.0
@export var lateral_accel_limit := 18.5  # m/s^2 grip budget for the steering clamp
@export var steer_max_rad := 0.60        # steering lock at a standstill
@export var steer_rate := 4.6            # how fast the wheels turn, rad/s
@export var air_control := 0.30
@export var align_rate := 9.0            # how fast the body follows the ground

# --- arcade extras ---
@export var gravity_force := 26.0
@export var boost_drain := 0.42
@export var boost_charge_rate := 0.075
@export var ride_height := 0.04

const GEAR_TOPS := [13.0, 21.0, 30.0, 40.0, 51.0, 62.0]
const SHIFT_TIME := 0.13

var controls := CarControls.new()
var driver = null                 # PlayerDriver or AiDriver: polls into `controls`
var visuals: CarVisuals = null
var body: F1Body = null
var skid_marks: SkidMarks = null
var track: TrackInfo = null
var is_player := false
var locked := false
var colour := "red"
var driver_name := "Player"

# live state (read by HUD, drivers, AI, tests)
var forward_speed := 0.0
var lateral_speed := 0.0
var steer_state := 0.0
var yaw_rate := 0.0
var on_ground := true
var wheels_on_ground := 0
var wheels_on_road := 0
var surface_mu := 1.0
var off_track := false
var gear := 1
var engine_rpm := 0.15
var shift_timer := 0.0
var boost_charge := 1.0
var boosting := false
var track_s := 0.0
var wrong_way := false
var finished := false
var last_impact := 0.0
# Damage, 0..1. Race control puts it there when the car hits something hard
# enough; the car spends it as engine power and top speed until it is reset.
var damage := 0.0

# measured off the body at spawn
var wheelbase := 2.9
var track_width := 1.5
var wheel_radius := 0.36
var body_size := Vector3(2.0, 1.15, 4.8)
var _wheel_nodes: Array[Node3D] = []
var _wheel_rest: Array[Vector3] = []   # local positions relative to the car root
var _ground_queries: Array[Vector3] = []

var _model_root: Node3D
var _engine_player: AudioStreamPlayer3D
var _scrub_player: AudioStreamPlayer3D
var _prev_velocity := Vector3.ZERO
var _rays: Array[RayCast3D] = []


func _ready() -> void:
	_build_body()
	controls.reset()


# ----------------------------------------------------------------- geometry

func _build_body() -> void:
	_model_root = Node3D.new()
	_model_root.name = "Model"
	add_child(_model_root)

	# The body is generated rather than loaded: scripts/car/f1_body.gd. It is built
	# to real Formula One proportions in metres and reports the four wheel nodes and
	# the bounds of every vertex it emitted, so wheelbase, track, wheel radius,
	# collider and ground rays are all measured off the art that is on screen.
	body = F1Body.new(colour)
	_model_root.add_child(body)
	body.build()

	# Two things are needed from each wheel: where it sits on the car (wheelbase,
	# track width, ground rays) and how big its mesh is (wheel radius). The position
	# has to come from the node's own transform, never from its AABB - the AABB
	# gives the size but is centred on the node, which is the mistake that once made
	# every car believe its wheelbase was one metre.
	var centres: Array[Vector3] = []
	var sizes: Array[Vector3] = []
	for wheel: Node3D in body.wheel_nodes:
		_wheel_nodes.append(wheel)
		centres.append(wheel.position)
		sizes.append(_mesh_extent(wheel))

	var full := body.bounds
	if centres.size() == 4:
		wheel_radius = maxf(0.15, sizes[0].y * 0.5)
		var front := (centres[0] + centres[1]) * 0.5
		var back := (centres[2] + centres[3]) * 0.5
		wheelbase = maxf(1.0, absf(front.z - back.z))
		track_width = maxf(0.8, absf(centres[0].x - centres[1].x))
	else:
		push_warning("Car: the body built %d wheel nodes, expected 4" % centres.size())
	body_size = Vector3(
		maxf(1.0, full.size.x),
		maxf(0.5, full.size.y),
		maxf(1.5, full.size.z)
	)

	# Centre the art on its footprint and drop it so the tyres rest on y = 0. The
	# wheels sit at the same offset, so the contact points stay under them.
	var centre := full.get_center()
	_model_root.position = Vector3(-centre.x, -full.position.y, -centre.z)

	# Collider: a box a little narrower and shorter than the art so door-to-door
	# racing does not feel magnetic - and lifted clear of the ground, because
	# the ground is not its job.
	#
	# This box used to sit *on* the contact plane, and that is a mistake this
	# car's whole design argues against: ride height, pitch and what the car is
	# standing on all come from the four wheel rays, and the body then follows
	# the surface they found. A box whose underside is the contact plane fights
	# that. On a hill it is an axis-aligned slab held level with the ground it
	# is on: over four and a half metres of a 10% gradient its leading edge is
	# a quarter of a metre inside the hillside, so `move_and_slide` shoves the
	# car every frame while `_apply_ground` puts it back. Driving the lap in a
	# straight line, one frame in eight had the chassis in the dirt.
	#
	# So it starts above the kerbs - which is the highest thing the car is
	# meant to ride over rather than hit - and its job is what is left: walls,
	# buildings, and the other four cars.
	var clearance := minf(wheel_radius * 0.5, body_size.y * 0.25)
	var shape := BoxShape3D.new()
	shape.size = Vector3(body_size.x * 0.94,
		maxf(0.4, body_size.y - clearance),
		body_size.z * 0.96)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = Vector3(0, clearance + shape.size.y * 0.5, 0)
	add_child(collider)

	# Layers: the car is on CARS, and its body hits the WORLD, the OBSTACLE and
	# the other cars. The ground rays below look at the WORLD only, so nothing a
	# car must not stand on - a barrier, a building, a tree trunk, another car's
	# bodywork - can be mistaken for the ground.
	collision_layer = Layers.CARS
	collision_mask = Layers.CAR_MASK

	# Wheel contact points, expressed in the car's own frame.
	_wheel_rest.clear()
	for c: Vector3 in centres:
		_wheel_rest.append(Vector3(c.x - centre.x, 0.0, c.z - centre.z))
	if _wheel_rest.is_empty():
		var hw := track_width * 0.5
		var hb := wheelbase * 0.5
		_wheel_rest = [
			Vector3(-hw, 0, -hb), Vector3(hw, 0, -hb),
			Vector3(-hw, 0, hb), Vector3(hw, 0, hb),
		]

	# Ground sensing: four rays as children of the car, so the physics server
	# keeps them in step as it moves - unlike querying the space state by hand
	# outside a physics step, which silently finds nothing.
	for rest: Vector3 in _wheel_rest:
		var ray := RayCast3D.new()
		ray.name = "GroundRay"
		ray.position = rest + Vector3(0, wheel_radius * 2.4, 0)
		ray.target_position = Vector3(0, -wheel_radius * 6.0, 0)
		ray.collide_with_areas = false
		ray.collision_mask = Layers.GROUND_MASK
		ray.add_exception(self)
		add_child(ray)
		_rays.append(ray)

	_engine_player = AudioStreamPlayer3D.new()
	_engine_player.stream = Sfx.stream("engine")
	_engine_player.unit_size = 18.0
	_engine_player.volume_db = -60.0
	_engine_player.max_distance = 90.0
	add_child(_engine_player)
	_engine_player.play()

	_scrub_player = AudioStreamPlayer3D.new()
	_scrub_player.stream = Sfx.stream("screech")
	_scrub_player.unit_size = 10.0
	_scrub_player.volume_db = -60.0
	_scrub_player.max_distance = 60.0
	add_child(_scrub_player)
	_scrub_player.play()

	visuals = CarVisuals.new()
	visuals.name = "Visuals"
	add_child(visuals)
	visuals.setup(_model_root, _wheel_nodes, _wheel_rest, wheel_radius, skid_marks,
		body.EXHAUST + Vector3(0.0, 0.0, _model_root.position.z))
	add_to_group("cars")


func _mesh_extent(node: Node3D) -> Vector3:
	# The extent of everything drawn under `node`, in `node`'s own frame: the wheel
	# radius, which the ground rays and the visual spin both depend on.
	var total := AABB()
	var have := false
	var stack: Array = [node]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		var xf := node.global_transform.inverse() * (cur as Node3D).global_transform
		if cur is MeshInstance3D and (cur as MeshInstance3D).mesh != null:
			var box: AABB = xf * (cur as MeshInstance3D).get_aabb()
			if have:
				total = total.merge(box)
			else:
				total = box
				have = true
		for c in cur.get_children():
			stack.append(c)
	return total.size


# ------------------------------------------------------------------ physics

func _physics_process(delta: float) -> void:
	if track != null:
		var near := track.nearest(global_position)
		track_s = near["s"]
		wrong_way = (not finished) and (-global_transform.basis.z).dot(near["tangent"]) < -0.35
	if locked:
		controls.reset()
	elif driver != null:
		controls = driver.poll(self, delta)
	_read_wheels()
	_apply_drive(delta)
	_apply_steering(delta)
	_apply_ground(delta)
	_prev_velocity = velocity
	move_and_slide()
	_absorb_collisions()
	_update_gearbox(delta)
	_update_effects(delta)
	if visuals != null:
		visuals.update(self, delta)


func _read_wheels() -> void:
	var normal := Vector3.ZERO
	var heights := 0.0
	var hits := 0
	var on_road := 0
	var mu := 1.0
	var offtrack := false
	for ray: RayCast3D in _rays:
		ray.force_raycast_update()
		if not ray.is_colliding():
			continue
		hits += 1
		normal += ray.get_collision_normal()
		heights += ray.get_collision_point().y
		var collider: Object = ray.get_collider()
		if collider is Node:
			var surface := str((collider as Node).get_meta("surface", "road"))
			if surface == "grass":
				mu = minf(mu, 0.62)
				offtrack = true
			else:
				# The kerb and the pit lane are road: what matters for track
				# limits is whether this wheel is on something built for the
				# car, not whether it is on the racing line.
				on_road += 1
	if hits > 0:
		wheels_on_ground = hits
		wheels_on_road = on_road
		surface_mu = mu
		off_track = offtrack
		on_ground = true
		_ground_normal = (normal / float(hits)).normalized()
		if _ground_normal.y < 0.2:
			_ground_normal = Vector3.UP
		_ground_height = heights / float(hits)
	else:
		wheels_on_ground = 0
		wheels_on_road = 0
		on_ground = false


var _ground_normal := Vector3.UP
var _ground_height := 0.0


func _apply_drive(delta: float) -> void:
	var fwd := -global_transform.basis.z
	var right := global_transform.basis.x
	forward_speed = velocity.dot(fwd)
	lateral_speed = velocity.dot(right)

	var c := controls
	if shift_timer > 0.0:
		shift_timer -= delta
		c.throttle *= 0.15

	# Boost: an arcade resource, spent while held and refilled by driving.
	boosting = c.boost and boost_charge > 0.02 and forward_speed > 1.0
	if boosting:
		boost_charge = maxf(0.0, boost_charge - boost_drain * delta)
	elif on_ground:
		boost_charge = minf(1.0, boost_charge + boost_charge_rate * delta)

	# Longitudinal forces, applied in world space along the car's own forward
	# axis. Nothing here moves the velocity to follow the nose: that happens only
	# through grip below, which is what lets the car slide and drift.
	# Damage is spent here, and only here: a damaged car is down on power and
	# down on top speed, which is what makes hitting a tree cost a lap rather
	# than cost a moment. It is not a multiplier on grip - a car that cannot
	# corner after a knock is a car that is undriveable after a knock.
	var health := 1.0 - clampf(damage, 0.0, 1.0) * 0.45
	var ceiling := max_speed * (1.0 - clampf(damage, 0.0, 1.0) * 0.22)
	var accel := 0.0
	if c.throttle > 0.01:
		var headroom := 1.0 - clampf(forward_speed / ceiling, 0.0, 1.0)
		accel += (boost_force if boosting else engine_force) * c.throttle * headroom * health
	if c.brake > 0.01:
		if forward_speed > 0.6:
			accel -= brake_force * c.brake
		else:
			# Past a standstill the brake becomes reverse.
			var reversing := clampf(1.0 - absf(minf(forward_speed, 0.0)) / reverse_max_speed, 0.0, 1.0)
			accel -= engine_force * 0.75 * c.brake * reversing
	if on_ground:
		accel -= drag * forward_speed * absf(forward_speed)
		accel -= signf(forward_speed) * rolling_resistance
	velocity += fwd * accel * delta

	# Lateral grip: a force along the car's right axis that removes sideways
	# velocity, but no faster than the tyres can manage. Under handbrake there is
	# less of it, so the car keeps the slide instead of snapping straight.
	var grip := grip_lateral
	if c.handbrake:
		grip = grip_handbrake
	if off_track:
		grip = minf(grip, grip_offtrack)
	grip *= surface_mu
	var sideways := velocity.dot(right)
	velocity += right * clampf(-sideways, -grip * delta, grip * delta)

	# Read the live components back off the world velocity for the HUD, the AI
	# and the tests.
	forward_speed = velocity.dot(fwd)
	lateral_speed = velocity.dot(right)


func _apply_steering(delta: float) -> void:
	var c := controls
	var target := clampf(c.steer, -1.0, 1.0)
	steer_state = move_toward(steer_state, target, steer_rate * delta)
	steer_state = clampf(steer_state, -1.0, 1.0)

	# Speed-limited lock: the tyres can only generate lateral_accel_limit, so at
	# speed the same steering wheel angle simply cannot be used. This is what
	# produces natural understeer instead of a car that spins at 200 km/h.
	var grip_budget := lateral_accel_limit * surface_mu * (1.0 if on_ground else 0.0)
	var lock := steer_max_rad
	if forward_speed > 1.0:
		var allowed := atan(wheelbase * grip_budget / (forward_speed * forward_speed))
		lock = minf(steer_max_rad, allowed)
	var steer_angle := steer_state * lock
	yaw_rate = 0.0
	if on_ground and absf(forward_speed) > 0.25:
		# Negative: a positive steer input is "turn right", which is a negative
		# rotation about the world up axis. Getting this sign backwards mirrors
		# the player's controls while leaving the AI's own steering self-consistent
		# - a bug that hides until a human sits in the car.
		yaw_rate = -forward_speed / wheelbase * tan(steer_angle)
		# Saved drift: a sliding rear end adds yaw, so a handbrake turn rotates
		# the car rather than just scrubbing speed.
		if c.handbrake:
			yaw_rate += clampf(-lateral_speed * 0.10, -0.9, 0.9)
	if not on_ground:
		yaw_rate *= air_control
	if yaw_rate != 0.0:
		var axis := _ground_normal if on_ground else Vector3.UP
		global_transform.basis = global_transform.basis.rotated(axis, yaw_rate * delta).orthonormalized()


func _apply_ground(delta: float) -> void:
	var fwd := -global_transform.basis.z
	if on_ground:
		# Sit on the surface: follow the average contact height...
		var wanted := _ground_height + ride_height
		global_position.y = lerpf(global_position.y, wanted, clampf(align_rate * delta, 0.0, 1.0))
		# ...and project the velocity onto it. The car's own motion is *not*
		# rebuilt from its heading here: the velocity is the truth, and grip is
		# the only thing that pulls it round.
		velocity = velocity.slide(_ground_normal)
		# Follow the camber and pitch of the road.
		var n := _ground_normal
		var f := fwd.slide(n).normalized()
		if f.length_squared() < 0.01:
			f = fwd
		var r := f.cross(n).normalized()
		var target := Basis(r, n, -f)
		global_transform.basis = global_transform.basis.slerp(
			target, clampf(align_rate * delta, 0.0, 1.0)
		).orthonormalized()
	else:
		velocity.y -= gravity_force * delta
		# Level out slowly in the air so jumps land predictably.
		var flat := global_transform.basis.slerp(
			Basis(Vector3.RIGHT, Vector3.UP, Vector3.BACK), 0.6 * delta
		)
		global_transform.basis = flat.orthonormalized()


func _absorb_collisions() -> void:
	var worst := 0.0
	var point := global_position
	for i in get_slide_collision_count():
		var hit := get_slide_collision(i)
		var closing := absf(_prev_velocity.dot(hit.get_normal()))
		if closing > worst:
			worst = closing
			point = hit.get_position()
	if worst > 3.5:
		last_impact = worst
		# A hard hit costs speed: hitting a barrier should end your corner.
		var loss := clampf((worst - 3.5) * 0.35, 0.0, 14.0)
		var fwd := -global_transform.basis.z
		var along := velocity.dot(fwd)
		velocity -= fwd * clampf(along, -loss, loss) * 0.55
		impacted.emit(worst)
		Sfx.play("impact", clampf(-14.0 + worst, -22.0, -3.0), randf_range(0.85, 1.15))


func _update_gearbox(delta: float) -> void:
	if shift_timer > 0.0:
		shift_timer -= delta
	var speed := absf(forward_speed)
	if forward_speed < -0.5:
		gear = 0  # reverse
		engine_rpm = clampf(speed / reverse_max_speed, 0.12, 0.9)
		return
	var index := 0
	for i in GEAR_TOPS.size():
		if speed > GEAR_TOPS[i] * 0.94 and i < GEAR_TOPS.size() - 1:
			index = i + 1
	gear = index + 1
	var top: float = GEAR_TOPS[gear - 1]
	var low: float = 0.0 if gear == 1 else GEAR_TOPS[gear - 2]
	engine_rpm = clampf(lerpf(0.22, 1.0, (speed - low) / maxf(1.0, top - low)), 0.15, 1.0)
	# Shifting up cuts the torque for a moment - heard, and felt as a pause.
	if gear > 1 and speed > top - 0.5 and shift_timer <= 0.0 and controls.throttle > 0.5:
		shift_timer = SHIFT_TIME


func _update_effects(delta: float) -> void:
	if _engine_player != null and _engine_player.stream != null:
		_engine_player.pitch_scale = clampf(
			lerpf(0.62, 2.45, engine_rpm) * (1.0 + 0.04 * randf_range(-1.0, 1.0)), 0.35, 3.4
		)
		var load := clampf(controls.throttle + 0.15, 0.0, 1.0)
		var db := lerpf(-15.0, -7.0, load) + 3.0 * engine_rpm
		if not is_player:
			db -= 3.0
		_engine_player.volume_db = lerpf(_engine_player.volume_db, db, 0.15)
	if _scrub_player != null and _scrub_player.stream != null:
		var slip := clutter()
		var target := -60.0 if slip < 0.06 else lerpf(-28.0, -11.0, clampf(slip, 0.0, 1.0))
		_scrub_player.volume_db = lerpf(_scrub_player.volume_db, target, 0.25)
		_scrub_player.pitch_scale = 0.9 + 0.6 * clampf(slip, 0.0, 1.0)


# How hard the tyres are sliding, 0..1 - used for sound, smoke and skid marks.
func clutter() -> float:
	var speed := absf(forward_speed)
	if speed < 2.0:
		return 0.0
	return clampf(absf(lateral_speed) / 9.0, 0.0, 1.0)


func speed_kmh() -> float:
	return absf(forward_speed) * 3.6


func is_off_track() -> bool:
	return off_track


# Diagnostic for the self-test: what the ground rays actually see.
func debug_ground_info() -> String:
	var hits := 0
	var lines := PackedStringArray()
	for i in _rays.size():
		var ray := _rays[i]
		var p := ray.global_position
		if ray.is_colliding():
			hits += 1
			var collider: Object = ray.get_collider()
			var name := str((collider as Node).name) if collider is Node else "?"
			lines.append("r%d(%.1f,%.1f,%.1f)->%s@%.2f" % [
				i, p.x, p.y, p.z, name, ray.get_collision_point().y,
			])
		else:
			lines.append("r%d(%.1f,%.1f,%.1f)->MISS" % [i, p.x, p.y, p.z])
	var near := track.nearest(global_position)
	var up := global_transform.basis.y
	return "pos=(%.1f,%.1f,%.1f) lateral=%.2f wheels=%d wb=%.2f r=%.2f up=(%.2f,%.2f,%.2f) target=%s | %s" % [
		global_position.x, global_position.y, global_position.z, near["lateral"],
		wheels_on_ground, wheelbase, wheel_radius, up.x, up.y, up.z,
		str(_rays[0].target_position) if _rays.size() > 0 else "-",
		"  ".join(lines),
	]


func respawn() -> void:
	if track == null:
		return
	var near := track.nearest(global_position)
	var tangent: Vector3 = near["tangent"]
	var pos: Vector3 = near["position"] + Vector3.UP * (ride_height + 0.4)
	global_position = pos
	var up := Vector3.UP
	var right := tangent.cross(up).normalized()
	global_transform.basis = Basis(right, up, -tangent).orthonormalized()
	forward_speed = 0.0
	lateral_speed = 0.0
	velocity = Vector3.ZERO
	steer_state = 0.0
	shift_timer = 0.0
	respawned.emit()
