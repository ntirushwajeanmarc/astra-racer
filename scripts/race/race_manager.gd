class_name RaceManager
extends Node3D
# Owns one race: builds the world from the selected circuit, places the grid,
# runs the countdown, tracks every car's laps through LapTracker, keeps the
# running order, and hands the results to the HUD.
#
# The same code runs as a self-test (see --selftest below), with the player's car
# driven by an AI instead of the input devices. That is deliberate: the test
# exercises this file, the physics, the track and the lap logic exactly as a
# player would, rather than a parallel "test build" that could drift.

signal lap_completed(car_name: String, lap: int, time: float)
signal race_finished(results: Array)

const AI_NAMES := ["Vega", "Kestrel", "Nova", "Rook", "Ace", "Iris", "Bolt"]
const AI_COLOURS := ["white", "green", "orange", "white", "green", "orange", "white"]
const COUNTDOWN_FROM := 3.6

enum State { COUNTDOWN, RACING, FINISHED }

var definition: Dictionary = {}
var info: TrackInfo
var builder: TrackBuilder
var skid_marks: SkidMarks
var camera_rig: CameraRig
var hud: RaceHUD
var cars: Array[Car] = []
var player: Car
var trackers := {}
var rules: RaceRules = null
var state := State.COUNTDOWN
var countdown := COUNTDOWN_FROM
var race_time := 0.0
var standings: Array = []
var laps_target := 3

# self-test mode
var selftest := false
var selftest_speed := 4.0
var selftest_limit := 40.0

# Hands the player's car to an AI without any of the rest of the self-test:
# no time scaling, no lap limit, no summary. The benchmark uses it, because a
# frame time measured from a car parked on the grid is a measurement of the one
# view on the lap with the least of the circuit in it. The self-test implies it.
var auto_drive := false

var _standings_timer := 0.0
var _finished_order: Array[Car] = []
var _results: Array = []
var _next_beep := 3
var _selftest_peak_speed := 0.0
var _selftest_start := 0.0
var _selftest_report := 1.0


func _ready() -> void:
	_parse_cmdline()
	definition = TrackData.get_track(Game.track_index)
	if selftest:
		auto_drive = true
	laps_target = 1 if selftest else clampi(int(Game.laps), 1, 30)
	_build_environment()
	_build_track()
	rules = RaceRules.new()
	_build_cars()
	if selftest:
		Engine.time_scale = selftest_speed
		Engine.physics_ticks_per_second = 240
		_selftest_start = Time.get_ticks_msec()
		_selftest_intro()
	else:
		_build_presentation()
	print("[race] %s - %d cars, %d laps%s" % [
		definition["name"], cars.size(), laps_target,
		" (self-test)" if selftest else "",
	])


func _parse_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--selftest":
			selftest = true
		elif arg == "--autodrive":
			auto_drive = true
		elif arg.begins_with("--speed="):
			selftest_speed = maxf(1.0, float(arg.split("=")[1]))
		elif arg.begins_with("--laps="):
			laps_target = maxi(1, int(arg.split("=")[1]))
		elif arg.begins_with("--limit="):
			selftest_limit = maxf(5.0, float(arg.split("=")[1]))
		elif arg.begins_with("--track="):
			Game.track_index = clampi(int(arg.split("=")[1]), 0, TrackData.track_count() - 1)


# ------------------------------------------------------------------ the world

func _build_environment() -> void:
	var world_env := WorldEnvironment.new()
	world_env.name = "Environment"
	world_env.environment = build_environment(definition)
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = definition.get("sun_angle", Vector3(-28, 130, 0))
	sun.light_energy = float(definition.get("sun_energy", 1.2))
	sun.light_color = definition.get("sun_colour", Color(1.0, 0.97, 0.92))
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 330.0
	# Four splits rather than the default two: at 330 m a two-split shadow puts
	# the whole middle distance in one map, and the kerbs and barriers thirty
	# metres ahead - which is the part of the circuit being driven - get the
	# same resolution as a building at the far end of the straight.
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	sun.shadow_normal_bias = 1.4
	add_child(sun)


# The Environment one circuit is raced in. Static and returning the resource
# rather than mounting it, so the test suite can build every circuit's
# environment and read back what it actually got - which is the only way the
# fog trap below is ever caught, because a wall of haze a hundred metres down
# the road is invisible to every headless check in the project.
static func build_environment(definition: Dictionary) -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = build_sky(definition)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = float(definition.get("ambient", 1.0))
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 2.2
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.fog_enabled = true
	env.fog_light_color = definition.get("fog", Color(0.72, 0.68, 0.62))
	# Fog is per circuit because the circuits do not see the same distances. On
	# a 1.5 km parkland loop nothing worth looking at is further off than about
	# 400 m and a dense haze is atmosphere; over Kigali the view is across a
	# valley to a city on the hill opposite, and the same density paints all of
	# it flat beige.
	env.fog_density = float(definition.get("fog_density", 0.0007))
	# And the sky keeps most of its own colour. Left at the default the fog
	# replaces the sky entirely, so the gradient the circuit defines above is
	# thrown away and the horizon and the zenith come out the same paste.
	env.fog_sky_affect = float(definition.get("fog_sky_affect", 0.45))
	# `fog_mode` is deliberately left alone. It defaults to the exponential
	# mode, which is the one `fog_density` belongs to - and assigning it, even
	# the value it already has, resets the density to 1.0 and puts a wall of
	# haze ten metres down the road. FOG_MODE_DEPTH is not what it sounds like
	# either: it ignores the density entirely and fogs linearly between
	# `fog_depth_begin` and `fog_depth_end`, which default to 10 m and 100 m.
	# A little contrast and colour back after the filmic curve, which is built
	# to protect highlights and does it by flattening everything else.
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 1.10
	return env


# The sky, which on a circuit with a drawn panorama is also its ambient light.
#
# A circuit may carry a `sky` panorama built by `tools/make_sky.py`, whose sun
# is drawn at the same angle the DirectionalLight3D above shines from. Where it
# does not, the two-colour procedural gradient the game started with is used,
# which is the right thing behind a parkland loop with a treeline on the
# skyline and the wrong thing over a city on a ridge.
static func build_sky(definition: Dictionary) -> Sky:
	var sky := Sky.new()
	var panorama := str(definition.get("sky", ""))
	if panorama != "" and ResourceLoader.exists(panorama):
		var material := PanoramaSkyMaterial.new()
		material.panorama = load(panorama)
		# The panorama is an ordinary sRGB PNG, so it has to be filtered rather
		# than taken as a raw radiance map, and Godot's own energy multiplier is
		# how a low-dynamic-range sky is made bright enough to light with.
		material.energy_multiplier = float(definition.get("sky_energy", 1.15))
		sky.sky_material = material
		sky.radiance_size = Sky.RADIANCE_SIZE_128
		return sky
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = definition.get("sky_top", Color(0.16, 0.30, 0.62))
	sky_material.sky_horizon_color = definition.get("sky_horizon", Color(0.9, 0.7, 0.5))
	sky_material.ground_horizon_color = (definition.get("sky_horizon", Color(0.9, 0.7, 0.5)) as Color).darkened(0.35)
	sky_material.ground_bottom_color = Color(0.11, 0.13, 0.12)
	sky_material.sun_angle_max = 14.0
	sky_material.sun_curve = 0.12
	sky.sky_material = sky_material
	return sky


func _build_track() -> void:
	builder = TrackBuilder.new()
	builder.name = "Track"
	add_child(builder)
	builder.build(definition)
	info = builder.info
	skid_marks = SkidMarks.new()
	skid_marks.name = "SkidMarks"
	add_child(skid_marks)


func _build_cars() -> void:
	var grid: Array[Transform3D] = builder.start_grid
	var opponents := clampi(int(Game.opponents), 0, 7)
	var total := opponents + 1
	# The player starts at the back of the grid - the arcade convention, and it
	# means the AI has a head start worth chasing.
	var order: Array = []
	for i in opponents:
		order.append({"ai": true, "index": i})
	order.append({"ai": false, "index": -1})

	for slot in total:
		var entry: Dictionary = order[slot]
		var xf: Transform3D = grid[slot % grid.size()]
		var car := Car.new()
		car.name = "Car%d" % slot
		car.is_player = not bool(entry["ai"])
		car.colour = "red" if car.is_player else AI_COLOURS[int(entry["index"]) % AI_COLOURS.size()]
		car.driver_name = "You" if car.is_player else AI_NAMES[int(entry["index"]) % AI_NAMES.size()]
		car.skid_marks = skid_marks
		car.transform = xf
		add_child(car)            # _ready builds the body, using car.skid_marks
		car.track = info
		# Not locked. The grid used to be held until the lights went out, which
		# makes a jump start impossible and so makes the countdown a loading
		# screen with a number on it. The cars are free from the moment they
		# are placed; the AI is told to hold station, and race control books
		# anything that has moved by the time the lights go out - including the
		# player, which is the point.
		car.locked = false
		rules.watch(car)

		var tracker := LapTracker.new()
		tracker.setup(info, laps_target)
		trackers[car] = tracker

		if car.is_player:
			player = car
			if auto_drive:
				var ai := AiDriver.new()
				ai.setup(car, info, 99, 1.0)
				ai.hold = true
				car.driver = ai
			else:
				var player_driver := PlayerDriver.new()
				player_driver.refresh_from_settings()
				car.driver = player_driver
		else:
			var ai := AiDriver.new()
			ai.setup(car, info, int(entry["index"]), float(Game.difficulty))
			ai.hold = true
			car.driver = ai
		cars.append(car)

	# Seed the running order from the grid, so the HUD never reports a position
	# before the first timing tick lands a quarter of a second later.
	_update_standings()


func _build_presentation() -> void:
	camera_rig = CameraRig.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)
	camera_rig.follow(player, clampi(int(Game.camera_mode), 0, 2))
	hud = RaceHUD.new()
	hud.name = "HUD"
	add_child(hud)
	hud.setup(self)


# ----------------------------------------------------------------- the racing

func _physics_process(delta: float) -> void:
	# Race control runs in every state, including the countdown - the countdown
	# is when a jump start happens, and the state after the flag is when a
	# penalty already given still has to be shown.
	rules.step(delta, state == State.RACING)
	match state:
		State.COUNTDOWN:
			countdown -= delta
			_tick_countdown()
			if countdown <= 0.0:
				_start_race()
		State.RACING, State.FINISHED:
			race_time += delta
			_track_laps()
			_standings_timer -= delta
			if _standings_timer <= 0.0:
				_standings_timer = 0.25
				_update_standings()
			if state == State.RACING and player != null and (trackers[player] as LapTracker).finished:
				_finish_race()
			if selftest:
				_selftest_tick()


func _tick_countdown() -> void:
	if selftest:
		return
	if countdown <= float(_next_beep) and _next_beep > 0:
		_next_beep -= 1
		if not selftest:
			Sfx.play("beep_low", -8.0)


func _start_race() -> void:
	state = State.RACING
	rules.start()
	for car in cars:
		if car.driver is AiDriver:
			(car.driver as AiDriver).hold = false
		(trackers[car] as LapTracker).start(race_time)
	if hud != null:
		hud.flash_go()
	if not selftest:
		Sfx.play("beep_high", -6.0)


func _track_laps() -> void:
	for car in cars:
		var tracker: LapTracker = trackers[car]
		var event := tracker.update(info, car.global_position, race_time)
		if event == "lap":
			rules.on_lap(car)
			if car == player and hud != null:
				hud.show_lap(tracker.laps_done, tracker.last_lap)
			if car == player and not selftest:
				Sfx.play("chime", -10.0)
			lap_completed.emit(car.driver_name, tracker.laps_done, tracker.last_lap)
		if tracker.finished and not _finished_order.has(car):
			_finished_order.append(car)


func _update_standings() -> void:
	var rows: Array = []
	for car in cars:
		var tracker: LapTracker = trackers[car]
		var progress := float(tracker.laps_done) * info.length + car.track_s
		if tracker.finished:
			progress += info.length * 100.0
		rows.append({
			"car": car, "name": car.driver_name, "progress": progress,
			"laps": tracker.laps_done, "best": tracker.best_lap,
			"finished": tracker.finished, "is_player": car.is_player,
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["progress"] > b["progress"])
	standings = rows


func player_position() -> int:
	for i in standings.size():
		if standings[i]["is_player"]:
			return i + 1
	return standings.size()


func _finish_race() -> void:
	state = State.FINISHED
	_update_standings()
	_results = []
	var placed: Array = []
	for car in _finished_order:
		placed.append(car)
	for row: Dictionary in standings:
		if not placed.has(row["car"]):
			placed.append(row["car"])
	# A disqualified driver is classified behind everyone who finished, no
	# matter where they crossed the line.
	var running: Array = []
	var excluded: Array = []
	for car: Car in placed:
		var book: RaceRules.Record = rules.record(car)
		if book != null and book.disqualified:
			excluded.append(car)
		else:
			running.append(car)
	placed = running + excluded
	for i in placed.size():
		var car: Car = placed[i]
		var tracker: LapTracker = trackers[car]
		var total := 0.0
		for t: float in tracker.lap_times:
			total += t
		var book: RaceRules.Record = rules.record(car)
		var penalty := 0.0 if book == null else book.penalty
		var out := 0.0 if book == null else (1.0 if book.disqualified else 0.0)
		_results.append({
			"position": i + 1,
			"name": car.driver_name,
			"colour": car.colour,
			"is_player": car.is_player,
			"best_lap": tracker.best_lap,
			# The time that counts is the driving plus what race control added
			# to it. Reporting the two separately as well, because a result a
			# driver cannot see the reason for is not a result.
			"total": total + penalty,
			"driving": total,
			"penalty": penalty,
			"disqualified": out > 0.0,
			"laps": tracker.laps_done,
			"finished": tracker.finished,
			"laps_target": tracker.laps_target,
		})
	Game.report_result({
		"track": definition["name"],
		"results": _results,
		"race_time": race_time,
	})
	race_finished.emit(_results)
	if hud != null:
		hud.show_results(_results)
	if not selftest:
		Sfx.play("chime", -5.0)


# -------------------------------------------------------------- input & flow

func _unhandled_input(event: InputEvent) -> void:
	if selftest or hud == null:
		return
	if event.is_action_pressed("pause"):
		hud.toggle_pause()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("camera_toggle"):
		camera_rig.cycle_mode()
		Game.set_setting("camera_mode", camera_rig.mode)
	elif event.is_action_pressed("reset_car") and player != null:
		# Race control repairs the car off `respawned`, so nothing to do here.
		player.respawn()
	elif event.is_action_pressed("look_back"):
		camera_rig.look_back = true
	elif event.is_action_released("look_back"):
		camera_rig.look_back = false


func restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


func to_menu() -> void:
	get_tree().paused = false
	Game.start_menu()


# ----------------------------------------------------------------- self-test

func _selftest_intro() -> void:
	# Skip the countdown: there is nobody to count down to.
	print("  %s" % builder.debug_report())
	for car in cars:
		print("  grid %-8s %s" % [car.driver_name, str(car.global_position)])
	countdown = 0.0
	_start_race()


func _selftest_tick() -> void:
	if player != null:
		_selftest_peak_speed = maxf(_selftest_peak_speed, player.speed_kmh())
	_selftest_report -= get_physics_process_delta_time()
	if _selftest_report <= 0.0:
		_selftest_report = 4.0
		_print_progress()
		if player != null and race_time < 6.0:
			print("  player: %s" % player.debug_ground_info())
	var elapsed := float(Time.get_ticks_msec() - _selftest_start) / 1000.0
	var all_finished := true
	for car in cars:
		if not (trackers[car] as LapTracker).finished:
			all_finished = false
	if all_finished or elapsed > selftest_limit:
		_finish_race()
		_print_selftest(elapsed)


func _print_progress() -> void:
	var parts := PackedStringArray()
	for car in cars:
		var tracker: LapTracker = trackers[car]
		parts.append("%s s=%.0f v=%.0f y=%.2f laps=%d%s" % [
			car.driver_name, car.track_s, car.speed_kmh(), car.global_position.y,
			tracker.laps_done, "" if car.on_ground else " AIR",
		])
	print("  t=%5.1f  %s" % [race_time, "  |  ".join(parts)])


func _print_selftest(elapsed: float) -> void:
	print("\n=== self-test: %s ===" % definition["name"])
	print("simulated %.1f s of racing in %.1f s wall clock (x%.0f)" % [
		race_time, elapsed, selftest_speed,
	])
	var failures: Array[String] = []
	for row: Dictionary in _results:
		var name := str(row["name"])
		var best: float = row["best_lap"]
		var note := ""
		if bool(row.get("disqualified", false)):
			note = "  DSQ"
		elif float(row.get("penalty", 0.0)) > 0.0:
			note = "  +%.0fs" % row["penalty"]
		print("  %-8s laps=%d/%d best=%s total=%s%s" % [
			name, row["laps"], row["laps_target"],
			LapTracker.format_time(best), LapTracker.format_time(row["total"]),
			note,
		])
		if not bool(row["finished"]):
			failures.append("%s did not finish (%d/%d laps)" % [name, row["laps"], row["laps_target"]])
		if best > 0.0 and best < 15.0:
			failures.append("%s recorded an impossible lap of %.2f s" % [name, best])
	for car in cars:
		var pos := car.global_position
		if is_nan(pos.x) or is_nan(pos.y) or is_nan(pos.z):
			failures.append("%s position is NaN" % car.driver_name)
		var near := info.nearest(pos)
		if absf(near["lateral"]) > info.half_width + 24.0:
			failures.append("%s ended %0.1f m off the road" % [car.driver_name, absf(near["lateral"])])
		if pos.y < info.min_y - 30.0 or pos.y > info.max_y + 60.0:
			failures.append("%s ended at height %.1f" % [car.driver_name, pos.y])
	if _selftest_peak_speed < 40.0:
		failures.append("no car ever exceeded 40 km/h (peak %.1f)" % _selftest_peak_speed)
	print("  peak speed: %.0f km/h" % _selftest_peak_speed)
	var rulings := rules.summary()
	if rulings.is_empty():
		print("  race control: nothing to report")
	else:
		print("  race control:")
		for line: String in rulings:
			print("    %s" % line)
	# The self-test drives the player with an AI, and an AI that cannot get
	# round without being booked is a rules bug, not a driving one. A clean
	# field is the invariant; anything else is worth failing on.
	if rulings.size() > cars.size():
		failures.append("race control made %d rulings against %d cars"
			% [rulings.size(), cars.size()])
	if failures.is_empty():
		print("SELFTEST=PASS")
		get_tree().quit(0)
	else:
		for f: String in failures:
			print("SELFTEST FAIL: %s" % f)
		print("SELFTEST=FAIL")
		get_tree().quit(1)
