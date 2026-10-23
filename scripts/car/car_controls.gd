class_name CarControls
extends RefCounted
# One physics step's worth of driving input. Produced by PlayerDriver (keyboard,
# gamepad or Arduino wheel) or by AiDriver, and consumed by Car - so the car
# cannot tell whether a human or the computer is driving it, which is what makes
# the AI testable against the same physics the player gets.

var steer := 0.0        # -1 full left .. +1 full right
var throttle := 0.0     # 0..1
var brake := 0.0        # 0..1
var handbrake := false
var boost := false


func reset() -> void:
	steer = 0.0
	throttle = 0.0
	brake = 0.0
	handbrake = false
	boost = false


func copy_from(other: CarControls) -> void:
	steer = other.steer
	throttle = other.throttle
	brake = other.brake
	handbrake = other.handbrake
	boost = other.boost


func duplicate_controls() -> CarControls:
	var out := CarControls.new()
	out.copy_from(self)
	return out


func as_dictionary() -> Dictionary:
	return {
		"steer": steer, "throttle": throttle, "brake": brake,
		"handbrake": handbrake, "boost": boost,
	}
