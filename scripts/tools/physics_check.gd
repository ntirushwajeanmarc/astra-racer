extends Node
# Asserts that the world a car meets is the world a player sees.
#
# Three things were wrong with Kigali and none of them were visible to any test
# that already existed, because every one of those tests either ran without a
# renderer or looked at geometry without driving into it:
#
#   * the ground you could see and the ground you landed on were different
#     surfaces. The terrain model was scenery, and the collision off the road
#     was a generated verge that ran from the road edge down to one flat height
#     for the whole circuit. Leaving the tarmac put the car underneath the
#     hillside it was looking at;
#   * the hillside cut through the racing line. The road's height came from the
#     GPX and the ground's from SRTM, and the two disagreed by up to ten metres
#     over half the lap;
#   * buildings could be driven through.
#
# So this drives. It drops cars, pushes them off the road and rams them into
# walls, and asserts what happens to them - which is the only kind of evidence
# that would have caught any of it.
#
#   godot --headless --path racer scenes/physics_check.tscn -- --track=2

const DROP_HEIGHT := 400.0


# A driver that always says the same thing. Car polls a driver rather than being
# handed controls, and the AI would steer away from the very things this test
# exists to drive into, so the test brings its own.
class FixedDriver extends RefCounted:
	var controls := CarControls.new()

	func _init(throttle: float) -> void:
		controls.throttle = throttle

	func poll(_car, _delta) -> CarControls:
		return controls


# And a driver that stays on the road without being an AI. The AI brakes,
# lifts and takes a line; this holds the throttle down and aims at the
# centreline, which is what a test that wants the car over as much ground as
# possible in as few frames as possible wants.
class CentreLineDriver extends RefCounted:
	var controls := CarControls.new()
	var info: TrackInfo

	func _init(track: TrackInfo) -> void:
		info = track
		controls.throttle = 1.0

	func poll(car, _delta) -> CarControls:
		var here: Dictionary = info.nearest(car.global_position)
		var aim: Vector3 = info.points[info.index_at(float(here["s"]) + 28.0)]
		var to: Vector3 = (aim - car.global_position).normalized()
		var right: Vector3 = car.global_transform.basis.x
		controls.steer = clampf(to.dot(right) * 3.0, -1.0, 1.0)
		return controls

var _failures: Array[String] = []
var _checks := 0
var _builder: TrackBuilder
var _world: Node3D


func _ready() -> void:
	var track := 2
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--track="):
			track = int(arg.split("=")[1])

	Engine.physics_ticks_per_second = 120
	_world = Node3D.new()
	_world.name = "World"
	add_child(_world)
	_builder = TrackBuilder.new()
	_builder.name = "Track"
	_world.add_child(_builder)
	_builder.build(TrackData.get_track(track))
	var definition := TrackData.get_track(track)
	print("[physics] %s - %.0f m lap" % [definition["name"], _builder.info.length])
	await _steps(4)

	_check_no_phantom_verge(definition)
	_check_every_body_is_on_a_layer_that_works()
	await _check_the_chassis_stays_out_of_the_ground()
	_check_the_ground_rays_see_only_ground()
	_check_the_car_still_hits_what_the_rays_ignore()
	await _check_ground_everywhere()
	await _check_ground_under_road()
	await _check_car_lands_on_what_it_sees()
	_check_the_barrier_is_not_buried()
	_check_nothing_stands_on_the_circuit()
	await _check_walls_stop_a_car()
	await _check_trees_stop_a_car()
	await _check_buildings_stop_a_car()

	print("\n%d/%d checks hold" % [_checks - _failures.size(), _checks])
	for f: String in _failures:
		print("  FAILED: %s" % f)
	print("PHYSICS_CHECK=" + ("PASS" if _failures.is_empty() else "FAIL"))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  ok    %s" % label)
	else:
		_failures.append(label)


func _steps(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


# ------------------------------------------------------------------ the ground

func _check_no_phantom_verge(definition: Dictionary) -> void:
	# The generated verge is the surface that used to be underneath everything.
	# On a circuit with real ground it must not exist at all: an invisible slope
	# lying over a visible hillside is the whole bug, and a test that only asked
	# whether the car landed on *something* passed the entire time it was there.
	var verge := _builder.get_node_or_null("Verge")
	if definition.has("terrain"):
		_expect(verge == null,
			"the generated verge is gone where there is real ground to stand on")
		_expect(_builder.terrain_bodies > 0,
			"the terrain carries collision (%d bodies)" % _builder.terrain_bodies)
	else:
		_expect(verge != null, "a circuit with no terrain still has its verge")


# What is under a point. A single ray, then a few centimetres either side if it
# found nothing.
#
# The retry is not a fudge, it is the difference between measuring the ground and
# measuring one infinitely thin line through it. A ray aimed exactly along the
# shared edge of two triangles can pass between them - on the Alpine verge there
# is precisely one sample in two hundred where it does, with solid ground three
# centimetres either side of it. A car has four wheels and a body and cannot fall
# through a seam with no width, so a test that reports one as a hole in the world
# is reporting on its own arithmetic.
func _ground_under(point: Vector3, from_above: float = DROP_HEIGHT) -> Dictionary:
	var space := _world.get_world_3d().direct_space_state
	for nudge: Vector3 in [Vector3.ZERO, Vector3(0.03, 0.0, 0.0),
			Vector3(0.0, 0.0, 0.03), Vector3(-0.03, 0.0, -0.03)]:
		var from := point + nudge + Vector3.UP * from_above
		var to := point + nudge - Vector3.UP * from_above
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
		if hit.has("collider"):
			return hit
	return {}


func _check_ground_everywhere() -> void:
	# Every place a car can reach has to have something under it. Sampled around
	# the lap and out to either side, because "the road has collision" was always
	# true and was never the question.
	var misses := 0
	var tested := 0
	var skipped := 0
	var step := maxf(40.0, _builder.info.length / 180.0)
	var s := 0.0
	while s < _builder.info.length:
		var i := _builder.info.index_at(s)
		# How far sideways it is meaningful to ask. Offsetting along the normal
		# of a 31 m corner by 90 m does not land beside the track, it lands past
		# the centre of the corner and out the other side - a point that is not
		# next to the circuit at all, and whose ground nobody can reach.
		var curvature := absf(_builder.info.curvature[i])
		var reach := 1.0e9 if curvature < 1.0e-5 else 0.6 / curvature
		for lateral: float in [-90.0, -40.0, -12.0, 0.0, 12.0, 40.0, 90.0]:
			if absf(lateral) > reach:
				skipped += 1
				continue
			var t := _builder.get_transform_at(s, lateral)
			tested += 1
			if not _ground_under(t.origin).has("collider"):
				misses += 1
		s += step
	_expect(misses == 0,
		"there is ground under every point near the lap (%d of %d found, %d too far round a corner to ask)"
			% [tested - misses, tested, skipped])


func _check_ground_under_road() -> void:
	# The hillside must not come up through the tarmac. This is the carve, and
	# it is measured the way a player meets it: cast down and see what answers
	# first.
	#
	# **Across the road, not down the middle of it.** This used to sample the
	# racing line alone, and the racing line is the one place the carve is
	# guaranteed to be right - the terrain build settles the ground under
	# exactly those points. It passed four hundred times out of four hundred
	# while the ground rose through the tarmac five metres from the centre for
	# six hundred and fifty metres of the Kigali lap, which is an earth ramp at
	# the road's own edge that a car drives up and into the barrier. A check
	# that only looks where the fix was applied is not a check.
	var through := 0
	var worst := 0.0
	var worst_at := 0.0
	var worst_lateral := 0.0
	var tested := 0
	var step := maxf(10.0, _builder.info.length / 900.0)
	# Out to where a car can still be: the barrier's face, less half a car. A
	# ray cast at the face itself comes down on top of the barrier, which is
	# solid, is not the road, and is deliberately taller than the road - so the
	# check would be measuring the thing that is supposed to be there.
	var edge := _builder.wall_face_lateral() - 1.1
	var s := 0.0
	while s < _builder.info.length:
		for lateral: float in [-edge, -4.5, -2.5, 0.0, 2.5, 4.5, edge]:
			var t := _builder.get_transform_at(s, lateral)
			var hit := _ground_under(t.origin)
			if not hit.has("collider"):
				continue
			tested += 1
			var body: Node = hit["collider"]
			var surface := str(body.get_meta("surface", "road"))
			if surface == "road":
				continue
			# Walls, buildings and tree trunks are meant to stand above the
			# road. What this is looking for is *ground* standing above it.
			if surface != "grass":
				continue
			# Something that is not the road answered first, which means the
			# ground is standing above the road surface here. Out at the
			# barrier line that is the verge, which is allowed to be a little
			# proud of the tarmac; on the road itself nothing is.
			var above: float = (hit["position"] as Vector3).y - t.origin.y
			var allowed := 0.35 if absf(lateral) > _builder.info.half_width else 0.0
			if above <= allowed:
				continue
			through += 1
			if above > worst:
				worst = above
				worst_at = s
				worst_lateral = lateral
		s += step
	_expect(through == 0,
		"the road is the first thing under every point across it (%d of %d, worst %.2f m of ground above it at %.0f m, lateral %+.1f)"
			% [tested - through, tested, worst, worst_at, worst_lateral])


func _check_car_lands_on_what_it_sees() -> void:
	# Drop a car onto the grass beside the track and let it settle. It has to
	# come to rest on the surface a ray finds - that is what "the ground you see
	# is the ground you land on" means once there is a car involved.
	var worst := 0.0
	var landed := 0
	var tested := 0
	var step := maxf(400.0, _builder.info.length / 12.0)
	var s := 0.0
	while s < _builder.info.length:
		var spot := _builder.get_transform_at(s, 26.0).origin
		var hit := _ground_under(spot)
		if not hit.has("collider"):
			s += step
			continue
		tested += 1
		var surface_y := (hit["position"] as Vector3).y
		var car := Car.new()
		_world.add_child(car)
		car.global_transform = Transform3D(Basis.IDENTITY,
			Vector3(spot.x, surface_y + 3.0, spot.z))
		car.track = _builder.info
		car.locked = false
		await _steps(180)
		var resting := car.global_position.y
		var gap := absf(resting - surface_y)
		if gap < 2.0:
			landed += 1
		worst = maxf(worst, gap)
		car.queue_free()
		s += step
	_expect(tested > 0 and landed == tested,
		"a car dropped on the grass settles on the ground it can see (%d of %d, worst gap %.2f m)"
			% [landed, tested, worst])


# The car's own collider, against the ground it is driving over.
#
# Ride height, pitch and what the car is standing on all come from the four
# wheel rays; the box collider is there for walls, buildings and the other
# cars. Those two jobs are only separate if the box is *above* the ground,
# and it was not - its underside was the tyre contact plane, so on a hill it
# was an axis-aligned slab held level with a sloping surface and its leading
# edge was buried in it. `move_and_slide` then shoved the car every frame
# while `_apply_ground` put it back.
#
# Nothing already here would have noticed. The ground checks cast rays, which
# find the same surface either way, and the self-test asserts lap times and
# that nobody ended up in a NaN - a car being kicked a few centimetres upwards
# eight times a second finishes the lap. So this drives a lap and watches the
# collisions the car itself reports.
func _check_the_chassis_stays_out_of_the_ground() -> void:
	var car := Car.new()
	_world.add_child(car)
	car.global_transform = _builder.start_transform
	car.track = _builder.info
	car.driver = CentreLineDriver.new(_builder.info)
	car.locked = false
	await get_tree().physics_frame

	var frames := 0
	var touches := 0
	var deepest := 0.0
	var where := 0.0
	for i in 2400:
		await get_tree().physics_frame
		frames += 1
		for k in car.get_slide_collision_count():
			var hit := car.get_slide_collision(k)
			# An upward-facing normal is the ground: a wall or another car
			# answers from the side.
			if hit.get_normal().y < 0.7:
				continue
			touches += 1
			if hit.get_depth() > deepest:
				deepest = hit.get_depth()
				where = car.track_s
	var reached := car.track_s
	car.queue_free()
	_expect(touches == 0,
		"the chassis never hits the ground it is driving over (%d of %d frames, deepest %.3f m at %.0f m, reached %.0f m)"
			% [touches, frames, deepest, where, reached])


# ------------------------------------ what may hold a car up, and what may not

# A car decides what it is standing on with four downward rays, and then
# `_apply_ground` *places* the body at the height they report. That is a
# placement, not a force, so nothing stops it - which makes anything a ray can
# see a surface a car can be parked on. And a barrier is a closed ribbon with a
# top face at the top of it.
#
# A ray that catches that face tells the car the ground is a metre and a half
# above where it is. The car is placed up there, and from up there its other rays
# find the wall as well: it ratchets up and ends balanced on the barrier with its
# wheels hanging down either side. That is a car submerged in a road separator,
# and it is the whole reason the ground rays are masked to the ground alone.
#
# `scripts/core/layers.gd` is the design - obstacles go on OBSTACLE, the ground
# rays are masked to WORLD, and a car's body keeps hitting both - and this is the
# check that says whether it was wired up. It asks the car's own ray mask, at the
# top of everything a car must never stand on, and it is deliberately not a test
# of the constants: a design that is only written down is the bug.
func _check_the_ground_rays_see_only_ground() -> void:
	var mask := Layers.GROUND_MASK
	var offenders := {}
	var probed := 0

	# The barrier: the top of it, all the way round, on both sides, which is the
	# one place a wheel ray has to be for a car to be balanced on it. Its shape is
	# a ribbon with no readable extent, so it is probed along its own length
	# rather than from a bounding box.
	var middle := _builder.wall_face_lateral() + TrackBuilder.WALL_THICKNESS * 0.5
	var step := maxf(20.0, _builder.info.length / 700.0)
	var s := 0.0
	while s < _builder.info.length:
		for side: float in [-1.0, 1.0]:
			var t := _builder.get_transform_at(s, side * middle)
			var top := t.origin.y + _builder.wall_height_at_distance(s, side)
			probed += 1
			var hit := _first_under(Vector3(t.origin.x, top + 1.0, t.origin.z), mask)
			if hit != null and not _is_ground(hit):
				offenders[str(hit.name)] = int(offenders.get(str(hit.name), 0)) + 1
		s += step

	# Trunks, posts and buildings: the same question at the top of each. A trunk
	# is twenty metres tall on the larger trees, so a ray that catches one does
	# not put the car on a barrier - it puts it on the canopy.
	for entry: Dictionary in _not_ground_shapes():
		probed += 1
		var body := _first_under(entry["top"], mask)
		if body != null and not _is_ground(body):
			offenders[str(body.name)] = int(offenders.get(str(body.name), 0)) + 1

	_expect(offenders.is_empty(),
		"the ground rays see ground and nothing else (%d probed, %s)" % [
			probed,
			"found nothing else" if offenders.is_empty() else "found %s" % str(offenders),
		])


# The other half of that design, and the half it is easy to lose: taking the
# obstacles off the world layer must not make them pass-through. The barrier a
# car is no longer lifted onto still has to stop it, or the fix trades one bug
# for a worse one.
func _check_the_car_still_hits_what_the_rays_ignore() -> void:
	# Read off a car rather than restated here. The question this asks is whether
	# the car in the game is configured the way the design says, and a check that
	# claims the answer by repeating the constant cannot tell.
	var car := Car.new()
	_world.add_child(car)
	var mask := car.collision_mask
	car.queue_free()

	var missed := {}
	var checked := 0
	for entry: Dictionary in _not_ground_shapes():
		var body: Node = entry["body"]
		if str(body.name) in missed or str(body.name) == "":
			continue
		checked += 1
		var layer := (body as CollisionObject3D).collision_layer
		if (layer & mask) == 0:
			missed[str(body.name)] = layer
	_expect(checked > 0 and missed.is_empty(),
		"the car body collides with all %d things its rays ignore (missing %s)" % [
			checked,
			"none" if missed.is_empty() else str(missed),
		])


# Every solid body in the circuit against the three layers - all of them, not a
# sample of them.
#
# The checks above ask the car's mask at the top of each kind of thing it must
# not climb, and then whether those things still stop it. This one takes the
# whole set and asserts the partition, in both directions:
#
#   a ground body          is on WORLD, so the car's ground rays CAN find it
#   anything not ground    is on OBSTACLE, so the rays CANNOT see it and the
#                          car's body CAN still hit it
#   a car                  is on CARS, which neither the rays nor its own body
#                          needs explaining
#
# Both directions matter, and the second is the half a careless fix breaks. Put
# the barrier on OBSTACLE without giving the car OBSTACLE in its mask and cars
# drive through walls. Put the terrain on OBSTACLE along with it and the ground
# rays find nothing, so the car falls out of the world. Neither shows up in a
# drove-into-a-wall check - a car that never reaches the wall is not "stopped by"
# anything - and both show up here, on every body, on every circuit.
func _check_every_body_is_on_a_layer_that_works() -> void:
	var faults := {}
	var ground := 0
	var obstacles := 0
	var cars := 0
	for body in _all_collision_bodies():
		var key := str(body.name)
		var layer := (body as CollisionObject3D).collision_layer
		var wrong := PackedStringArray()
		if layer != Layers.WORLD and layer != Layers.CARS and layer != Layers.OBSTACLE:
			wrong.append("layer %d is not one of the three" % layer)
		if _is_ground(body):
			ground += 1
			if layer != Layers.WORLD:
				wrong.append("is ground but is not on WORLD, so no ray can find it")
		elif layer == Layers.CARS:
			cars += 1
		else:
			obstacles += 1
			if layer != Layers.OBSTACLE:
				wrong.append("is not ground but is not on OBSTACLE, so a car can stand on it")
			if (layer & Layers.GROUND_MASK) != 0:
				wrong.append("is not ground and the ground rays can see it")
			if (layer & Layers.CAR_MASK) == 0:
				wrong.append("is not ground and the car's body cannot hit it, so cars pass through")
		if not wrong.is_empty():
			faults[key] = ", ".join(wrong)
	_expect(ground > 0 and obstacles > 0 and faults.is_empty(),
		"every solid body is on a layer that works (%d ground, %d not ground, %d cars; %s)" % [
			ground, obstacles, cars,
			"all correct" if faults.is_empty() else str(faults),
		])


func _all_collision_bodies() -> Array:
	var out: Array = []
	var stack: Array[Node] = [_world]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is CollisionObject3D:
			out.append(node)
	return out


# The ground, labelled the way the game labels it: the road carries `surface`
# "road", and the verge and the terrain carry "grass". Anything else a ray answers
# with - a barrier, a trunk, a post, a building - is something a car must not be
# held up by.
func _is_ground(body: Node) -> bool:
	var surface := str(body.get_meta("surface", ""))
	return surface == "road" or surface == "grass"


# Every collision shape in the circuit that is not ground, with a point a metre
# above the top of it. The barrier's own ribbon has no readable extent and is
# probed along its length instead.
func _not_ground_shapes() -> Array:
	var out: Array = []
	var stack: Array[Node] = [_builder]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is StaticBody3D):
			continue
		if _is_ground(node):
			continue                      # ground, and meant to be stood on
		for child in node.get_children():
			var collider := child as CollisionShape3D
			if collider == null:
				continue
			_add_shape_top(out, node, collider)
	return out


func _add_shape_top(out: Array, body: Node, collider: CollisionShape3D) -> void:
	var shape := collider.shape
	if shape is CylinderShape3D:
		var height := (shape as CylinderShape3D).height
		out.append({"body": body,
			"top": collider.global_position + Vector3.UP * (height * 0.5 + 1.0)})
	elif shape is BoxShape3D:
		var up: Vector3 = collider.global_transform.basis.y.normalized()
		var half := (shape as BoxShape3D).size.y * 0.5
		out.append({"body": body, "top": collider.global_position + up * (half + 1.0)})


# What one downward ray with `mask` finds first, or null. This is a hand-rolled
# copy of what `Car` does with its four wheel rays, on purpose: the point is to
# ask the same question of the same physics with the same mask.
func _first_under(from: Vector3, mask: int) -> Node:
	var space := _world.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from - Vector3.UP * 500.0)
	query.collision_mask = mask
	var hit := space.intersect_ray(query)
	if not hit.has("collider"):
		return null
	return hit["collider"] as Node


# ------------------------------------------------------------- hitting things

func _drive_into(from: Vector3, towards: Vector3, seconds: float) -> Dictionary:
	"""Point a car at something, hold the throttle down, and report where it got
	to. Returns the distance travelled and how far it ended up past the target."""
	var car := Car.new()
	_world.add_child(car)
	var direction := (towards - from)
	direction.y = 0.0
	direction = direction.normalized()
	var basis := Basis.looking_at(direction, Vector3.UP)
	car.global_transform = Transform3D(basis, from)
	car.track = _builder.info
	car.driver = FixedDriver.new(1.0)
	car.locked = false
	await get_tree().physics_frame
	var start := car.global_position
	var steps := int(seconds * Engine.physics_ticks_per_second)
	var peak := 0.0
	for i in steps:
		await get_tree().physics_frame
		peak = maxf(peak, car.speed_kmh())
	var travelled := car.global_position.distance_to(start)
	var beyond := (car.global_position - towards).dot(direction)
	car.queue_free()
	return {"travelled": travelled, "beyond": beyond, "peak": peak}


func _check_walls_stop_a_car() -> void:
	# The barrier, at right angles, on both sides, all the way round.
	#
	# This used to test exactly one place - a quarter of the way round the lap -
	# and pass while the barrier was a fiction for half a kilometre of Kigali.
	# Where the circuit runs back alongside itself the ground between the two
	# roads is banked up to the higher one, which buried the lower one's
	# barrier, and a car drove up its own shoulder, over it, and into the
	# oncoming road. One sample point cannot find that; a lap of them can.
	var worst := -INF
	var worst_at := 0.0
	var tested := 0
	var escaped := 0
	var step := maxf(250.0, _builder.info.length / 14.0)
	var s := 0.0
	while s < _builder.info.length:
		for side: float in [-1.0, 1.0]:
			var t := _builder.get_transform_at(s, 0.0)
			var right := t.basis.x.normalized() * side
			var wall := t.origin + right * _builder.wall_face_lateral()
			var from := t.origin + Vector3.UP * 0.4
			var result := await _drive_into(from, wall + Vector3.UP * 0.4, 5.0)
			tested += 1
			var beyond := float(result["beyond"])
			if beyond >= 1.0:
				escaped += 1
			if beyond > worst:
				worst = beyond
				worst_at = s
		s += step
	_expect(escaped == 0,
		"the barrier stops a car driven at it everywhere (%d of %d, worst %.2f m past the wall face at %.0f m)"
			% [tested - escaped, tested, worst, worst_at])


# The same failure, measured rather than driven: a barrier is only a barrier if
# the ground outside it is lower than its top. This is the cheap, complete form
# of the test above - every metre of the lap instead of a couple of dozen
# samples - and it is what actually pins down where the trouble is.
func _check_the_barrier_is_not_buried() -> void:
	var over := 0
	var tested := 0
	var worst := 0.0
	var worst_at := 0.0
	var lateral := _builder.wall_face_lateral()
	var s := 0.0
	while s < _builder.info.length:
		for side: float in [-1.0, 1.0]:
			var t := _builder.get_transform_at(s, 0.0)
			var right := t.basis.x.normalized() * side
			var top := t.origin.y + _builder.wall_height_at_distance(s, side)
			for out: float in [1.2, 3.0, 5.0]:
				var probe := t.origin + right * (lateral + out)
				var hit := _ground_under(probe, 200.0)
				if not hit.has("collider"):
					continue
				# Only the ground. A building standing beside the barrier is
				# taller than it and that is fine - a wall is not a ramp, and
				# nothing drives up the side of one. What this is looking for
				# is *ground* a car can climb.
				var body: Node = hit["collider"]
				if str(body.get_meta("surface", "")) != "grass":
					continue
				tested += 1
				var here: float = (hit["position"] as Vector3).y
				if here > top + 0.05:
					over += 1
					if here - top > worst:
						worst = here - top
						worst_at = s
		s += 8.0
	_expect(over == 0,
		"the ground outside the barrier never stands above it (%d of %d, worst %.2f m over at %.0f m)"
			% [tested - over, tested, worst, worst_at])


# Nothing the track builder scatters may stand on the road. Offsetting sideways
# from the centreline does not guarantee that: inside a corner tighter than the
# offset the point folds past the centre of the corner, and where the Kigali
# lap runs back alongside itself a tree fifteen metres off one pass is five
# metres onto the other. Harmless while scenery was decoration; a tree with a
# solid trunk standing on the racing line is not.
func _check_nothing_stands_on_the_circuit() -> void:
	var limit := _builder.wall_face_lateral()
	var closest := INF
	var offenders := 0
	var shapes := 0
	for child in _builder.get_children():
		if not (child is StaticBody3D) or not str(child.name).ends_with("Solid"):
			continue
		for node in child.get_children():
			var collider := node as CollisionShape3D
			if collider == null:
				continue
			shapes += 1
			var radius := 0.0
			if collider.shape is CylinderShape3D:
				radius = (collider.shape as CylinderShape3D).radius
			var near := _builder.info.nearest(collider.global_position)
			var gap: float = absf(near["lateral"]) - radius
			closest = minf(closest, gap)
			if gap < limit:
				offenders += 1
	if shapes == 0:
		_expect(true, "this circuit scatters no solid scenery")
		return
	_expect(offenders == 0,
		"no solid scenery stands inside the barrier (%d shapes, nearest %.2f m from the centreline, barrier at %.2f m)"
			% [shapes, closest, limit])


func _check_trees_stop_a_car() -> void:
	# A tree, rammed. The trunks were decoration until now - a MultiMesh draws
	# and that is all it does - so a car went through a street tree without so
	# much as a scrape, which on a circuit lined with them is the most obvious
	# thing in the world that can be wrong with it.
	var target := Vector3.ZERO
	var radius := 0.0
	for child in _builder.get_children():
		if not (child is StaticBody3D) or not str(child.name).begins_with("Trees"):
			continue
		for node in child.get_children():
			var collider := node as CollisionShape3D
			if collider == null or not (collider.shape is CylinderShape3D):
				continue
			var near := _builder.info.nearest(collider.global_position)
			var gap: float = absf(near["lateral"])
			# Near enough to reach, far enough to get up to speed first.
			if gap > 9.0 and gap < 20.0 and target == Vector3.ZERO:
				target = collider.global_position
				radius = (collider.shape as CylinderShape3D).radius
	if target == Vector3.ZERO:
		_expect(true, "no tree close enough to the road to ram")
		return
	# Started *outside* the barrier, level with the tree and aimed along the
	# circuit at it. Driving at it from the racing line does not test the tree
	# at all: the barrier is between the two, and the first version of this
	# passed by being stopped eight metres short of a trunk it never reached.
	var on_line: Dictionary = _builder.info.nearest(target)
	var index: int = on_line["index"]
	var outward := (target - (on_line["position"] as Vector3))
	outward.y = 0.0
	outward = outward.normalized()
	var along: Vector3 = _builder.info.tangents[index]
	along.y = 0.0
	along = along.normalized()
	var ground := _ground_under(target - along * 14.0)
	if not ground.has("position"):
		_expect(true, "no ground beside that tree to start a car on")
		return
	var from: Vector3 = (ground["position"] as Vector3) + Vector3.UP * 0.5
	var result := await _drive_into(from, Vector3(target.x, from.y, target.z), 6.0)
	_expect(float(result["travelled"]) > 2.0 and float(result["beyond"]) < radius,
		"a tree stops a car driven at it (travelled %.1f m, stopped %.2f m short of the trunk, peak %.0f km/h)"
			% [result["travelled"], -float(result["beyond"]), result["peak"]])


func _check_buildings_stop_a_car() -> void:
	# And a building. Picked from the city's own landmark list rather than by
	# eye, so the test aims at a building that is really there.
	var city: City = _builder.city
	if city == null or city.landmarks.is_empty():
		_expect(true, "no city on this circuit, so nothing to drive into")
		return
	var target := Vector3.ZERO
	var best := INF
	for entry: Dictionary in city.landmarks:
		var p: Array = entry["position"]
		var here := Vector3(float(p[0]), float(p[1]), float(p[2]))
		var on_line: Vector3 = _builder.info.nearest(here)["position"]
		var distance := Vector2(here.x - on_line.x, here.z - on_line.z).length()
		# Close enough to the road that the car can reach it, far enough that
		# there is room to get up to speed first.
		if distance < best and distance > 18.0 and distance < 60.0:
			best = distance
			target = here
	if target == Vector3.ZERO:
		_expect(true, "no named building near enough to the road to ram")
		return

	var on_line: Vector3 = _builder.info.nearest(target)["position"]
	var direction := (target - on_line)
	direction.y = 0.0
	direction = direction.normalized()
	var from := on_line + Vector3.UP * 0.4 - direction * 4.0
	var ground := _ground_under(target)
	var wall := target
	if ground.has("position"):
		wall = Vector3(target.x, (ground["position"] as Vector3).y, target.z)
	var result := await _drive_into(from, wall, 7.0)
	# "Beyond" is measured against the building's centre, so anything short of
	# its own half width means the car was stopped by its wall.
	_expect(float(result["beyond"]) < 0.0,
		"a building stops a car driven at it (stopped %.1f m short of its centre, %.0f m away, peak %.0f km/h)"
			% [-result["beyond"], best, result["peak"]])
