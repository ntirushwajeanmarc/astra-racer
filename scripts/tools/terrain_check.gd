extends Node
# Renders the imported terrain on its own and saves one frame.
#
# The terrain asset is met by the engine, so the only honest check of it is a
# frame the engine drew: it is loaded exactly as the game will load it - the
# imported resource, no material override, no camera tricks - and lit plainly
# against a dark background so what the surface is made of is visible in the
# pixels rather than inferred from the file.
#
#   xvfb-run -a godot --path racer scenes/terrain_check.tscn -- --shot=/tmp/t.png

func _ready() -> void:
	var shot := "/tmp/terrain_check.png"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			shot = arg.split("=")[1]

	var packed: PackedScene = load("res://assets/terrain/kigali_terrain.glb")
	if packed == null:
		print("TERRAIN_RENDER=FAIL the terrain would not load")
		get_tree().quit(1)
		return
	var terrain: Node3D = packed.instantiate()
	add_child(terrain)
	# The same repair the game applies when it mounts this asset. Without it
	# the importer's first-material quirk leaves the ground ignoring its own
	# vertex colours and the whole valley renders white - which is exactly the
	# thing this check exists to show, so a check that skipped it was a
	# photograph of a bug that is not in the asset.
	var materials := GltfFix.use_vertex_colours(terrain)
	print("  %d material(s) told to use their vertex colours" % materials)

	# A dark background: the terrain is the only bright thing, so the share of the
	# frame it covers and its colour are both measurable without guessing which
	# pixels are sky.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.04, 0.05, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.62)
	env.ambient_light_energy = 0.35
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 2.0
	sun.rotation_degrees = Vector3(-52.0, 125.0, 0.0)
	add_child(sun)

	var cam := Camera3D.new()
	cam.near = 20.0
	cam.far = 200000.0
	cam.fov = 60.0
	add_child(cam)
	# Framed so the terrain fills the lower frame and the horizon sits in shot: the
	# first attempt sat far enough back that the plane projected to a small diamond
	# and only 18% of the frame was ground.
	cam.global_position = Vector3(-2600.0, 1300.0, -2600.0)
	cam.look_at(Vector3(0.0, 80.0, 0.0), Vector3.UP)
	cam.make_current()

	AudioServer.set_bus_mute(0, true)
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(shot)
	if error == OK:
		print("CAPTURED=%s %dx%d" % [shot, image.get_width(), image.get_height()])
	else:
		print("TERRAIN_RENDER=FAIL could not save (%d)" % error)
	get_tree().quit(0 if error == OK else 1)
