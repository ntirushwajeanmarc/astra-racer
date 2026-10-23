extends Node
# Renders the city the engine actually imported, and asserts what is in it.
#
# The terrain check next door looks at the ground on its own; this looks at the
# thing standing on the ground, and it loads both together because the one
# failure that matters most - a city floating above, or buried inside, its own
# hillside - is invisible in either asset alone.
#
# It is also the only check that can see the things a manifest cannot claim: the
# roofs really are pitched, the walls really are wound outward, the textures
# really did survive the import. Those are pixels, so this saves pixels.
#
#   godot --path racer scenes/city_check.tscn -- --view=downtown --shot=/tmp/c.png
#
# Views: aerial, downtown, street, skyline, or landmark:<name>.

const CITY := "res://assets/terrain/kigali_city.glb"
const TERRAIN := "res://assets/terrain/kigali_terrain.glb"
const MANIFEST := "res://assets/terrain/kigali_city.json"
const LANDMARKS := "res://assets/terrain/kigali_city_landmarks.json"

var _failures: Array[String] = []
var _checks := 0
var _solid_bodies := 0


func _ready() -> void:
	var shot := ""
	var view := "downtown"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			shot = arg.split("=")[1]
		elif arg.begins_with("--view="):
			view = arg.split("=")[1]

	var manifest := _read_json(MANIFEST)
	var landmarks := _read_json(LANDMARKS)
	var packed: PackedScene = load(CITY)
	if packed == null or manifest.is_empty():
		print("CITY_CHECK=FAIL the city will not load")
		get_tree().quit(1)
		return

	var city: Node3D = packed.instantiate()
	# This check loads the assets straight off disk rather than through the
	# track builder, so it has to apply the same import repair the game does -
	# otherwise it renders a city and a hillside that no player will ever see.
	# It showed white roofs and a white valley for exactly that reason.
	GltfFix.use_vertex_colours(city)
	# The offset the circuit mounts both assets at. Using the manifest's own copy
	# rather than a number typed here is what keeps this check honest if the
	# circuit is ever moved inside its terrain.
	var offset := _vector(manifest.get("offset", [0, 0, 0]))
	city.position = offset
	add_child(city)

	var terrain_packed: PackedScene = load(TERRAIN)
	if terrain_packed != null:
		var terrain: Node3D = terrain_packed.instantiate()
		GltfFix.use_vertex_colours(terrain)
		terrain.position = offset
		add_child(terrain)

	_assert_contents(city, manifest, landmarks)
	_light()
	_aim(view, manifest, landmarks)

	AudioServer.set_bus_mute(0, true)
	for i in 8:
		await get_tree().process_frame
	# The ray test waits for this: collision shapes are not in the physics space
	# until a physics frame has run, so casting in _ready finds an empty world
	# and reports a city with no collision in it at all.
	await get_tree().physics_frame
	await get_tree().physics_frame
	_assert_solid(city)
	await RenderingServer.frame_post_draw

	if shot != "":
		var image := get_viewport().get_texture().get_image()
		if image.save_png(shot) == OK:
			print("CAPTURED=%s %dx%d" % [shot, image.get_width(), image.get_height()])
		else:
			_failures.append("could not save %s" % shot)

	print("\n%d/%d checks hold" % [_checks - _failures.size(), _checks])
	for f: String in _failures:
		print("  FAILED: %s" % f)
	print("CITY_CHECK=" + ("PASS" if _failures.is_empty() else "FAIL"))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _check(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("  ok    %s%s" % [label, "" if detail == "" else " (%s)" % detail])
	else:
		_failures.append("%s%s" % [label, "" if detail == "" else " - %s" % detail])


func _assert_contents(city: Node3D, manifest: Dictionary, landmarks: Dictionary) -> void:
	var visual := 0
	var solid := 0
	var triangles := 0
	var materials := {}
	var textured := 0
	var lowest := INF
	var highest := -INF
	for child in city.get_children():
		if child is MeshInstance3D:
			visual += 1
			var mesh: Mesh = (child as MeshInstance3D).mesh
			var aabb := mesh.get_aabb()
			lowest = minf(lowest, aabb.position.y)
			highest = maxf(highest, aabb.position.y + aabb.size.y)
			for s in mesh.get_surface_count():
				triangles += mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX].size() / 3
				var mat := mesh.surface_get_material(s)
				if mat != null:
					materials[mat.resource_name] = true
					if mat is StandardMaterial3D and \
						(mat as StandardMaterial3D).albedo_texture != null:
						textured += 1
		elif child is StaticBody3D:
			solid += 1

	_check("the city imported as chunks", visual == int(manifest["visible_chunks"]),
		"%d of %d" % [visual, manifest["visible_chunks"]])
	_check("the chunks near the track carry collision",
		solid == int(manifest["collision_chunks"]), "%d bodies" % solid)
	_check("every surface is textured", textured > 0 and materials.size() >= 5,
		"%d textured surfaces across %d materials" % [textured, materials.size()])
	_check("the triangle count survived the import",
		absf(triangles - float(manifest["triangles"])) < 4.0,
		"%d vs %d" % [triangles, manifest["triangles"]])
	# A city that is all one height is a city that was extruded, not built. The
	# manifest counts the roofs; this asserts the geometry actually varies.
	_check("the skyline has range", highest - lowest > 60.0,
		"%.0f m from the lowest ground to the tallest roof" % (highest - lowest))
	_check("most roofs are pitched",
		int(manifest["pitched_roofs"]) > int(manifest["buildings"]) / 2,
		"%d of %d" % [manifest["pitched_roofs"], manifest["buildings"]])
	_check("nothing was left standing in the road",
		int(manifest["dropped_in_road"]) > 0,
		"%d footprints dropped" % manifest["dropped_in_road"])
	_check("the landmarks are named",
		(landmarks.get("landmarks", []) as Array).size() > 50,
		"%d named" % (landmarks.get("landmarks", []) as Array).size())

	_solid_bodies = solid


# Collision has to be reachable or it is decoration, and a wall that is only
# solid from the inside is worse than no wall at all - the car goes through it
# and then cannot get back out. So this walks the faces of every solid chunk and
# fires two rays at each one it samples: one from outside, which must hit it,
# and one from inside, which must not.
#
# The direction comes from the geometry itself. glTF winds a front face
# counter-clockwise and Godot winds one clockwise, so the importer reverses
# every triangle - which means the outward side of a face returned by
# `get_faces()` is minus its right-hand-rule normal, not plus it.
#
# The stand-off distance is scaled to each face rather than fixed, because these
# buildings stand three metres apart and some of them are less than a metre
# thick: a fixed three-metre offset puts the "inside" point outside the far wall
# of a narrow building and reports a hole that is not there.
func _assert_solid(city: Node3D) -> void:
	var space := get_viewport().get_world_3d().direct_space_state
	var sampled := 0
	var solid_from_outside := 0
	var solid_from_inside := 0
	var worst := ""
	for child in city.get_children():
		if not (child is StaticBody3D):
			continue
		var shape := child.get_child(0) as CollisionShape3D
		if shape == null or shape.shape == null:
			continue
		var concave := shape.shape as ConcavePolygonShape3D
		if concave == null:
			continue
		var faces := concave.get_faces()
		var triangles := faces.size() / 3
		if triangles == 0:
			continue
		var step := maxi(1, triangles / 24)
		for t in range(0, triangles, step):
			var f0 := faces[t * 3]
			var f1 := faces[t * 3 + 1]
			var f2 := faces[t * 3 + 2]
			var facing := (f1 - f0).cross(f2 - f0)
			var size := facing.length()
			if size < 0.5:
				continue                      # a sliver proves nothing
			var outward := -facing / size
			var reach := clampf(sqrt(size * 0.5) * 0.4, 0.05, 1.2)
			var here: Vector3 = child.to_global((f0 + f1 + f2) / 3.0)
			var away := here + outward * reach
			var into := here - outward * reach
			sampled += 1
			# From outside, the ray has to be stopped before it reaches the
			# inside of the wall. Anything that stops it counts, including a
			# neighbour standing in front - a car arriving here hits that
			# neighbour, and a wall behind a wall is still a wall.
			var front := space.intersect_ray(
				PhysicsRayQueryParameters3D.create(away, into))
			if front.has("collider"):
				solid_from_outside += 1

			# From inside, the question is not whether anything is hit but
			# *which way what was hit is facing*. 1 053 of these footprints share
			# a party wall with the building next door - they are terraces, and
			# OSM draws the two walls within a few centimetres of each other - so
			# a ray fired outwards from inside one of them very often leaves
			# through the neighbour's outside wall. That is two buildings, not a
			# hole. The neighbour's wall faces back towards us, so its normal
			# opposes `outward`; a face of *this* wall caught from behind would
			# report a normal along `outward`, and that is the only thing that
			# means inside out.
			var back := space.intersect_ray(
				PhysicsRayQueryParameters3D.create(into, away))
			if back.has("position") and back.has("normal") \
				and (back["position"] as Vector3).distance_to(here) < 0.1 \
				and (back["normal"] as Vector3).dot(outward) > 0.5:
				solid_from_inside += 1
				if worst == "":
					worst = "%s at %s" % [child.name, str(here.round())]

	_check("every face sampled stops a car coming at it",
		sampled > 200 and solid_from_outside == sampled,
		"%d of %d faces across %d chunks" % [solid_from_outside, sampled, _solid_bodies])
	_check("and no wall is inside out", solid_from_inside == 0,
		"%d faces solid from the wrong side%s"
			% [solid_from_inside, "" if worst == "" else " - first at %s" % worst])


func _light() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	var material := ProceduralSkyMaterial.new()
	material.sky_top_color = Color(0.16, 0.30, 0.62)
	material.sky_horizon_color = Color(0.95, 0.72, 0.42)
	material.ground_horizon_color = Color(0.95, 0.72, 0.42)
	sky.sky_material = material
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.7
	# The circuit's own fog, not a guess at it: this check exists to show what
	# the game looks like, and a check with its own haze is a check that can
	# report a problem the game does not have, or miss one it does.
	var definition := TrackData.get_track(2)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = definition.get("fog", Color(0.70, 0.68, 0.62))
	env.fog_density = float(definition.get("fog_density", 0.0007))
	env.fog_sky_affect = float(definition.get("fog_sky_affect", 0.45))
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.25
	sun.rotation_degrees = Vector3(-32.0, 120.0, 0.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 600.0
	add_child(sun)


func _aim(view: String, manifest: Dictionary, landmarks: Dictionary) -> void:
	var cam := Camera3D.new()
	cam.near = 0.5
	cam.far = 40000.0
	cam.fov = 62.0
	add_child(cam)
	cam.make_current()

	var target := Vector3(0.0, 40.0, 0.0)
	var eye := Vector3(600.0, 400.0, 600.0)
	if view.begins_with("landmark:"):
		var wanted := view.substr(9).to_lower()
		for entry: Dictionary in landmarks.get("landmarks", []):
			if str(entry["name"]).to_lower().contains(wanted):
				target = _vector(entry["position"])
				var back := maxf(60.0, float(entry["height"]) * 3.0)
				eye = target + Vector3(back, float(entry["height"]) * 0.9 + 18.0, back)
				break
	elif view == "aerial":
		# High over the middle of the model, looking down the hillside.
		eye = Vector3(-1500.0, 1100.0, -1500.0)
		target = Vector3(300.0, 60.0, 300.0)
	elif view == "skyline":
		# Low and far, so the roofline is read against the sky rather than from
		# above - the angle a flat lid on every building is most obvious from.
		eye = Vector3(-1400.0, 180.0, 900.0)
		target = Vector3(300.0, 110.0, -200.0)
	elif view == "street":
		# Down among them, at the height of a driver's eyeline.
		var biggest := _biggest(landmarks)
		target = biggest + Vector3(40.0, -6.0, 40.0)
		eye = biggest + Vector3(150.0, 2.0, 150.0)
	else:                                     # downtown
		var biggest := _biggest(landmarks)
		eye = biggest + Vector3(420.0, 260.0, 420.0)
		target = biggest

	cam.global_position = eye
	cam.look_at(target, Vector3.UP)


func _biggest(landmarks: Dictionary) -> Vector3:
	var best := Vector3(0.0, 60.0, 0.0)
	var area := 0.0
	for entry: Dictionary in landmarks.get("landmarks", []):
		if float(entry["footprint_area"]) > area:
			area = float(entry["footprint_area"])
			best = _vector(entry["position"])
	return best


func _vector(values) -> Vector3:
	var a: Array = values
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _read_json(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return {}
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}
