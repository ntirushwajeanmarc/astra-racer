extends Node
# Game: the autoload singleton. Holds player settings (persisted to user://),
# registers every input action at launch, owns the scene flow between menu and
# race, and carries the last race result into the results screen.
#
# Input actions are registered in code rather than in project.godot so the
# keyboard, gamepad and Arduino-wheel bindings live in one readable place - and
# so a wheel that reports its pots on unusual axes still works (the calibrated
# "wheel" input mode read below bypasses the action map entirely).

signal settings_changed

const SETTINGS_PATH := "user://settings.cfg"
const MENU_SCENE := "res://scenes/menu.tscn"
const RACE_SCENE := "res://scenes/race.tscn"

# --- persisted settings -----------------------------------------------------
var master_volume := 0.85
var laps := 3
var opponents := 4
var difficulty := 0.92          # AI skill multiplier, 0.7 easy .. 1.15 hard
var camera_mode := 0            # 0 chase, 1 close chase, 2 bonnet
var steering_assist := 0.35     # counter-steer help for keyboard players
var input_mode := 0             # 0 = actions (keyboard/gamepad), 1 = wheel axes
var wheel_axes := {"steer": 0, "throttle": 2, "brake": 3}
var wheel_invert := {"steer": false, "throttle": false, "brake": false}
var wheel_deadzone := 0.04
var steer_sensitivity := 1.0

var track_index := 0
var last_result: Dictionary = {}


func _ready() -> void:
	register_actions()
	load_settings()
	apply_volume()


# --------------------------------------------------------------------- input

const KEYS := {
	"steer_left": [KEY_A, KEY_LEFT],
	"steer_right": [KEY_D, KEY_RIGHT],
	"throttle": [KEY_W, KEY_UP],
	"brake": [KEY_S, KEY_DOWN],
	"handbrake": [KEY_SPACE],
	"boost": [KEY_SHIFT],
	"reset_car": [KEY_R],
	"camera_toggle": [KEY_C],
	"look_back": [KEY_TAB],
	"pause": [KEY_ESCAPE, KEY_P],
	"shift_up": [KEY_E],
	"shift_down": [KEY_Q],
}
# Joypad axes are bound by SDL index. Steering is axis 0 on every pad and wheel
# we care about; throttle and brake are bound on several plausible axes so a
# hand-built wheel works without rebinding (see docs/ARDUINO_WHEEL.md).
const JOY_AXES := {
	"steer_left": [[0, -1.0]],
	"steer_right": [[0, 1.0]],
	"throttle": [[1, -1.0], [5, 1.0], [2, 1.0], [7, 1.0]],
	"brake": [[1, 1.0], [4, 1.0], [3, 1.0], [6, 1.0]],
}
const JOY_BUTTONS := {
	"handbrake": [JOY_BUTTON_B, JOY_BUTTON_RIGHT_SHOULDER],
	"boost": [JOY_BUTTON_X, JOY_BUTTON_LEFT_SHOULDER],
	"reset_car": [JOY_BUTTON_Y],
	"pause": [JOY_BUTTON_START],
	"camera_toggle": [JOY_BUTTON_DPAD_UP],
	"look_back": [JOY_BUTTON_DPAD_DOWN],
	"shift_up": [JOY_BUTTON_RIGHT_SHOULDER],
	"shift_down": [JOY_BUTTON_LEFT_SHOULDER],
}


func register_actions() -> void:
	for action: String in KEYS:
		_action(action, KEYS[action], JOY_AXES.get(action, []), JOY_BUTTONS.get(action, []))
	# Menu actions the wheel's buttons should also drive.
	_action("ui_accept", [KEY_ENTER, KEY_SPACE], [], [JOY_BUTTON_A])
	_action("ui_cancel", [KEY_ESCAPE], [], [JOY_BUTTON_B])


func _action(name: String, keys: Array, motions: Array, buttons: Array, deadzone := 0.12) -> void:
	if not InputMap.has_action(name):
		InputMap.add_action(name, deadzone)
	else:
		InputMap.action_set_deadzone(name, deadzone)
	InputMap.action_erase_events(name)
	for k: int in keys:
		var key := InputEventKey.new()
		key.physical_keycode = k
		InputMap.action_add_event(name, key)
	for m: Array in motions:
		var motion := InputEventJoypadMotion.new()
		motion.axis = int(m[0])
		motion.axis_value = float(m[1])
		InputMap.action_add_event(name, motion)
	for b: int in buttons:
		var button := InputEventJoypadButton.new()
		button.button_index = b
		InputMap.action_add_event(name, button)


# ------------------------------------------------------------------ settings

func apply_volume() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(clampf(master_volume, 0.0001, 1.0)))
	AudioServer.set_bus_mute(0, master_volume <= 0.001)


func set_setting(key: String, value: Variant) -> void:
	if not (key in self) or self.get(key) == value:
		return
	self.set(key, value)
	save_settings()
	settings_changed.emit()


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("race", "laps", laps)
	cfg.set_value("race", "opponents", opponents)
	cfg.set_value("race", "difficulty", difficulty)
	cfg.set_value("race", "track_index", track_index)
	cfg.set_value("view", "camera_mode", camera_mode)
	cfg.set_value("control", "steering_assist", steering_assist)
	cfg.set_value("control", "input_mode", input_mode)
	cfg.set_value("control", "wheel_deadzone", wheel_deadzone)
	cfg.set_value("control", "steer_sensitivity", steer_sensitivity)
	for key: String in wheel_axes:
		cfg.set_value("wheel", "axis_" + key, wheel_axes[key])
		cfg.set_value("wheel", "invert_" + key, wheel_invert[key])
	cfg.save(SETTINGS_PATH)


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	master_volume = cfg.get_value("audio", "master_volume", master_volume)
	laps = clampi(int(cfg.get_value("race", "laps", laps)), 1, 30)
	opponents = clampi(int(cfg.get_value("race", "opponents", opponents)), 0, 7)
	difficulty = clampf(cfg.get_value("race", "difficulty", difficulty), 0.6, 1.2)
	track_index = int(cfg.get_value("race", "track_index", track_index))
	camera_mode = clampi(int(cfg.get_value("view", "camera_mode", camera_mode)), 0, 2)
	steering_assist = clampf(cfg.get_value("control", "steering_assist", steering_assist), 0.0, 1.0)
	input_mode = clampi(int(cfg.get_value("control", "input_mode", input_mode)), 0, 1)
	wheel_deadzone = clampf(cfg.get_value("control", "wheel_deadzone", wheel_deadzone), 0.0, 0.4)
	steer_sensitivity = clampf(cfg.get_value("control", "steer_sensitivity", steer_sensitivity), 0.5, 2.0)
	for key: String in wheel_axes:
		wheel_axes[key] = int(cfg.get_value("wheel", "axis_" + key, wheel_axes[key]))
		wheel_invert[key] = bool(cfg.get_value("wheel", "invert_" + key, wheel_invert[key]))


# --------------------------------------------------------------- scene flow

func start_race(index: int = -1) -> void:
	if index >= 0:
		set_setting("track_index", index)
		get_tree().change_scene_to_file(RACE_SCENE)


func start_menu() -> void:
	get_tree().change_scene_to_file(MENU_SCENE)


func report_result(result: Dictionary) -> void:
	last_result = result


func quit_game() -> void:
	get_tree().quit()
