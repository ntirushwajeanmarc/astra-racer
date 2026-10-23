extends Node
# Measures what a circuit costs to draw, and says whether it is affordable.
#
# The self-test runs headless, where there is no renderer at all, so it can prove
# the race works and can prove nothing whatever about whether it runs. Kigali is
# 28 197 buildings, a 6.5 km elevation model and 11 000 barrier segments, and the
# only honest answer to "is that too much" is a frame time measured while driving
# through it.
#
# It drives the real race scene with the player under AI, samples frame times
# over a window, and reports the mean and the 1% worst - the worst is the number
# that matters, because a race that averages sixty and stutters to twenty in the
# city centre is not a race that runs at sixty.
#
#   godot --path racer scenes/bench.tscn -- --track=2 --seconds=20
#
# Flags: --track=N, --seconds=N, --warmup=N, --budget=MS, --csv=PATH

var _frames: PackedFloat32Array = PackedFloat32Array()
var _warmup := 3.0
var _seconds := 20.0
var _budget := 16.7
var _csv := ""
var _elapsed := 0.0
var _race: Node = null
var _label := ""
var _hide: PackedStringArray = PackedStringArray()


func _ready() -> void:
	var track := 2
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seconds="):
			_seconds = maxf(2.0, float(arg.split("=")[1]))
		elif arg.begins_with("--warmup="):
			_warmup = maxf(0.0, float(arg.split("=")[1]))
		elif arg.begins_with("--budget="):
			_budget = maxf(1.0, float(arg.split("=")[1]))
		elif arg.begins_with("--csv="):
			_csv = arg.split("=")[1]
		elif arg.begins_with("--track="):
			track = int(arg.split("=")[1])
		elif arg.begins_with("--hide="):
			# Attribution: run the same lap with one part of the world switched
			# off and the difference is what that part costs. Guessing which of
			# the road, the barriers and the city is the expensive one is how
			# you end up optimising the cheap one.
			_hide = arg.split("=")[1].split(",")

	Game.track_index = clampi(track, 0, TrackData.track_count() - 1)
	AudioServer.set_bus_mute(0, true)

	# The race is driven, not parked: a stationary car at the grid sees one
	# corner of the city and none of the chunk loading, which is the cheapest
	# frame on the lap and the least worth measuring.
	var packed: PackedScene = load("res://scenes/race.tscn")
	_race = packed.instantiate()
	# Before add_child, because add_child is what runs the race's _ready, and
	# _ready is where the player's driver is chosen. Setting it afterwards
	# leaves the player parked on the grid for the whole benchmark.
	_race.set("auto_drive", true)
	add_child(_race)
	_label = str(TrackData.get_track(Game.track_index)["name"])
	if not _hide.is_empty():
		var builder: Node = _race.get("builder")
		for wanted: String in _hide:
			var node := builder.get_node_or_null(NodePath(wanted.strip_edges()))
			if node is Node3D:
				(node as Node3D).visible = false
				_label += " -" + wanted.strip_edges()
			else:
				push_warning("bench: no node called %s to hide" % wanted)
	print("[bench] %s - %.0f s of frames after %.0f s of warm-up"
		% [_label, _seconds, _warmup])


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < _warmup:
		return
	_frames.append(delta * 1000.0)
	if _elapsed < _warmup + _seconds:
		return
	_report()
	get_tree().quit(0 if _worst_percent() <= _budget * 2.5 else 1)


func _worst_percent() -> float:
	# The mean of the slowest 1% of frames. A single worst frame is usually the
	# frame a resource finished loading on and says nothing about the circuit;
	# the slowest hundredth is the stutter a player actually feels.
	var sorted := _frames.duplicate()
	sorted.sort()
	var count := maxi(1, sorted.size() / 100)
	var total := 0.0
	for i in range(sorted.size() - count, sorted.size()):
		total += sorted[i]
	return total / float(count)


func _report() -> void:
	var sorted := _frames.duplicate()
	sorted.sort()
	var total := 0.0
	for f in sorted:
		total += f
	var mean := total / maxf(1.0, float(sorted.size()))
	var median := sorted[sorted.size() / 2]
	var worst := _worst_percent()

	var drawn := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	var primitives := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var draw_calls := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var video := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)

	print("\n=== bench: %s ===" % _label)
	print("  frames sampled     %d over %.1f s" % [sorted.size(), _seconds])
	print("  mean               %.2f ms  (%.0f fps)" % [mean, 1000.0 / maxf(0.01, mean)])
	print("  median             %.2f ms  (%.0f fps)" % [median, 1000.0 / maxf(0.01, median)])
	print("  worst 1%%           %.2f ms  (%.0f fps)" % [worst, 1000.0 / maxf(0.01, worst)])
	print("  budget             %.2f ms" % _budget)
	print("  objects in frame   %d" % drawn)
	print("  draw calls         %d" % draw_calls)
	print("  primitives         %d" % primitives)
	print("  video memory       %.1f MB" % (float(video) / 1048576.0))
	if _csv != "":
		var f := FileAccess.open(_csv, FileAccess.WRITE)
		if f != null:
			f.store_line("track,mean_ms,median_ms,worst1_ms,objects,draw_calls,primitives,video_mb")
			f.store_line("%s,%.3f,%.3f,%.3f,%d,%d,%d,%.1f" % [
				_label, mean, median, worst, drawn, draw_calls, primitives,
				float(video) / 1048576.0])
	print("BENCH=%s" % ("PASS" if worst <= _budget * 2.5 else "SLOW"))
