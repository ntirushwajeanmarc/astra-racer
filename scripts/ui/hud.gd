class_name RaceHUD
extends CanvasLayer
# Everything the player reads during and after a race: position, lap, timing,
# the running order, the dial, the minimap, the countdown, the wrong-way
# warning, and the pause and results screens.
#
# Runs with PROCESS_MODE_ALWAYS so it keeps working - and can still be operated -
# while the tree is paused.

const PANEL := Color(0.05, 0.06, 0.08, 0.72)
const ACCENT := Color(0.36, 0.92, 0.48)
const LANDMARK_RANGE := 130.0     # metres: close enough to be passing it
const LANDMARK_HOLD := 2.4        # seconds a caption stays up once shown
const LANDMARK_POLL := 0.2        # seconds between lookups

var manager: RaceManager
var paused := false
var results_visible := false

var _position_label: Label
var _lap_label: Label
var _time_label: Label
var _gap_label: Label
var _order_label: Label
var _countdown_label: Label
var _warning_label: Label
var _notice_label: Label
var _penalty_label: Label
var _damage_label: Label
var _lap_popup: Label
var _dial: SpeedDial
var _map: MiniMap
var _pause_panel: Control
var _results_panel: Control
var _results_text: RichTextLabel
var _popup_timer := 0.0
var _go_timer := 0.0
var _volume: HSlider
var _landmark_label: Label
var _landmark_name := ""
var _landmark_hold := 0.0
var _landmark_poll := 0.0


func setup(p_manager: RaceManager) -> void:
	manager = p_manager
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 10
	_build()


func _build() -> void:
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_position_label = _text(root, Vector2(24, 18), 44, ACCENT)
	_lap_label = _text(root, Vector2(26, 68), 22, Color(1, 1, 1, 0.92))
	_order_label = _text(root, Vector2(26, 104), 15, Color(1, 1, 1, 0.72))

	_time_label = _text(root, Vector2(-320, 18), 30, Color(1, 1, 1, 0.95), true)
	_gap_label = _text(root, Vector2(-320, 54), 15, Color(1, 1, 1, 0.72), true)

	_map = MiniMap.new()
	_map.name = "MiniMap"
	_map.position = Vector2(-232, 84)
	_map.size = Vector2(208, 150)
	_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_map)

	_dial = SpeedDial.new()
	_dial.name = "SpeedDial"
	_dial.size = Vector2(196, 196)
	_dial.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_dial)

	_countdown_label = _text(root, Vector2(0, 0), 92, Color(1, 0.95, 0.6), true)
	_countdown_label.size = Vector2(300, 120)
	_warning_label = _text(root, Vector2(0, 0), 30, Color(1, 0.32, 0.26), true)
	_warning_label.size = Vector2(420, 40)
	_warning_label.text = "WRONG WAY - TURN AROUND"
	_warning_label.visible = false
	_lap_popup = _text(root, Vector2(0, 0), 30, ACCENT, true)
	_lap_popup.size = Vector2(520, 40)
	_lap_popup.visible = false

	# Race control. What it just ruled, in the middle of the screen where it
	# cannot be missed, and the running total underneath the lap time where it
	# can be checked. A penalty a driver only discovers on the results screen
	# is not a rule, it is an ambush.
	_notice_label = _text(root, Vector2(0, 0), 26, Color(1, 0.72, 0.24), true)
	_notice_label.size = Vector2(520, 36)
	_notice_label.visible = false
	_penalty_label = _text(root, Vector2(-320, 78), 17, Color(1, 0.62, 0.3), true)
	_penalty_label.visible = false
	# Damage. Only there when there is some, because an instrument that reads
	# zero for a whole clean race is an instrument nobody looks at.
	_damage_label = _text(root, Vector2(-320, 100), 17, Color(1, 0.45, 0.35), true)
	_damage_label.visible = false

	# The building you are passing, named. Kigali is a real place and 173 of the
	# buildings beside its road carry the name OpenStreetMap has for them, so
	# the circuit can say what it is going past: the arena, the ministry, the
	# school on the corner. Low and left, small and half transparent - it is a
	# caption on the scenery, not part of the instrument panel.
	_landmark_label = _text(root, Vector2(0, 0), 17, Color(1, 1, 1, 0.66))
	_landmark_label.size = Vector2(460, 26)
	_landmark_label.visible = false

	root.resized.connect(_relayout)
	_relayout()
	_build_pause(root)
	_build_results(root)


# What race control is saying about the player, and what it has already cost.
func _update_race_control() -> void:
	if manager == null or manager.rules == null or manager.player == null:
		return
	var book: RaceRules.Record = manager.rules.record(manager.player)
	if book == null:
		return
	_notice_label.visible = book.notice != ""
	_notice_label.text = book.notice
	_penalty_label.visible = book.penalty > 0.0 or book.disqualified
	_penalty_label.text = "DISQUALIFIED" if book.disqualified \
		else "PENALTY +%.0fs" % book.penalty
	_damage_label.visible = book.damage > 0.02
	_damage_label.text = "DAMAGE %d%%" % int(round(book.damage * 100.0))


func _text(parent: Control, pos: Vector2, size: int, colour: Color, right := false) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 6)
	label.position = pos
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _relayout() -> void:
	var rect := get_viewport().get_visible_rect()
	if _dial != null:
		_dial.position = Vector2(rect.size.x - 236, rect.size.y - 236)
	if _map != null:
		_map.position = Vector2(rect.size.x - 236, 84)
	for label: Label in [_time_label, _gap_label, _penalty_label, _damage_label]:
		if label != null:
			label.size = Vector2(300, 40)
			label.position.x = rect.size.x - 24 - 300
	if _countdown_label != null:
		_countdown_label.position = Vector2(rect.size.x * 0.5 - 150, rect.size.y * 0.34)
	if _warning_label != null:
		_warning_label.position = Vector2(rect.size.x * 0.5 - 210, rect.size.y * 0.20)
	if _notice_label != null:
		_notice_label.position = Vector2(rect.size.x * 0.5 - 260, rect.size.y * 0.15)
	if _lap_popup != null:
		_lap_popup.position = Vector2(rect.size.x * 0.5 - 260, rect.size.y * 0.26)
	if _landmark_label != null:
		_landmark_label.position = Vector2(26, rect.size.y - 54)


func _build_pause(root: Control) -> void:
	_pause_panel = Control.new()
	_pause_panel.name = "Pause"
	_pause_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_panel.visible = false
	_pause_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(_pause_panel)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_panel.add_child(dim)

	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 10)
	box.position = Vector2(60, 60)
	_pause_panel.add_child(box)

	var title := Label.new()
	title.text = "PAUSED"
	title.add_theme_font_size_override("font_size", 40)
	box.add_child(title)

	var hint := Label.new()
	hint.text = "Esc resume   C camera   R restart   Q quit to menu"
	hint.add_theme_font_size_override("font_size", 16)
	box.add_child(hint)

	var volume_row := HBoxContainer.new()
	box.add_child(volume_row)
	var volume_label := Label.new()
	volume_label.text = "Volume"
	volume_label.custom_minimum_size = Vector2(90, 0)
	volume_row.add_child(volume_label)
	_volume = HSlider.new()
	_volume.min_value = 0.0
	_volume.max_value = 1.0
	_volume.step = 0.05
	_volume.value = Game.master_volume
	_volume.custom_minimum_size = Vector2(240, 0)
	_volume.value_changed.connect(func(v: float) -> void:
		Game.set_setting("master_volume", v)
		Game.apply_volume())
	volume_row.add_child(_volume)

	var laps_row := HBoxContainer.new()
	box.add_child(laps_row)
	var laps_label := Label.new()
	laps_label.text = "Laps"
	laps_label.custom_minimum_size = Vector2(90, 0)
	laps_row.add_child(laps_label)
	var laps := SpinBox.new()
	laps.min_value = 1
	laps.max_value = 30
	laps.value = Game.laps
	laps.custom_minimum_size = Vector2(120, 0)
	laps.value_changed.connect(func(v: float) -> void:
		Game.set_setting("laps", int(v)))
	laps_row.add_child(laps)


func _build_results(root: Control) -> void:
	_results_panel = Control.new()
	_results_panel.name = "Results"
	_results_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_results_panel.visible = false
	root.add_child(_results_panel)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_results_panel.add_child(dim)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.position = Vector2(70, 70)
	_results_panel.add_child(box)
	var title := Label.new()
	title.name = "Title"
	title.text = "RACE RESULTS"
	title.add_theme_font_size_override("font_size", 38)
	box.add_child(title)
	_results_text = RichTextLabel.new()
	_results_text.bbcode_enabled = true
	_results_text.fit_content = true
	_results_text.custom_minimum_size = Vector2(560, 260)
	_results_text.add_theme_font_size_override("normal_font_size", 18)
	box.add_child(_results_text)
	var hint := Label.new()
	hint.text = "R  race again        Esc  back to the menu"
	hint.add_theme_font_size_override("font_size", 16)
	box.add_child(hint)


# ------------------------------------------------------------------- updating

func _process(delta: float) -> void:
	if manager == null or manager.player == null:
		return
	var player := manager.player
	var tracker: LapTracker = manager.trackers[player]
	_position_label.text = "%d%s" % [manager.player_position(), _ordinal(manager.player_position())]
	_lap_label.text = "LAP %d / %d" % [mini(tracker.lap, tracker.laps_target), tracker.laps_target]
	_time_label.text = LapTracker.format_time(_current_lap(tracker))
	_gap_label.text = "BEST %s" % LapTracker.format_time(tracker.best_lap)
	_order_label.text = _order_text()
	_dial.speed_kmh = player.speed_kmh()
	_dial.max_kmh = player.max_speed * 3.6
	_dial.gear = player.gear
	_dial.boost = player.boost_charge
	_dial.rpm = player.engine_rpm
	_dial.slip = player.clutter()
	# The map needs the circuit once - it derives both the outline it draws and the
	# bounds it draws it in from TrackInfo - and the cars every frame, because they
	# move. Only handing it the cars left it with no outline and no bounds at all,
	# so it drew nothing: not an empty map, no map.
	if _map.info == null:
		_map.setup(manager.info, manager.cars, player)
	_map.cars = manager.cars
	_map.player = player
	_warning_label.visible = player.wrong_way and manager.state == RaceManager.State.RACING
	_update_race_control()

	var counting := manager.state == RaceManager.State.COUNTDOWN
	_countdown_label.visible = counting
	if counting:
		var n := int(ceil(manager.countdown))
		_countdown_label.text = str(maxi(1, n))
	elif _go_timer > 0.0:
		_go_timer -= delta
		_countdown_label.visible = true
		_countdown_label.text = "GO!"
	else:
		_countdown_label.visible = false

	if _popup_timer > 0.0:
		_popup_timer -= delta
		if _popup_timer <= 0.0:
			_lap_popup.visible = false

	_update_landmark(delta, player.global_position)


# Names the building the player is passing, if it has a name.
#
# Polled a few times a second rather than every frame, and held for a couple of
# seconds once it appears: at 160 km/h a landmark's 130 m is gone in three, and
# a caption that tracked the nearest name every frame would flicker between two
# buildings on the same corner rather than read as anything.
func _update_landmark(delta: float, where: Vector3) -> void:
	if _landmark_hold > 0.0:
		_landmark_hold -= delta
	_landmark_poll -= delta
	if _landmark_poll > 0.0:
		return
	_landmark_poll = LANDMARK_POLL

	var city: City = null
	if manager != null and manager.builder != null:
		city = manager.builder.city
	if city == null:
		return
	var found := city.landmark_near(where, LANDMARK_RANGE)
	if found.is_empty():
		if _landmark_hold <= 0.0:
			_landmark_name = ""
			_landmark_label.visible = false
		return
	var title := str(found["name"])
	if title != _landmark_name:
		_landmark_name = title
		_landmark_hold = LANDMARK_HOLD
		_landmark_label.text = "◆  %s" % title
	_landmark_label.visible = true


func _current_lap(tracker: LapTracker) -> float:
	if manager.state == RaceManager.State.RACING:
		return manager.race_time - tracker.lap_start_time
	return tracker.last_lap


func _order_text() -> String:
	var lines := PackedStringArray()
	var shown := 0
	for i in manager.standings.size():
		if shown >= 7:
			break
		var row: Dictionary = manager.standings[i]
		shown += 1
		var mark := ">" if row["is_player"] else " "
		lines.append("%s %d  %-9s %s" % [
			mark, i + 1, str(row["name"]), LapTracker.format_time(row["best"]),
		])
	return "\n".join(lines)


func _ordinal(n: int) -> String:
	match n % 10:
		1:
			return "st" if n % 100 != 11 else "th"
		2:
			return "nd" if n % 100 != 12 else "th"
		3:
			return "rd" if n % 100 != 13 else "th"
		_:
			return "th"


# -------------------------------------------------------------------- signals

func flash_go() -> void:
	_go_timer = 1.1


func show_lap(lap: int, time: float) -> void:
	_lap_popup.text = "LAP %d  %s" % [lap, LapTracker.format_time(time)]
	_lap_popup.visible = true
	_popup_timer = 2.6


func toggle_pause() -> void:
	if results_visible:
		return
	paused = not paused
	_pause_panel.visible = paused
	get_tree().paused = paused


func show_results(results: Array) -> void:
	results_visible = true
	_pause_panel.visible = false
	paused = false
	get_tree().paused = true
	var lines := PackedStringArray()
	lines.append("[table=3][cell]Pos[/cell][cell]Driver[/cell][cell]Best lap[/cell][/table]")
	for row: Dictionary in results:
		var name := str(row["name"])
		if bool(row["is_player"]):
			name = "[color=#5ce87a]%s[/color]" % name
		var best: float = row["best_lap"]
		# What race control did, alongside the lap time, because a result with
		# a penalty in it that does not say so is a result nobody trusts.
		var note := ""
		if bool(row.get("disqualified", false)):
			note = "   [color=#ff6a5a]DSQ[/color]"
		elif float(row.get("penalty", 0.0)) > 0.0:
			note = "   [color=#ffb03c]+%.0fs[/color]" % row["penalty"]
		lines.append("%2d.   %-10s   %s%s" % [
			int(row["position"]), name, LapTracker.format_time(best), note,
		])
	var mine: Dictionary = {}
	for row: Dictionary in results:
		if bool(row["is_player"]):
			mine = row
	var headline := ""
	if not mine.is_empty():
		headline = "\n\nYou finished [b]%d%s[/b]  -  best lap %s" % [
			int(mine["position"]), _ordinal(int(mine["position"])),
			LapTracker.format_time(mine["best_lap"]),
		]
		if bool(mine.get("disqualified", false)):
			headline += "\n[color=#ff6a5a]Disqualified by race control[/color]"
		elif float(mine.get("penalty", 0.0)) > 0.0:
			headline += "\n[color=#ffb03c]%.0f seconds of penalties[/color]" \
				% mine["penalty"]
	if manager != null and manager.rules != null:
		var rulings := manager.rules.summary()
		if not rulings.is_empty():
			headline += "\n\n[color=#9aa4b2]Race control[/color]"
			for line: String in rulings:
				headline += "\n[color=#9aa4b2]  %s[/color]" % line
	_results_text.text = "\n".join(lines) + headline
	_results_panel.visible = true


func _unhandled_input(event: InputEvent) -> void:
	if results_visible:
		if event.is_action_pressed("ui_accept") or event.is_action_pressed("reset_car"):
			manager.restart()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause"):
			manager.to_menu()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("pause"):
		toggle_pause()
		get_viewport().set_input_as_handled()
	elif paused and event.is_action_pressed("reset_car"):
		manager.restart()
		get_viewport().set_input_as_handled()
	elif paused and event is InputEventKey and (event as InputEventKey).physical_keycode == KEY_Q:
		manager.to_menu()
		get_viewport().set_input_as_handled()
