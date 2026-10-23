class_name PlayerDriver
extends RefCounted
# Turns the player's hardware into CarControls. Two paths:
#   actions mode - the InputMap (keyboard, gamepad, or any pad whose layout
#                  matches the bindings Game registers);
#   wheel mode   - reads calibrated joystick axes straight from the device, so a
#                  hand-built Arduino wheel works whatever axis it reports on.
# Also applies the counter-steer assist, which is what makes the car drivable on
# a keyboard at racing speed.

var use_wheel := false
var axis_steer := 0
var axis_throttle := 2
var axis_brake := 3
var invert_steer := false
var invert_throttle := false
var invert_brake := false
var deadzone := 0.04
var sensitivity := 1.0
var assist := 0.35
var device := 0

# Filled in each poll so the HUD/controls screen can show what is being used.
var source := "keyboard"
var raw_steer := 0.0
var raw_throttle := 0.0
var raw_brake := 0.0


func refresh_from_settings() -> void:
	use_wheel = Game.input_mode == 1
	axis_steer = int(Game.wheel_axes["steer"])
	axis_throttle = int(Game.wheel_axes["throttle"])
	axis_brake = int(Game.wheel_axes["brake"])
	invert_steer = bool(Game.wheel_invert["steer"])
	invert_throttle = bool(Game.wheel_invert["throttle"])
	invert_brake = bool(Game.wheel_invert["brake"])
	deadzone = Game.wheel_deadzone
	sensitivity = Game.steer_sensitivity
	assist = Game.steering_assist


func poll(car: Car, _delta: float = 0.0) -> CarControls:
	var out := CarControls.new()
	if use_wheel and _wheel_connected():
		source = "wheel"
		raw_steer = _axis(axis_steer, invert_steer)
		raw_throttle = _pedal(axis_throttle, invert_throttle)
		raw_brake = _pedal(axis_brake, invert_brake)
		out.steer = raw_steer * sensitivity
		out.throttle = raw_throttle
		out.brake = raw_brake
	else:
		var keys := Input.get_axis("steer_left", "steer_right")
		var pad_steer := 0.0
		for pad in Input.get_connected_joypads():
			pad_steer = maxf(absf(Input.get_joy_axis(pad, axis_steer)), pad_steer)
		source = "keyboard" if pad_steer < deadzone else "pad"
		raw_steer = keys
		raw_throttle = Input.get_action_strength("throttle")
		raw_brake = Input.get_action_strength("brake")
		out.steer = keys * sensitivity
		out.throttle = raw_throttle
		out.brake = raw_brake

	out.handbrake = Input.is_action_pressed("handbrake")
	out.boost = Input.is_action_pressed("boost")

	# Counter-steer assist: blend the player's steering toward the direction the
	# car is actually sliding. Only for non-wheel input - a wheel user gets the
	# raw thing.
	if assist > 0.0 and not use_wheel and car != null:
		var slide := clampf(car.lateral_speed / 7.0, -1.0, 1.0)
		var blend := assist * clampf(absf(car.lateral_speed) / 3.0, 0.0, 1.0)
		out.steer = lerpf(out.steer, slide, blend)
	out.steer = clampf(out.steer, -1.0, 1.0)
	return out


func _wheel_connected() -> bool:
	return not Input.get_connected_joypads().is_empty()


func shape_axis(raw: float, deadzone: float, inverted: bool) -> float:
	# Pure mapping from a raw joystick axis reading to steering, so the wheel
	# calibration can be tested without a wheel plugged in.
	var value := -raw if inverted else raw
	if absf(value) < deadzone:
		return 0.0
	return clampf(signf(value) * (absf(value) - deadzone) / maxf(0.001, 1.0 - deadzone), -1.0, 1.0)


func shape_pedal(raw: float, deadzone: float, inverted: bool) -> float:
	# Pedals arrive either as a unipolar axis (released 0/-1, pressed +1) or as a
	# combined throttle/brake stick; both collapse to "how hard is it pressed".
	var value := -raw if inverted else raw
	return clampf((value - deadzone) / maxf(0.001, 1.0 - deadzone), 0.0, 1.0)


func _axis(index: int, inverted: bool) -> float:
	var value := 0.0
	for pad in Input.get_connected_joypads():
		if absf(Input.get_joy_axis(pad, index)) > absf(value):
			value = Input.get_joy_axis(pad, index)
	return shape_axis(value, deadzone, inverted)


func _pedal(index: int, inverted: bool) -> float:
	var value := 0.0
	for pad in Input.get_connected_joypads():
		if absf(Input.get_joy_axis(pad, index)) > absf(value):
			value = Input.get_joy_axis(pad, index)
	return shape_pedal(value, deadzone, inverted)
