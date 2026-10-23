class_name AiDriver
extends RefCounted
# Drives a car around the circuit. It aims at a point a distance ahead that
# grows with speed, offsets that point toward the inside of the corner it can
# see coming, and picks a target speed from the tightest curvature within
# braking distance. The result is a driver that brakes for corners it has not
# reached yet - the difference between an opponent and a moving obstacle.
#
# It only ever produces CarControls, the same struct the player produces, so an
# AI car is subject to exactly the same physics.

var track: TrackInfo
var car: Car
var skill := 0.92              # scales cornering grip and top speed
var lane_bias := 0.0           # personal line offset, -1..1 of half a road
var aggression := 1.0
var max_lat_accel := 17.5      # m/s^2 the driver dares to use
var s := 0.0

# Held on the grid until the lights go out. The cars are not locked any more -
# they have to be free for a jump start to be a thing that can happen - so the
# AI has to be told to stay put instead, or it would drive off during the
# countdown and book itself every single race.
var hold := false

var _stuck_time := 0.0
var _reverse_time := 0.0
var _progress_mark := 0.0
var _mark_time := 0.0
var _jitter := RandomNumberGenerator.new()
var _avoid := 0.0


func setup(p_car: Car, p_track: TrackInfo, index: int, p_skill: float) -> void:
	car = p_car
	track = p_track
	skill = p_skill
	_jitter.seed = 1000 + index * 977
	lane_bias = _jitter.randf_range(-0.55, 0.55)
	aggression = _jitter.randf_range(0.9, 1.1)
	max_lat_accel = lerpf(12.0, 22.0, clampf(skill, 0.0, 1.3) / 1.3)


func poll(p_car: Car, delta: float) -> CarControls:
	car = p_car
	var out := CarControls.new()
	if hold:
		# Nothing at all, rather than the brake. A held brake on a stationary
		# car is not "stay put" in this physics: past a standstill the brake
		# becomes reverse, so the whole field would have backed off the grid
		# during the countdown and booked itself for moving before the lights
		# went out. A grounded car with no input does not roll: gravity is
		# projected onto the surface it is standing on.
		return out
	if track == null:
		return out
	s = car.track_s
	var speed := maxf(car.forward_speed, 0.0)
	var lookahead := clampf(speed * 0.62, 11.0, 46.0)

	# Target speed: the slowest corner the driver can still see.
	var target_speed := car.max_speed * (0.72 + 0.28 * clampf(skill, 0.0, 1.3))
	var scan := 8.0
	while scan <= lookahead:
		var sample := track.point_at(s + scan)
		var k := absf(sample["curvature"])
		if k > 0.0008:
			var corner := sqrt(max_lat_accel * skill / k)
			# Slower the further into the corner the sample is.
			var approach := lerpf(0.72, 1.0, clampf(scan / maxf(lookahead, 1.0), 0.0, 1.0))
			target_speed = minf(target_speed, corner * approach)
		scan += 6.0

	# Racing line: aim inside the corner that is coming, not where the car is.
	var ahead := track.point_at(s + lookahead * 0.8)
	var corner_k: float = ahead["curvature"]
	var inside := -signf(corner_k) * track.half_width * 0.46 * clampf(absf(corner_k) * 260.0, 0.0, 1.0)
	_avoid = lerpf(_avoid, _avoidance(), clampf(3.0 * delta, 0.0, 1.0))
	var wanted_lateral := inside + lane_bias * track.half_width * 0.30 + _avoid
	var target := track.point_at(s + lookahead)
	var target_pos: Vector3 = target["position"] + (target["right"] as Vector3) * wanted_lateral

	# Pure pursuit steering on the ground plane.
	var to_target := target_pos - car.global_position
	to_target.y = 0.0
	var forward := -car.global_transform.basis.z
	forward.y = 0.0
	if to_target.length_squared() > 0.01:
		forward = forward.normalized()
		var wanted := to_target.normalized()
		var angle := forward.signed_angle_to(wanted, Vector3.UP)
		var authority := clampf(1.6 - speed / maxf(car.max_speed, 1.0), 0.35, 1.6)
		out.steer = clampf(-angle * 1.9 * authority, -1.0, 1.0)

	# Pedals.
	var error := target_speed - speed
	if car.finished:
		out.throttle = 0.0
		out.brake = clampf(speed / 12.0, 0.0, 0.6)
	elif error > 0.4:
		out.throttle = clampf(error / 5.0, 0.0, 1.0)
	elif error < -1.0:
		out.brake = clampf(-error / 9.0, 0.0, 1.0)
	else:
		out.throttle = 0.25

	# Boost down the straights only.
	var straight := absf(corner_k) < 0.0016
	if straight and car.boost_charge > 0.55 and speed > 8.0:
		out.boost = true
		out.throttle = 1.0

	_recover(delta, out)
	return out


# Nudge sideways around a car that is immediately ahead and slower.
func _avoidance() -> float:
	if car == null or car.get_tree() == null:
		return 0.0
	var mine := -car.global_transform.basis.z
	var away := 0.0
	for other in car.get_tree().get_nodes_in_group("cars"):
		if other == car or not (other is Car):
			continue
		var delta: Vector3 = (other as Car).global_position - car.global_position
		var ahead := delta.dot(mine)
		if ahead < 0.5 or ahead > 16.0:
			continue
		var lateral := delta.dot(car.global_transform.basis.x)
		if absf(lateral) > 5.0:
			continue
		away -= signf(lateral if absf(lateral) > 0.2 else 1.0) * 2.4
	return clampf(away, -3.2, 3.2)


func _recover(delta: float, out: CarControls) -> void:
	# A driver that is wedged against a barrier reverses out and tries again
	# rather than sitting there for the rest of the race.
	if _reverse_time > 0.0:
		_reverse_time -= delta
		out.throttle = 0.0
		out.brake = 1.0
		out.steer = -out.steer
		return
	if absf(car.forward_speed) < 1.6:
		_stuck_time += delta
	else:
		_stuck_time = maxf(0.0, _stuck_time - delta * 2.0)
	if _stuck_time > 1.6:
		_stuck_time = 0.0
		_reverse_time = 1.2
	# Progress watchdog: if the car has not advanced for a long time, take the
	# respawn instead of ruining the race.
	_mark_time += delta
	if _mark_time > 6.0:
		_mark_time = 0.0
		if absf(track.forward_delta(_progress_mark, s)) < 12.0:
			car.respawn()
		_progress_mark = s
