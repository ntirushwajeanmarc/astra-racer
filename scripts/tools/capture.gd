extends Node
# Renders the game for a few seconds and saves one frame as a PNG, so the
# visuals can be looked at rather than assumed to be right.
#
# Needs a rendering device, so run it under a display or Xvfb - headless has no
# renderer at all and would save a black frame:
#   xvfb-run -a godot --path . scenes/capture.tscn -- --shot=/tmp/race.png --frames=120

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var shot := "/tmp/astra_racer.png"
	var frames := 24
	var topdown := 0.0
	var only := ""
	var tour := 0
	var at := PackedStringArray()
	var outdir := "/tmp"
	var full := false
	for arg in args:
		if arg.begins_with("--shot="):
			shot = arg.split("=")[1]
		elif arg.begins_with("--frames="):
			frames = maxi(1, int(arg.split("=")[1]))
		elif arg.begins_with("--topdown="):
			topdown = float(arg.split("=")[1])
		elif arg.begins_with("--only="):
			only = arg.split("=")[1]
		elif arg.begins_with("--tour="):
			tour = maxi(1, int(arg.split("=")[1]))
		elif arg.begins_with("--at="):
			# Named places rather than an even sweep: when something is wrong
			# at one stretch of a fourteen-kilometre lap, a tour of twelve
			# frames will not land on it.
			at = arg.split("=")[1].split(",")
		elif arg.begins_with("--outdir="):
			outdir = arg.split("=")[1]
		elif arg == "--full":
			# Keep the shadows and the glow. The economies below exist so a
			# frame can be waited for under llvmpipe; a shot meant to show what
			# the game looks like has to be the game, not the cheap version of
			# it, so it is worth the wait.
			full = true

	var packed: PackedScene = load("res://scenes/race.tscn")
	var race := packed.instantiate()

	# Capture-only economies: under a software renderer (Xvfb + llvmpipe) a
	# full-size, shadowed, glowing frame is far too slow to wait for. `--full`
	# is for a shot taken on a real GPU, where none of that applies.
	if not full:
		DisplayServer.window_set_size(Vector2i(640, 360))
		get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	AudioServer.set_bus_mute(0, true)

	add_child(race)
	if not full:
		var sun := race.get_node_or_null("Sun") as DirectionalLight3D
		if sun != null:
			sun.shadow_enabled = false
		var world_env := race.get_node_or_null("Environment") as WorldEnvironment
		if world_env != null and world_env.environment != null:
			world_env.environment.glow_enabled = false

	# Isolation mode: hide every child of the track except the named one, to see
	# whether a single mesh draws at all without anything else in the way.
	if only != "":
		for child in race.builder.get_children():
			if child is Node3D:
				(child as Node3D).visible = (child.name == only)
		for car in race.cars:
			car.visible = false

	# Optional bird's-eye camera over the start line: the quickest way to check
	# that the road, kerbs, verges and grid are where they should be.
	if topdown > 0.0:
		var cam := Camera3D.new()
		cam.name = "TopDown"
		var origin: Vector3 = race.builder.start_transform.origin
		cam.global_position = origin + Vector3.UP * topdown
		cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		add_child(cam)
		cam.make_current()

	if not at.is_empty():
		for i in 8:
			await get_tree().process_frame
		var marks: Array[float] = []
		for text: String in at:
			marks.append(float(text))
		var shot_count := await _tour(race, marks.size(), outdir, marks)
		print("TOUR_DONE=%d/%d" % [shot_count, marks.size()])
		get_tree().quit(0 if shot_count == marks.size() else 1)
		return

	if tour > 0:
		for i in 8:
			await get_tree().process_frame
		var saved := await _tour(race, tour, outdir)
		print("TOUR_DONE=%d/%d" % [saved, tour])
		get_tree().quit(0 if saved == tour else 1)
		return

	# Let the field get away: the countdown runs for the first 3.6 seconds, and
	# each awaited frame advances the real clock, however slow the software
	# renderer is.
	for i in frames:
		await get_tree().process_frame

	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(shot)
	if error == OK:
		print("CAPTURED=%s %dx%d" % [shot, image.get_width(), image.get_height()])
	else:
		print("CAPTURE FAILED (%d) for %s" % [error, shot])
	get_tree().quit(0 if error == OK else 1)


# A lap's worth of frames from one run. Evaluating how a 14 km circuit looks
# cannot be done from the grid: the start line is one view of it, and the thing
# that goes wrong with generated scenery is that it goes wrong somewhere else.
# `--tour=N` parks a camera at N points spaced evenly round the lap, pointing
# along the racing line, and saves a frame at each. `--at=S1,S2,...` does the
# same at named distances instead, which is how you look at the one stretch of
# a fourteen-kilometre lap that is wrong rather than hoping a sweep lands on
# it.
func _tour(race: Node, count: int, outdir: String, marks: Array[float] = []) -> int:
	var builder = race.builder
	var length: float = builder.info.length
	var cam := Camera3D.new()
	cam.name = "Tour"
	cam.far = 12000.0
	add_child(cam)
	cam.make_current()
	for car in race.cars:
		car.visible = false
	var saved := 0
	for i in count:
		var s: float = marks[i] if i < marks.size() else length * float(i) / float(count)
		var here: Transform3D = builder.get_transform_at(s, 0.0)
		var ahead: Transform3D = builder.get_transform_at(fmod(s + 60.0, length), 0.0)
		cam.global_position = here.origin + Vector3.UP * 6.0 \
			- (ahead.origin - here.origin).normalized() * 14.0
		cam.look_at(ahead.origin + Vector3.UP * 1.5, Vector3.UP)
		for f in 6:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		var path := "%s/tour_%02d.png" % [outdir, i]
		if image.save_png(path) == OK:
			saved += 1
			print("TOUR=%s at %.0f m" % [path, s])
	return saved
