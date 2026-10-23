class_name MainMenu
extends Control
# The front end: pick a circuit, opponents, laps and difficulty, then race. Also
# the controls screen, which is where an Arduino steering wheel gets set up:
# every axis on the attached device is shown live, and an axis can be captured by
# simply moving that control, so nothing has to be typed in or guessed.

const ACTIONS := [
	["steer_left", "Steer left"], ["steer_right", "Steer right"],
	["throttle", "Throttle"], ["brake", "Brake / reverse"],
	["handbrake", "Handbrake"], ["boost", "Boost"],
	["reset_car", "Reset car"], ["camera_toggle", "Camera"],
	["look_back", "Look back"], ["pause", "Pause"],
]
const AXES_SHOWN := 8

var _background: Control
var _main_box: VBoxContainer
var _controls_box: VBoxContainer
var _rules_box: VBoxContainer
var _rules_scroll: ScrollContainer
var _selector_values := {}
var _action_bars := {}
var _axis_bars := {}
var _axis_labels := {}
var _status: Label
var _capture := ""
var _track_info: TrackInfo
var _device_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_background()
	_build_main()
	_build_controls()
	_build_rules()
	_refresh_track_background()
	_refresh()
	_show_main()


# ------------------------------------------------------------------ background

func _build_background() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.045, 0.05, 0.07)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	_background = Control.new()
	_background.name = "CircuitOutline"
	_background.set_anchors_preset(Control.PRESET_FULL_RECT)
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_background.draw.connect(_draw_circuit)
	add_child(_background)


func _refresh_track_background() -> void:
	var definition := TrackData.get_track(Game.track_index)
	var loop := TrackData.sample_loop(TrackData.control_points(definition), 6.0)
	_track_info = TrackInfo.new()
	_track_info.build_from(loop, float(definition.get("half_width", 7.0)), 6.0)
	_background.queue_redraw()


func _draw_circuit() -> void:
	if _track_info == null or _track_info.count == 0:
		return
	var rect := size
	var path := _track_info.grid_path_2d()
	var bounds := Rect2(path[0], Vector2.ZERO)
	for p: Vector2 in path:
		bounds = bounds.expand(p)
	var scale := minf(rect.x / maxf(bounds.size.x, 1.0), rect.y / maxf(bounds.size.y, 1.0)) * 0.62
	var offset := (rect - bounds.size * scale) * 0.5 - bounds.position * scale
	var points := PackedVector2Array()
	for p: Vector2 in path:
		points.append(p * scale + offset)
	_background.draw_polyline(points, Color(0.36, 0.92, 0.48, 0.16), 26.0, true)
	_background.draw_polyline(points, Color(0.36, 0.92, 0.48, 0.30), 4.0, true)


# ------------------------------------------------------------------- main menu

func _build_main() -> void:
	_main_box = VBoxContainer.new()
	_main_box.name = "Main"
	_main_box.add_theme_constant_override("separation", 8)
	_main_box.position = Vector2(64, 56)
	add_child(_main_box)

	var title := Label.new()
	title.text = "ASTRA RACER"
	title.add_theme_font_size_override("font_size", 62)
	title.add_theme_color_override("font_color", Color(0.36, 0.92, 0.48))
	_main_box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "three laps, four rivals, one very good reason to brake later"
	subtitle.add_theme_font_size_override("font_size", 17)
	subtitle.add_theme_color_override("font_color", Color(1, 1, 1, 0.62))
	_main_box.add_child(subtitle)

	_main_box.add_child(_spacer(18))
	_selector("Circuit", "track_index", _main_box, TrackData.track_count(),
		func() -> String: return str(TrackData.get_track(Game.track_index)["name"]))
	_selector("Rivals", "opponents", _main_box, 8,
		func() -> String: return "%d  (you start last)" % Game.opponents)
	_selector("Laps", "laps", _main_box, 30,
		func() -> String: return "%d" % Game.laps)
	_selector("Difficulty", "difficulty", _main_box, 4,
		func() -> String:
			if Game.difficulty < 0.8:
				return "Gentle"
			elif Game.difficulty < 1.0:
				return "Club"
			elif Game.difficulty < 1.1:
				return "Pro"
			return "Ruthless")

	var blurb := Label.new()
	blurb.name = "Blurb"
	blurb.add_theme_font_size_override("font_size", 15)
	blurb.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	blurb.custom_minimum_size = Vector2(620, 40)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_main_box.add_child(blurb)

	_main_box.add_child(_spacer(14))
	_main_box.add_child(_button("RACE", func() -> void: Game.start_race(Game.track_index)))
	_main_box.add_child(_button("CONTROLS & WHEEL", func() -> void: _show_controls()))
	_main_box.add_child(_button("RACE RULES", func() -> void: _show_rules()))
	_main_box.add_child(_button("QUIT", func() -> void: Game.quit_game()))

	var keys := Label.new()
	keys.add_theme_font_size_override("font_size", 14)
	keys.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	keys.text = "A/D or wheel steer   W/S or pedals   Space handbrake   Shift boost\nC camera   R reset   Tab look back   Esc pause"
	_main_box.add_child(_spacer(10))
	_main_box.add_child(keys)


func _selector(title: String, key: String, parent: VBoxContainer, max_value: int,
		display: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)

	var label := Label.new()
	label.text = title
	label.custom_minimum_size = Vector2(130, 0)
	label.add_theme_font_size_override("font_size", 20)
	row.add_child(label)

	row.add_child(_arrow("<", func() -> void:
		_step(key, -1, max_value)
		_refresh()))
	var value := Label.new()
	value.custom_minimum_size = Vector2(300, 0)
	value.add_theme_font_size_override("font_size", 20)
	value.add_theme_color_override("font_color", Color(0.36, 0.92, 0.48))
	row.add_child(value)
	row.add_child(_arrow(">", func() -> void:
		_step(key, 1, max_value)
		_refresh()))
	_selector_values[key] = {"label": value, "display": display}


func _step(key: String, direction: int, max_value: int) -> void:
	match key:
		"track_index":
			Game.set_setting("track_index", wrapi(Game.track_index + direction, 0, TrackData.track_count()))
			_refresh_track_background()
		"opponents":
			Game.set_setting("opponents", wrapi(Game.opponents + direction, 0, maxi(1, max_value)))
		"laps":
			Game.set_setting("laps", wrapi(Game.laps + direction - 1, 0, max_value) + 1)
		"difficulty":
			var steps := [0.75, 0.9, 1.0, 1.12]
			var index := 0
			for i in steps.size():
				if absf(float(steps[i]) - Game.difficulty) < 0.05:
					index = i
			index = wrapi(index + direction, 0, steps.size())
			Game.set_setting("difficulty", float(steps[index]))


func _arrow(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(44, 34)
	button.add_theme_font_size_override("font_size", 20)
	button.pressed.connect(action)
	return button


func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(320, 44)
	button.add_theme_font_size_override("font_size", 20)
	button.pressed.connect(action)
	return button


func _spacer(height: int) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	return spacer


# --------------------------------------------------------- controls & wheel

func _build_controls() -> void:
	_controls_box = VBoxContainer.new()
	_controls_box.name = "Controls"
	_controls_box.add_theme_constant_override("separation", 6)
	_controls_box.position = Vector2(64, 40)
	_controls_box.visible = false
	add_child(_controls_box)

	var title := Label.new()
	title.text = "CONTROLS & STEERING WHEEL"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color(0.36, 0.92, 0.48))
	_controls_box.add_child(title)

	_device_label = Label.new()
	_device_label.add_theme_font_size_override("font_size", 16)
	_controls_box.add_child(_device_label)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 16)
	_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	_controls_box.add_child(_status)

	var mode_row := HBoxContainer.new()
	_controls_box.add_child(mode_row)
	mode_row.add_child(_arrow("<", func() -> void:
		Game.set_setting("input_mode", 1 - Game.input_mode)
		_refresh()))
	var mode_label := Label.new()
	mode_label.name = "ModeLabel"
	mode_label.custom_minimum_size = Vector2(420, 0)
	mode_label.add_theme_font_size_override("font_size", 18)
	mode_row.add_child(mode_label)
	mode_row.add_child(_arrow(">", func() -> void:
		Game.set_setting("input_mode", 1 - Game.input_mode)
		_refresh()))

	# Wheel axis assignment, captured by moving the control.
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 40)
	_controls_box.add_child(columns)

	var left := VBoxContainer.new()
	columns.add_child(left)
	var axis_title := Label.new()
	axis_title.text = "DEVICE AXES (live)"
	axis_title.add_theme_font_size_override("font_size", 18)
	left.add_child(axis_title)
	for i in AXES_SHOWN:
		var row := HBoxContainer.new()
		left.add_child(row)
		var label := Label.new()
		label.custom_minimum_size = Vector2(150, 0)
		label.add_theme_font_size_override("font_size", 15)
		row.add_child(label)
		var bar := ProgressBar.new()
		bar.min_value = -1.0
		bar.max_value = 1.0
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(220, 14)
		row.add_child(bar)
		_axis_labels[i] = label
		_axis_bars[i] = bar

	var right := VBoxContainer.new()
	columns.add_child(right)
	var bind_title := Label.new()
	bind_title.text = "WHEEL BINDINGS"
	bind_title.add_theme_font_size_override("font_size", 18)
	right.add_child(bind_title)
	for entry: Array in [["steer", "Steering"], ["throttle", "Throttle"], ["brake", "Brake"]]:
		var key := str(entry[0])
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		right.add_child(row)
		var label := Label.new()
		label.text = str(entry[1])
		label.custom_minimum_size = Vector2(110, 0)
		label.add_theme_font_size_override("font_size", 16)
		row.add_child(label)
		var value := Label.new()
		value.name = "Wheel" + key
		value.custom_minimum_size = Vector2(150, 0)
		value.add_theme_font_size_override("font_size", 16)
		value.add_theme_color_override("font_color", Color(0.36, 0.92, 0.48))
		row.add_child(value)
		row.add_child(_arrow("<", func() -> void:
			Game.wheel_axes[key] = wrapi(int(Game.wheel_axes[key]) - 1, 0, AXES_SHOWN)
			Game.save_settings()
			_refresh()))
		row.add_child(_arrow(">", func() -> void:
			Game.wheel_axes[key] = wrapi(int(Game.wheel_axes[key]) + 1, 0, AXES_SHOWN)
			Game.save_settings()
			_refresh()))
		var invert := CheckBox.new()
		invert.text = "invert"
		invert.add_theme_font_size_override("font_size", 15)
		invert.button_pressed = bool(Game.wheel_invert[key])
		invert.toggled.connect(func(pressed: bool) -> void:
			Game.wheel_invert[key] = pressed
			Game.save_settings())
		row.add_child(invert)
		var capture := Button.new()
		capture.text = "learn"
		capture.add_theme_font_size_override("font_size", 15)
		capture.pressed.connect(func() -> void:
			_capture = key
			_refresh())
		row.add_child(capture)

	var deadzone_row := HBoxContainer.new()
	_controls_box.add_child(deadzone_row)
	var dz_label := Label.new()
	dz_label.text = "Deadzone"
	dz_label.custom_minimum_size = Vector2(110, 0)
	deadzone_row.add_child(dz_label)
	var deadzone := HSlider.new()
	deadzone.min_value = 0.0
	deadzone.max_value = 0.3
	deadzone.step = 0.01
	deadzone.value = Game.wheel_deadzone
	deadzone.custom_minimum_size = Vector2(260, 0)
	deadzone.value_changed.connect(func(v: float) -> void:
		Game.set_setting("wheel_deadzone", v))
	deadzone_row.add_child(deadzone)

	var action_title := Label.new()
	action_title.text = "ACTIONS (live, by keyboard/gamepad)"
	action_title.add_theme_font_size_override("font_size", 18)
	_controls_box.add_child(action_title)
	for entry: Array in ACTIONS:
		var action := str(entry[0])
		var row := HBoxContainer.new()
		_controls_box.add_child(row)
		var label := Label.new()
		label.text = str(entry[1])
		label.custom_minimum_size = Vector2(150, 0)
		label.add_theme_font_size_override("font_size", 15)
		row.add_child(label)
		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = 1.0
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(220, 14)
		row.add_child(bar)
		_action_bars[action] = bar

	_controls_box.add_child(_spacer(12))
	_controls_box.add_child(_button("BACK", func() -> void: _show_main()))


func _show_controls() -> void:
	_main_box.visible = false
	_rules_box.visible = false
	_controls_box.visible = true
	_capture = ""
	_refresh()


func _show_rules() -> void:
	_main_box.visible = false
	_controls_box.visible = false
	_rules_box.visible = true
	# The rules are longer than a 720p screen, so they scroll - and the height
	# that has to scroll is whatever is left after the heading and the button,
	# which is only known once there is a viewport.
	if _rules_scroll != null:
		var rect := get_viewport().get_visible_rect()
		_rules_scroll.custom_minimum_size = Vector2(880,
			maxf(200.0, rect.size.y - 160.0))


func _show_main() -> void:
	_controls_box.visible = false
	_rules_box.visible = false
	_main_box.visible = true
	_refresh()


func _refresh() -> void:
	for key: String in _selector_values:
		var entry: Dictionary = _selector_values[key]
		(entry["label"] as Label).text = str((entry["display"] as Callable).call())
	var blurb := _main_box.get_node_or_null("Blurb") as Label
	if blurb != null:
		blurb.text = str(TrackData.get_track(Game.track_index)["blurb"])
	var mode_label := _controls_box.get_node_or_null("ModeLabel") as Label
	if mode_label != null:
		mode_label.text = "Input: %s" % (
			"steering wheel (calibrated axes)" if Game.input_mode == 1
			else "keyboard / gamepad (action map)"
		)
	for entry: Array in [["steer", "Steering"], ["throttle", "Throttle"], ["brake", "Brake"]]:
		var key := str(entry[0])
		var label := _controls_box.get_node_or_null("Wheel" + key) as Label
		if label != null:
			label.text = "axis %d" % int(Game.wheel_axes[key])
	if _status != null:
		_status.text = ("Move the %s control now..." % _capture) if _capture != "" \
			else "Press 'learn' then move the wheel or pedal to bind an axis."


func _process(_delta: float) -> void:
	if not _controls_box.visible:
		return
	var pads := Input.get_connected_joypads()
	if _device_label != null:
		if pads.is_empty():
			_device_label.text = "No gamepad or wheel detected - plug it in and it appears here."
		else:
			var names := PackedStringArray()
			for pad in pads:
				names.append(Input.get_joy_name(pad))
			_device_label.text = "Detected: %s" % ", ".join(names)
	var pad := pads[0] if not pads.is_empty() else -1
	for i in AXES_SHOWN:
		var value := Input.get_joy_axis(pad, i) if pad >= 0 else 0.0
		(_axis_bars[i] as ProgressBar).value = value
		(_axis_labels[i] as Label).text = "axis %d   %+.2f" % [i, value]
	for action: String in _action_bars:
		(_action_bars[action] as ProgressBar).value = Input.get_action_strength(action)


func _input(event: InputEvent) -> void:
	if _capture == "" or not (event is InputEventJoypadMotion):
		return
	var motion := event as InputEventJoypadMotion
	if absf(motion.axis_value) < 0.5:
		return
	Game.wheel_axes[_capture] = motion.axis
	Game.wheel_invert[_capture] = motion.axis_value < 0.0
	Game.set_setting("input_mode", 1)
	Game.save_settings()
	_capture = ""
	_refresh()
	get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _controls_box.visible:
		_show_main()


# --------------------------------------------------------------- the rules

# The rules, written down. Race control gives time penalties and it
# disqualifies people, and a game that does either without ever having said it
# would is not enforcing rules, it is playing tricks. Everything on this screen
# is a number that is actually in RaceRules, so it cannot drift into being a
# description of a game this is not.
func _build_rules() -> void:
	_rules_box = VBoxContainer.new()
	_rules_box.name = "Rules"
	_rules_box.add_theme_constant_override("separation", 8)
	_rules_box.position = Vector2(64, 28)
	_rules_box.visible = false
	add_child(_rules_box)

	var title := Label.new()
	title.text = "RACE RULES"
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color(0.36, 0.92, 0.48))
	_rules_box.add_child(title)

	_rules_scroll = ScrollContainer.new()
	_rules_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rules_box.add_child(_rules_scroll)
	var entries := VBoxContainer.new()
	entries.add_theme_constant_override("separation", 6)
	_rules_scroll.add_child(entries)

	for entry: Array in [
		["The lap", "Fourteen checkpoints have to be crossed in order. Cut the "
			+ "circuit or drive backwards and the lap simply does not count - "
			+ "there is nothing to gain by it."],
		["The start", "You are not held on the grid. Move before the lights go "
			+ "out and it is a jump start: %ds, once." % int(RaceRules.JUMP_PENALTY)],
		["Track limits", ("All four wheels off the road for more than a moment "
			+ "is leaving the circuit. %d warnings a lap are free, because "
			+ "being put on the grass is racing. After that it is +%ds each "
			+ "time.") % [RaceRules.LIMITS_FREE, int(RaceRules.LIMITS_PENALTY)]],
		["Contact", "Barriers, buildings, trees and the other cars are all "
			+ "solid. A shunt damages the car, and a damaged car is down on "
			+ "power and down on top speed until you nurse it back or press "
			+ "reset. There is no time penalty: you have already lost the "
			+ "time."],
		["Wrong way", "You are warned after %ds and disqualified after %ds."
			% [int(RaceRules.WRONG_WAY_WARN), int(RaceRules.WRONG_WAY_DQ)]],
		["Disqualification", ("%ds of penalties ends your race, and so does "
			+ "ignoring the wrong-way warning. A disqualified driver is "
			+ "classified behind everyone who finished.")
			% int(RaceRules.DQ_PENALTY_SECONDS)],
		["Where you see it", "Every ruling is announced as it is given and the "
			+ "running total sits under the lap timer. Nothing is sprung on "
			+ "you at the end."],
	]:
		var heading := Label.new()
		heading.text = str(entry[0])
		heading.add_theme_font_size_override("font_size", 19)
		heading.add_theme_color_override("font_color", Color(1, 0.78, 0.35))
		entries.add_child(heading)

		var body := Label.new()
		body.text = str(entry[1])
		body.add_theme_font_size_override("font_size", 15)
		body.add_theme_color_override("font_color", Color(0.84, 0.87, 0.9))
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.custom_minimum_size = Vector2(840, 0)
		entries.add_child(body)

	_rules_box.add_child(_button("BACK", func() -> void: _show_main()))
