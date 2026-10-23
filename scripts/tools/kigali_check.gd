extends Node
# Drives the game the way a player does, and asserts Kigali is reachable.
#
# Everything else that checks this circuit stops short of the front door: the
# unit suite builds a TrackBuilder directly, the converter check writes track data
# and runs it headless. Neither goes through the menu, which is what the project
# actually starts at - so neither would notice a circuit that exists in TrackData
# and cannot be selected, or a race scene that never gets told which circuit to
# build. This walks the real path: load the menu, step its circuit selector the
# way its own arrows do, press the same call the RACE button calls, and then look
# at the world that comes up.

func _ready() -> void:
	var checks := 0
	var failures: Array[String] = []

	# 1. The menu - the project's own entry point.
	var packed: PackedScene = load("res://scenes/menu.tscn")
	if packed == null:
		print("KIGALI_CHECK=FAIL the menu will not load")
		get_tree().quit(1)
		return
	add_child(packed.instantiate())
	await get_tree().process_frame
	await get_tree().process_frame
	checks += 1
	if TrackData.track_count() < 3:
		failures.append("the game offers %d circuits" % TrackData.track_count())
	else:
		print("  ok    the menu offers %d circuits" % TrackData.track_count())

	# 2. Step the selector to Kigali, using the menu's own control.
	Game.set_setting("track_index", 0)
	_refresh_menu()
	for i in 2:
		_step_menu()
	var shown := _menu_value("track_index")
	checks += 1
	if Game.track_index != 2 or shown != "KIGALI":
		failures.append("stepping to the third circuit gave index %d showing %s"
			% [Game.track_index, shown])
	else:
		print("  ok    stepping the circuit selector twice gives %s" % shown)

	# 3. Press RACE. This is the call the menu's RACE button makes.
	#
	# current_scene is cleared first because the menu runs *inside* this check's
	# own scene: without that, changing to the race scene frees this node and the
	# check dies halfway through, which is a failure that looks like a pass.
	get_tree().current_scene = null
	Game.start_race(Game.track_index)
	var race: Node = null
	for i in 120:
		await get_tree().process_frame
		var candidate := get_tree().current_scene
		if candidate != null and candidate.get_node_or_null("Track") != null:
			race = candidate
			break
	checks += 1
	if race == null:
		failures.append("pressing RACE never brought up a circuit")
	else:
		var definition: Dictionary = race.get("definition")
		if str(definition.get("name", "")) != "KIGALI":
			failures.append("RACE built %s, not KIGALI" % definition.get("name", "?"))
		else:
			print("  ok    RACE builds the Kigali circuit")

	# 4. The world that came up. A circuit that loads but mounts none of its
	#    scenery or roads is a circuit in name only.
	if race != null:
		var track: Node = race.get_node("Track")
		for wanted: String in ["Road", "BarrierWalls", "Terrain", "Buildings"]:
			checks += 1
			if track.get_node_or_null(wanted) == null:
				failures.append("%s was not built" % wanted)
			else:
				print("  ok    %s is in the world" % wanted)
		# The terrain is scenery only: the road has to carry the collision or the
		# cars fall through a 25 m elevation model.
		checks += 1
		var road: Node = track.get_node_or_null("Road")
		if road == null or not (road is StaticBody3D):
			failures.append("the road is not a body, so nothing can be driven on")
		else:
			print("  ok    the road is a StaticBody3D and carries the collision")

	print("\n%d/%d checks hold" % [checks - failures.size(), checks])
	for f: String in failures:
		print("  FAILED: %s" % f)
	print("KIGALI_CHECK=" + ("PASS" if failures.is_empty() else "FAIL"))
	get_tree().quit(0 if failures.is_empty() else 1)


func _menu() -> Node:
	for child in get_children():
		if child.has_method("_step") and child.has_method("_refresh"):
			return child
	return null


func _step_menu() -> void:
	var menu := _menu()
	if menu != null:
		menu._step("track_index", 1, TrackData.track_count())
		menu._refresh()


func _refresh_menu() -> void:
	var menu := _menu()
	if menu != null:
		menu._refresh()


func _menu_value(key: String) -> String:
	var menu := _menu()
	if menu == null:
		return ""
	var values: Dictionary = menu._selector_values
	if not values.has(key):
		return ""
	return str((values[key] as Dictionary)["label"].text)
