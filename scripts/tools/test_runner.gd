extends Node
# Headless test suite. Run with:
#   godot --headless --path . scenes/test_runner.tscn
# Exits 0 when every invariant holds, 1 otherwise.
#
# These are invariants, not examples: every joystick reading is shaped, every
# checkpoint order is tried, both circuits are swept for self-intersection, and
# the car is asked to do everything it can do. The self-test in RaceManager
# covers the assembled game; this covers the pieces it is assembled from.

var _failures: Array[String] = []
var _checks := 0
var _section := ""


func _ready() -> void:
	_run()


func _run() -> void:
	await _section_axis_shaping()
	await _section_lap_tracking()
	await _section_track_geometry()
	await _section_barriers()
	await _section_car_direction()
	await _section_car_physics()
	await _section_hud_wiring()
	_section_environment()
	await _section_race_rules()
	_report()


# --------------------------------------------------------------------- helpers

func _start(name: String) -> void:
	_section = name
	print("\n[%s]" % name)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("%s: %s" % [_section, message])
		print("  FAIL  %s" % message)
	else:
		print("  ok    %s" % message)


func _steps(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _controls(steer: float, throttle: float, brake: float, handbrake := false) -> CarControls:
	var c := CarControls.new()
	c.steer = steer
	c.throttle = throttle
	c.brake = brake
	c.handbrake = handbrake
	return c


# --------------------------------------------------- wheel calibration shaping

func _section_axis_shaping() -> void:
	_start("wheel calibration")
	var driver := PlayerDriver.new()

	# A deadzone must produce exactly zero, both sides, and stay symmetric.
	var zero_ok := true
	var x := -0.05
	while x <= 0.05:
		if absf(driver.shape_axis(x, 0.06, false)) > 0.0001:
			zero_ok = false
		x += 0.005
	_expect(zero_ok, "readings inside the deadzone steer by nothing")

	# Full lock must be reachable and never exceeded, for any deadzone.
	var bounds_ok := true
	var monotonic_ok := true
	for deadzone: float in [0.0, 0.04, 0.15, 0.3]:
		var previous := -2.0
		var raw := -1.0
		while raw <= 1.0001:
			var shaped := driver.shape_axis(raw, deadzone, false)
			if absf(shaped) > 1.0001:
				bounds_ok = false
			if shaped < previous - 0.0001:
				monotonic_ok = false
			previous = shaped
			raw += 0.01
		if absf(driver.shape_axis(1.0, deadzone, false) - 1.0) > 0.0001:
			bounds_ok = false
	_expect(bounds_ok, "steering stays within -1..1 and reaches full lock")
	_expect(monotonic_ok, "steering rises monotonically with the wheel")

	# Inverting must mirror exactly, so a backwards pot is a one-checkbox fix.
	var invert_ok := true
	var r := -1.0
	while r <= 1.0:
		if absf(driver.shape_axis(r, 0.08, true) + driver.shape_axis(r, 0.08, false)) > 0.0001:
			invert_ok = false
		r += 0.05
	_expect(invert_ok, "invert mirrors the steering exactly")

	# Pedals: 0..1, never negative, and a released pedal is silence.
	var pedal_ok := true
	for raw2: float in [-1.0, -0.5, 0.0, 0.05, 0.5, 1.0]:
		for deadzone2: float in [0.0, 0.04, 0.2]:
			var value := driver.shape_pedal(raw2, deadzone2, false)
			if value < 0.0 or value > 1.0:
				pedal_ok = false
	_expect(pedal_ok, "pedal shaping stays within 0..1")
	_expect(absf(driver.shape_pedal(0.0, 0.04, false)) < 0.0001, "a released pedal gives no throttle")
	_expect(absf(driver.shape_pedal(1.0, 0.04, false) - 1.0) < 0.0001, "a pressed pedal gives full throttle")


# ------------------------------------------------------------- lap validation

func _track_info(index: int) -> TrackInfo:
	var definition := TrackData.get_track(index)
	var loop := TrackData.sample_loop(TrackData.control_points(definition), 2.0)
	var info := TrackInfo.new()
	info.build_from(loop, float(definition["half_width"]), 2.0, float(definition["start_s"]))
	info.make_checkpoints(int(definition["checkpoints"]), float(definition["start_s"]))
	return info


func _section_lap_tracking() -> void:
	_start("lap validation")
	var info := _track_info(0)
	var tracker := LapTracker.new()
	tracker.setup(info, 3)
	tracker.start(0.0)

	# Driving the centreline for one circuit, at a plausible speed, is one lap.
	# Start *on* the line: the tracker is waiting for the first gate after it.
	var time := 0.0
	# A mutable container: GDScript lambdas capture locals by value, so a plain
	# int counter inside one would never be seen to change.
	var laps := [0]
	tracker.lap_completed.connect(func(_n: int, _t: float) -> void:
		laps[0] += 1)
	tracker.previous_position = info.points[info.start_index]
	for k in range(0, info.count + 1):
		time += info.spacing / 40.0        # 40 m/s
		tracker.update(info, info.points[(info.start_index + k) % info.count], time)
	_expect(laps[0] == 1, "one circuit of the centreline counts exactly one lap (got %d)" % laps[0])
	_expect(absf(tracker.best_lap - time) < 0.05, "the recorded lap time matches the time taken (%.3f vs %.3f)" % [tracker.best_lap, time])
	_expect(tracker.lap == 2, "the lap counter advances to 2")

	# Missing a gate blocks the lap: jump *past* gate 1 beyond the road width, so
	# its plane is never crossed inside it, then drive the rest of the circuit.
	var skipper := LapTracker.new()
	skipper.setup(info, 3)
	skipper.start(0.0)
	var skipped := [0]
	skipper.lap_completed.connect(func(_n: int, _t: float) -> void:
		skipped[0] += 1)
	var t2 := 0.0
	var gate1: int = info.checkpoint_indices[1]
	skipper.previous_position = info.points[info.start_index]
	for k in range(0, info.count + 1):
		t2 += info.spacing / 40.0
		var i := (info.start_index + k) % info.count
		var pos := info.points[i]
		if absf(i - gate1) <= 1 or absf(i - gate1) >= info.count - 1:
			pos += info.rights[gate1] * (info.half_width * 4.0)
		skipper.update(info, pos, t2)
	_expect(skipped[0] == 0, "a car that misses a gate banks no lap (%d)" % skipped[0])

	# Crossing a gate backwards must not count.
	var reverse := LapTracker.new()
	reverse.setup(info, 3)
	reverse.start(0.0)
	var cp_index: int = info.checkpoint_indices[1]
	var approach: Vector3 = info.points[cp_index] - info.flat_tangents[cp_index] * 2.0
	var through: Vector3 = info.points[cp_index] + info.flat_tangents[cp_index] * 0.5
	reverse.previous_position = approach
	reverse.update(info, approach, 0.1)
	var event := reverse.update(info, through, 0.2)
	_expect(event == "checkpoint", "crossing a gate forwards registers")
	var back := reverse.update(info, approach, 0.3)
	_expect(back == "", "crossing the same gate backwards registers nothing")

	# A teleport must not be timed as a lap.
	var jumper := LapTracker.new()
	jumper.setup(info, 3)
	jumper.start(0.0)
	var fake := [0]
	jumper.lap_completed.connect(func(_n: int, _t: float) -> void:
		fake[0] += 1)
	jumper.previous_position = info.points[info.start_index]
	for k in range(0, info.count + 1):
		jumper.update(info, info.points[(info.start_index + k) % info.count], 0.001 * float(k))   # 0.76 s "lap"
	_expect(fake[0] == 0, "an impossibly fast lap is discarded rather than recorded (%d)" % fake[0])


# --------------------------------------------------------------- track shape

func _section_track_geometry() -> void:
	_start("track geometry")
	for index in TrackData.track_count():
		var definition := TrackData.get_track(index)
		var name := str(definition["name"])
		var half_width := float(definition["half_width"])
		var info := _track_info(index)

		# Even spacing keeps "distance along the lap" linear, which the AI's
		# look-ahead and every lap-time measurement depend on.
		var worst := 0.0
		for i in info.count:
			worst = maxf(worst, absf(info.points[i].distance_to(info.points[(i + 1) % info.count]) - info.spacing))
		_expect(worst < 0.05, "%s: samples are evenly spaced (worst error %.3f m)" % [name, worst])

		# Self-intersection: no two parts of the circuit may come within the road
		# plus its walls. This is the invariant that the first layout broke, and
		# it broke the game rather than merely looking wrong.
		var clearance := 2.0 * (half_width + 1.0 + 1.6) + 2.0
		var closest := INF
		var closest_pair := Vector2i.ZERO
		for i in info.count:
			for j in range(i + 1, info.count):
				var separated := minf(float(j - i), float(info.count - (j - i))) * info.spacing
				if separated < 60.0:
					continue
				var d := info.points[i].distance_to(info.points[j])
				if d < closest:
					closest = d
					closest_pair = Vector2i(i, j)
		_expect(closest >= clearance,
			"%s: no pinch points (closest approach %.1f m, needs %.1f; samples %d/%d)" % [
				name, closest, clearance, closest_pair.x, closest_pair.y])

		# Drivable gradient and corner radius.
		var max_slope := 0.0
		for i in info.count:
			max_slope = maxf(max_slope, absf(info.points[i].y - info.points[(i + 1) % info.count].y) / info.spacing)
		_expect(max_slope < 0.22, "%s: gradient stays under 12.4 degrees (max %.3f)" % [name, max_slope])

		var tightest := INF
		for i in info.count:
			var k := absf(info.curvature[i])
			if k > 0.00001:
				tightest = minf(tightest, 1.0 / k)
		_expect(tightest > 15.0, "%s: tightest corner radius is %.1f m" % [name, tightest])

		# The loop must close and the gates must be spread around it.
		_expect(info.checkpoint_indices.size() == int(definition["checkpoints"]),
			"%s: %d gates placed" % [name, info.checkpoint_indices.size()])
		_expect(info.length > 600.0, "%s: lap is %.0f m" % [name, info.length])
		_expect(info.points[info.start_index].distance_to(info.points[0]) < 200.0,
			"%s: the start line sits on the opening straight" % name)


# --------------------------------------------------------------- barrier walls

func _section_barriers() -> void:
	_start("barrier walls")
	var world := Node3D.new()
	world.name = "BarrierWorld"
	add_child(world)
	var builder := TrackBuilder.new()
	world.add_child(builder)
	builder.build(TrackData.get_track(0))
	var info := builder.info
	var face := builder.wall_face_lateral()

	# A car fired at a barrier with the power on must be stopped by it, on both
	# sides, at both tick rates the game runs at. The barrier is generated, so it
	# is the only thing between a huge slide and a car parked in the scenery.
	for rate: int in [60, 240]:
		Engine.physics_ticks_per_second = rate
		var fastest := 0.0
		for side: float in [-1.0, 1.0]:
			var which := "right" if side > 0.0 else "left"
			var sample := info.point_at(200.0)
			var right: Vector3 = sample["right"]
			var heading := right * side
			var car := Car.new()
			world.add_child(car)
			car.track = info
			car.global_transform = Transform3D(
				Basis.looking_at(heading, Vector3.UP),
				(sample["position"] as Vector3) + Vector3.UP * 0.5
			)
			car.velocity = heading * 62.0        # flat out: the fastest the car can hit it
			await _steps(2)
			var half_length := car.body_size.z * 0.96 * 0.5
			car.controls = _controls(0.0, 1.0, 0.0)
			var deepest := 0.0
			for i in rate:
				await get_tree().physics_frame
				var lat: float = absf(info.nearest(car.global_position)["lateral"])
				deepest = maxf(deepest, lat + half_length)
			fastest = maxf(fastest, deepest)
			print("  %d Hz, %s barrier: nose reached %.2f m, face at %.2f m, %s" % [
				rate, which, deepest, face,
				"stopped" if deepest <= face + 0.05 else "THROUGH IT",
			])
			car.queue_free()
			await _steps(2)
		_expect(fastest <= face + 0.05,
			"at %d Hz a car fired flat out at the barrier is stopped by it (nose %.2f, wall %.2f)" % [
				rate, fastest, face,
			])

	Engine.physics_ticks_per_second = 60
	world.queue_free()


# ------------------------------------------------------- reading the car

func _section_car_direction() -> void:
	_start("reading the car's direction")
	var world := Node3D.new()
	world.name = "DirectionWorld"
	add_child(world)
	var car := Car.new()
	world.add_child(car)
	car.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.5, 0))
	await _steps(2)

	# The body exposes the wheels and the two wings, so the test can ask the art
	# the same question a player does: which end is the front?
	var body: F1Body = car.body
	_expect(body != null, "the car has a body to read")
	if body == null:
		world.queue_free()
		return

	var forward := -car.global_transform.basis.z
	var nose := body.to_global(Vector3(0.0, 0.0, body.nose_z()))
	var tail := body.to_global(Vector3(0.0, 0.0, body.tail_z()))
	_expect((nose - car.global_position).dot(forward) > 1.0,
		"the nose points the way the car drives (%.2f m ahead)" % [
			(nose - car.global_position).dot(forward),
		])
	_expect((tail - car.global_position).dot(forward) < -1.0,
		"and the tail points the other way (%.2f m behind)" % [
			(tail - car.global_position).dot(forward),
		])

	# Front and rear have to be different shapes, or the direction is only knowable
	# from the physics. A wide, low front wing and a narrow, high rear wing is what
	# an F1 car is, and it is what makes the silhouette readable.
	var front: AABB = body.wing_box("front_wing")
	var rear: AABB = body.wing_box("rear_wing")
	_expect(front.size.x > rear.size.x * 1.4,
		"the front wing is much wider than the rear (%.2f vs %.2f m)" % [front.size.x, rear.size.x])
	var front_top := front.position.y + front.size.y
	var rear_top := rear.position.y + rear.size.y
	_expect(rear_top > front_top + 0.5,
		"the rear wing is much higher than the front (%.2f vs %.2f m)" % [rear_top, front_top])

	# The wings bracket the car: ahead of the front axle, behind the rear one. That
	# is what stops the whole body being built mirrored, which would put the nose
	# where the diffuser is while every measurement still looked sane.
	var front_axle: float = (body.wheel_nodes[0].position.z + body.wheel_nodes[1].position.z) * 0.5
	var rear_axle: float = (body.wheel_nodes[2].position.z + body.wheel_nodes[3].position.z) * 0.5
	_expect(body.nose_z() < front_axle, "the front wing is ahead of the front axle")
	_expect(body.tail_z() > rear_axle, "the rear wing is behind the rear axle")

	# Steering and skid marks are driven from wheel order, so the first pair has to
	# be the pair nearest the nose.
	_expect(absf(body.wheel_nodes[0].position.z - front_axle) < 0.01
			and absf(body.wheel_nodes[3].position.z - rear_axle) < 0.01,
		"the wheel nodes are ordered front pair first")
	_expect(body.wheel_nodes[0].position.distance_to(Vector3(0.0, 0.0, body.nose_z()))
			< body.wheel_nodes[2].position.distance_to(Vector3(0.0, 0.0, body.nose_z())),
		"and the front pair is the pair nearer the nose")
	_expect(body.wheel_nodes[0].position.x < 0.0 and body.wheel_nodes[2].position.x < 0.0
			and body.wheel_nodes[1].position.x > 0.0 and body.wheel_nodes[3].position.x > 0.0,
		"with left on one side and right on the other")

	# Nothing may hang below the tyres, or the car is lifted off them to clear the
	# road and the wheels float.
	_expect(body.bounds.position.y > -0.005,
		"the tyres are the lowest part of the car (lowest %.3f m)" % body.bounds.position.y)
	_expect(body.bounds.size.z > 4.2 and body.bounds.size.z < 5.4,
		"the car is Formula One length (%.2f m)" % body.bounds.size.z)
	_expect(body.bounds.size.x > 1.7 and body.bounds.size.x < 2.3,
		"and Formula One width (%.2f m)" % body.bounds.size.x)

	world.queue_free()


# ------------------------------------------------------------------ car physics

func _section_car_physics() -> void:
	_start("car physics")
	Engine.physics_ticks_per_second = 240
	Engine.time_scale = 4.0

	var world := Node3D.new()
	world.name = "PhysicsWorld"
	add_child(world)

	# A long flat road with a collider, tagged the way the track tags its own.
	var ground := StaticBody3D.new()
	ground.set_meta("surface", "road")
	var ground_shape := BoxShape3D.new()
	ground_shape.size = Vector3(600.0, 4.0, 6000.0)
	var ground_collider := CollisionShape3D.new()
	ground_collider.shape = ground_shape
	ground_collider.position = Vector3(0, -2.0, -2000.0)
	ground.add_child(ground_collider)
	world.add_child(ground)

	var straight := PackedVector3Array()
	for i in 600:
		straight.append(Vector3(0, 0, -float(i) * 2.0))
	var info := TrackInfo.new()
	info.build_from(straight, 6.0, 2.0, 10.0)
	info.make_checkpoints(8, 10.0)

	var car := Car.new()
	car.is_player = true
	world.add_child(car)
	car.track = info
	car.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.4, 0))

	await _steps(30)   # settle onto the road

	_expect(car.wheels_on_ground == 4, "all four wheels find the ground (%d of 4)" % car.wheels_on_ground)
	# The measurements have to agree with the body they were taken off: this is the
	# check that the car driving is the car that is drawn.
	var design_wheelbase := F1Body.REAR_AXLE_Z - F1Body.FRONT_AXLE_Z
	_expect(absf(car.wheelbase - design_wheelbase) < 0.02,
		"the measured wheelbase matches the body (%.2f vs %.2f m)" % [car.wheelbase, design_wheelbase])
	_expect(absf(car.wheel_radius - F1Body.TYRE_RADIUS) < 0.01,
		"the measured wheel radius matches the body (%.3f vs %.3f m)" % [
			car.wheel_radius, F1Body.TYRE_RADIUS,
		])
	_expect(absf(car.track_width - F1Body.FRONT_TRACK) < 0.02,
		"the measured track matches the body (%.2f vs %.2f m)" % [car.track_width, F1Body.FRONT_TRACK])

	# Throttle accelerates; the gearbox climbs with it.
	car.controls = _controls(0.0, 1.0, 0.0)
	await _steps(120)
	var after_throttle := car.forward_speed
	_expect(after_throttle > 8.0, "throttle accelerates (%.1f m/s after 2 s)" % after_throttle)
	_expect(car.gear >= 2, "the gearbox climbed to gear %d" % car.gear)
	_expect(car.speed_kmh() > 30.0, "speed reads %0.0f km/h" % car.speed_kmh())

	# Braking slows it hard.
	car.controls = _controls(0.0, 0.0, 1.0)
	await _steps(60)
	_expect(car.forward_speed < after_throttle - 6.0,
		"braking removes speed (%.1f -> %.1f m/s)" % [after_throttle, car.forward_speed])

	# Steering right turns right about the world up axis.
	car.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.4, -200.0))
	car.velocity = Vector3.ZERO
	await _steps(10)
	car.controls = _controls(0.0, 1.0, 0.0)
	await _steps(90)
	var heading_before := -car.global_transform.basis.z
	car.controls = _controls(1.0, 0.6, 0.0)
	await _steps(45)
	var heading_after := -car.global_transform.basis.z
	_expect(heading_after.x > heading_before.x + 0.05,
		"steering right turns the car right (x %.2f -> %.2f)" % [heading_before.x, heading_after.x])

	# The handbrake makes it slide: sideways speed with it, none without.
	var slip_handbrake := await _slip_with(0.6, -260.0, true)
	var slip_grip := await _slip_with(0.6, -260.0, false)
	_expect(slip_handbrake > slip_grip + 0.15,
		"the handbrake breaks traction (slip %.2f vs %.2f m/s)" % [slip_handbrake, slip_grip])

	# Reverse.
	car.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.4, -300.0))
	car.velocity = Vector3.ZERO
	car.forward_speed = 0.0
	await _steps(20)
	car.controls = _controls(0.0, 0.0, 1.0)
	await _steps(150)
	_expect(car.forward_speed < -1.5, "braking from rest reverses (%.1f m/s)" % car.forward_speed)
	_expect(car.gear == 0, "the HUD shows reverse")

	# Top speed is bounded, and reachable.
	car.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.4, -600.0))
	car.velocity = Vector3.ZERO
	await _steps(10)
	car.controls = _controls(0.0, 1.0, 0.0)
	await _steps(1400)      # ~23 s
	_expect(car.forward_speed <= car.max_speed * 1.05,
		"speed is bounded by max_speed (%.1f of %.1f m/s)" % [car.forward_speed, car.max_speed])
	_expect(car.forward_speed > 35.0, "and it actually gets there (%.1f m/s)" % car.forward_speed)

	# Nothing explodes under abuse.
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for i in 900:
		car.controls = _controls(rng.randf_range(-1.0, 1.0), rng.randf(), rng.randf() * 0.5, rng.randf() < 0.15)
		await get_tree().physics_frame
	var finite := is_finite(car.global_position.x) and is_finite(car.global_position.y) \
		and is_finite(car.global_position.z) and is_finite(car.forward_speed) \
		and is_finite(car.lateral_speed)
	_expect(finite, "15 s of random abuse leaves no NaN anywhere")
	_expect(car.global_position.y > -50.0, "and the car is still on the road (y %.1f)" % car.global_position.y)

	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	world.queue_free()


func _slip_with(steer: float, z: float, handbrake: bool) -> float:
	var car: Car = null
	for child in get_children():
		if child.name == "PhysicsWorld":
			for c in child.get_children():
				if c is Car:
					car = c
	if car == null:
		return 0.0
	car.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.4, z))
	car.velocity = Vector3(0, 0, -18.0)
	car.forward_speed = 18.0
	car.lateral_speed = 0.0
	await _steps(4)
	var peak := 0.0
	car.controls = _controls(steer, 0.4, 0.0, handbrake)
	for i in 40:
		peak = maxf(peak, absf(car.lateral_speed))
		await get_tree().physics_frame
	return peak


# ------------------------------------------------------------------ the HUD

func _section_hud_wiring() -> void:
	_start("hud wiring")
	# The minimap draws the circuit it is handed, and it is handed one only if the
	# HUD passes the TrackInfo on. That is the sort of wiring that can go missing
	# without anything failing: a map that gets the cars but not the circuit draws
	# nothing at all, and a HUD with a blank corner looks like a design choice
	# rather than a bug. So this builds a real race, lets the HUD update, and asks
	# the map what it actually received.
	var race := RaceManager.new()
	add_child(race)
	await _steps(6)

	var hud: RaceHUD = race.hud
	_expect(hud != null, "the race builds a HUD")
	if hud == null:
		race.queue_free()
		return
	var map: MiniMap = hud._map
	_expect(map != null, "and the HUD has a minimap")
	if map != null:
		_expect(map.info != null, "the minimap is handed the circuit to draw")
		_expect(map.cars.size() == race.cars.size() and map.cars.size() > 0,
			"and every car to plot on it (%d cars)" % map.cars.size())
		_expect(map.player != null and map.player.is_player,
			"and can tell which of them is the player")
		_expect(map.info != null and map.info.length > 600.0,
			"and that circuit is a whole lap (%0.0f m)" % (map.info.length if map.info != null else 0.0))
	race.queue_free()
	await _steps(2)


# -------------------------------------------------------------------- summary

func _report() -> void:
	print("\n%d checks, %d failed" % [_checks, _failures.size()])
	for f: String in _failures:
		print("  FAILED: %s" % f)
	print("TESTS=%s" % ("PASS" if _failures.is_empty() else "FAIL"))
	get_tree().quit(0 if _failures.is_empty() else 1)


# ----------------------------------------------------------- the environment

# The air a circuit is raced in, read back off the Environment the race builds.
#
# This section exists because of a bug that cost a whole afternoon and that no
# other check in this project could have seen. Godot's Environment resets
# `fog_density` to 1.0 when `fog_mode` is assigned - even when it is assigned
# the value it already holds - and a density of 1.0 is a wall of haze ten
# metres down the road with the entire circuit behind it. Every headless test
# passed, the self-test drove a clean lap, and the game was unplayable.
#
# So the numbers the circuits ask for are asserted against the numbers the
# Environment ends up carrying. Anything that quietly overwrites one is caught
# the moment it is added.
func _section_environment() -> void:
	_start("environment")
	for index in TrackData.track_count():
		var definition := TrackData.get_track(index)
		var name := str(definition["name"])
		var env := RaceManager.build_environment(definition)
		var wanted := float(definition.get("fog_density", 0.0007))
		_expect(is_equal_approx(env.fog_density, wanted),
			"%s gets the fog density it asked for (%.5f)" % [name, env.fog_density])
		# Belt and braces: whatever the circuit asked for, a density this side
		# of a thousandth is the difference between haze and a painted wall.
		_expect(env.fog_density < 0.01,
			"%s can see further than the end of its own bonnet (%.5f)"
				% [name, env.fog_density])
		_expect(env.fog_mode == Environment.FOG_MODE_EXPONENTIAL,
			"%s fogs by density rather than over a fixed 10-100 m range" % name)
		var panorama := str(definition.get("sky", ""))
		var sky := env.sky
		if panorama == "":
			_expect(sky != null and sky.sky_material is ProceduralSkyMaterial,
				"%s falls back to the procedural gradient" % name)
		else:
			_expect(ResourceLoader.exists(panorama),
				"%s ships the sky it names (%s)" % [name, panorama])
			_expect(sky != null and sky.sky_material is PanoramaSkyMaterial,
				"%s is lit by its own drawn sky" % name)


# ------------------------------------------------------------- the race rules

# Race control, driven directly. The rules are pure logic over public state on
# the car, which is deliberate: it means they can be tested by putting a car in
# a state and stepping them, without a circuit, a renderer or a six-minute lap.
func _section_race_rules() -> void:
	_start("race rules")
	var car := Car.new()
	add_child(car)
	car.driver_name = "Tester"
	car.locked = true
	await get_tree().physics_frame

	# --- the start ---------------------------------------------------------
	var rules := RaceRules.new()
	rules.watch(car)
	rules.step(0.1, false)
	var book: RaceRules.Record = rules.record(car)
	_expect(book.penalty == 0.0, "sitting still on the grid costs nothing")

	car.global_position += Vector3(0, 0, -RaceRules.JUMP_DISTANCE - 0.5)
	rules.step(0.1, false)
	_expect(is_equal_approx(book.penalty, RaceRules.JUMP_PENALTY),
		"creeping before the lights go out is a jump start (+%.0fs)" % book.penalty)
	rules.step(0.1, false)
	_expect(is_equal_approx(book.penalty, RaceRules.JUMP_PENALTY),
		"and it is only booked once")

	# --- track limits ------------------------------------------------------
	rules = RaceRules.new()
	rules.watch(car)
	rules.start()
	book = rules.record(car)
	car.on_ground = true
	car.wheels_on_ground = 4
	car.wheels_on_road = 4
	for i in 20:
		rules.step(0.1, true)
	_expect(book.limits_total == 0, "four wheels on the road is not an offence")

	# Three excursions. Two are free, the third costs.
	for excursion in 3:
		car.wheels_on_road = 0
		for i in 12:
			rules.step(0.1, true)
		car.wheels_on_road = 4
		for i in 16:
			rules.step(0.1, true)
	_expect(book.limits_total == 3,
		"every excursion is counted (%d)" % book.limits_total)
	_expect(is_equal_approx(book.penalty, RaceRules.LIMITS_PENALTY),
		"%d a lap are free and the next one costs +%.0fs"
			% [RaceRules.LIMITS_FREE, book.penalty])

	# A lap wipes the slate: the free excursions come back.
	rules.on_lap(car)
	_expect(book.limits_offences == 0, "a new lap restores the free excursions")

	# A brush with the grass, shorter than the grace period, is not an offence.
	var before := book.limits_total
	car.wheels_on_road = 0
	rules.step(RaceRules.LIMITS_GRACE * 0.5, true)
	car.wheels_on_road = 4
	rules.step(0.1, true)
	_expect(book.limits_total == before,
		"a moment with the wheels off the road is not an offence")

	# --- contact -----------------------------------------------------------
	rules = RaceRules.new()
	rules.watch(car)
	rules.start()
	book = rules.record(car)
	car.impacted.emit(RaceRules.CONTACT_FLOOR - 1.0)
	_expect(book.damage == 0.0, "a brush does no damage")
	car.impacted.emit(RaceRules.CONTACT_HEAVY)
	_expect(book.damage > 0.4 and car.damage == book.damage,
		"a heavy shunt damages the car (%.0f%%)" % [book.damage * 100.0])
	_expect(book.penalty == 0.0,
		"and costs no time penalty - the time is lost in the wreck")
	var hurt := book.damage
	car.wheels_on_road = 4
	car.velocity = Vector3(0, 0, -30.0)
	car.forward_speed = 30.0
	rules.step(1.0, true)
	_expect(book.damage < hurt and book.damage > 0.0,
		"driving on nurses the damage back, slowly (%.0f%% -> %.0f%%)"
			% [hurt * 100.0, book.damage * 100.0])
	rules.on_reset(car)
	_expect(book.damage == 0.0 and car.damage == 0.0,
		"and a reset repairs it outright")

	# Damage is spent as performance, which is the whole point of it.
	var clean: float = await _throttle_for(0.0, 2.0)
	var broken: float = await _throttle_for(1.0, 2.0)
	_expect(broken < clean * 0.95,
		"a damaged car is slower (%.1f vs %.1f m/s after 2 s)" % [broken, clean])

	# --- wrong way ---------------------------------------------------------
	rules = RaceRules.new()
	rules.watch(car)
	rules.start()
	book = rules.record(car)
	car.wrong_way = true
	car.forward_speed = 20.0
	car.velocity = Vector3(0, 0, -20.0)
	for i in int(RaceRules.WRONG_WAY_DQ / 0.25) + 2:
		rules.step(0.25, true)
	_expect(book.disqualified,
		"driving against the circuit for %ds ends the race" % int(RaceRules.WRONG_WAY_DQ))
	car.wrong_way = false

	# --- disqualification by penalties -------------------------------------
	rules = RaceRules.new()
	rules.watch(car)
	rules.start()
	book = rules.record(car)
	car.on_ground = true
	car.wheels_on_ground = 4
	var guard := 0
	while not book.disqualified and guard < 200:
		guard += 1
		car.wheels_on_road = 0
		for i in 12:
			rules.step(0.1, true)
		car.wheels_on_road = 4
		for i in 16:
			rules.step(0.1, true)
	_expect(book.disqualified and book.penalty >= RaceRules.DQ_PENALTY_SECONDS,
		"enough penalties end the race (+%.0fs)" % book.penalty)
	_expect(not rules.summary().is_empty(),
		"and race control can say what it did (%d rulings)" % rules.summary().size())

	car.queue_free()


# How fast a car gets in `seconds` from rest at a given damage level, on a flat
# road it can actually get grip from. Used to assert that damage is spent as
# performance rather than merely recorded: a number on a car that drives the
# same as it did before is not a consequence.
func _throttle_for(damage: float, seconds: float) -> float:
	var world := Node3D.new()
	add_child(world)
	var ground := StaticBody3D.new()
	ground.set_meta("surface", "road")
	var shape := BoxShape3D.new()
	shape.size = Vector3(200.0, 4.0, 4000.0)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = Vector3(0, -2.0, -1500.0)
	ground.add_child(collider)
	world.add_child(ground)

	var car := Car.new()
	world.add_child(car)
	car.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.4, 0))
	await _steps(30)
	car.damage = damage
	car.locked = false
	var steps := int(seconds * Engine.physics_ticks_per_second)
	for i in steps:
		car.controls = _controls(0.0, 1.0, 0.0)
		await get_tree().physics_frame
	var speed := car.forward_speed
	world.queue_free()
	return speed
