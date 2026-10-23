class_name City
extends Node3D
# Mounts the city `tools/build_city.py` builds, and makes it affordable.
#
# The asset arrives as 185 chunk meshes and 32 collision bodies in one glb. This
# node puts it in the circuit's frame, repairs one thing the importer gets wrong,
# gives every chunk a draw distance, and answers "what am I driving past" for the
# HUD.
#
# Why a node rather than three lines in TrackBuilder: a 28 000-building city has
# a cost that has to be managed frame by frame, and a name for every part of that
# management is worth more than the indirection costs.

const FADE_MARGIN := 220.0

var manifest: Dictionary = {}
var landmarks: Array = []
var chunks := 0
var solid_chunks := 0

var _landmark_positions := PackedVector3Array()


func mount(spec: Dictionary) -> bool:
	var packed: PackedScene = load(str(spec.get("model", "")))
	if packed == null:
		push_warning("City: cannot load %s" % spec.get("model", ""))
		return false
	manifest = _read_json(str(spec.get("manifest", "")))
	_read_landmarks(str(spec.get("landmarks", "")))

	var model: Node3D = packed.instantiate()
	model.name = "Model"
	add_child(model)
	position = spec.get("position", Vector3.ZERO)

	_repair_materials(model)
	_set_draw_distance(model, float(spec.get("draw_distance", 1600.0)))
	_mark_obstacles(model)
	return true


# The city's own collision bodies, onto the OBSTACLE layer.
#
# They arrive from the glTF importer, one StaticBody3D per solid chunk, and each is
# a solid box rather than a thin ribbon - so a wheel ray that catches the top of
# one tells the car the ground is as high as a building. A car must hit a building
# and never stand on one. The top-level scan is the same one `_set_draw_distance`
# above already walks, so it rests on the same thing the importer gives this file.
func _mark_obstacles(model: Node) -> void:
	for child in model.get_children():
		if child is StaticBody3D:
			Layers.mark_obstacle(child as StaticBody3D)


# --------------------------------------------------------------------- repairs

func _repair_materials(model: Node3D) -> void:
	# See GltfFix: one material per file comes back ignoring its vertex colours,
	# and in this city that material renders white.
	GltfFix.use_vertex_colours(model)
	# Weathered sheet metal is not a mirror. Left at the glTF's own metallic
	# value the roofs reflect the sky and the whole city reads as snow from the
	# hillside opposite.
	var seen := {}
	for child in model.get_children():
		if not (child is MeshInstance3D):
			continue
		var mesh: Mesh = (child as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var material := mesh.surface_get_material(s) as StandardMaterial3D
			if material == null or seen.has(material.get_instance_id()):
				continue
			seen[material.get_instance_id()] = true
			if material.resource_name.begins_with("Roof"):
				material.metallic = 0.0


func _set_draw_distance(model: Node3D, distance: float) -> void:
	# Kigali is 6.5 km across and the lap only ever runs through part of it, so
	# most of these chunks are scenery for a hillside three kilometres away. A
	# draw distance a little beyond where the haze closes in removes them from
	# the frame entirely rather than asking the GPU to rasterise a city nobody
	# can see - and because the cut lands inside the fog, it cannot be seen
	# happening.
	for child in model.get_children():
		if child is MeshInstance3D:
			var chunk := child as MeshInstance3D
			chunk.visibility_range_end = distance
			chunk.visibility_range_end_margin = FADE_MARGIN
			chunk.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			chunks += 1
		elif child is StaticBody3D:
			solid_chunks += 1


# ------------------------------------------------------------------- landmarks

func _read_landmarks(path: String) -> void:
	if path == "":
		return
	var parsed := _read_json(path)
	landmarks = parsed.get("landmarks", [])
	# The lookup runs every few frames against the player's position, so the
	# coordinates are unpacked once into a flat array rather than read back out
	# of the dictionaries each time.
	_landmark_positions.resize(landmarks.size())
	for i in landmarks.size():
		var p: Array = (landmarks[i] as Dictionary)["position"]
		_landmark_positions[i] = Vector3(float(p[0]), float(p[1]), float(p[2]))


# The nearest named building to a point, or an empty dictionary if the nearest
# one is further away than `within`. The city knows its own landmarks; the HUD
# only has to ask.
func landmark_near(point: Vector3, within: float) -> Dictionary:
	var best := -1
	var best_distance := within * within
	for i in _landmark_positions.size():
		var offset := _landmark_positions[i] - point
		# Height is ignored: a tower on the hill above the road is not "near" by
		# the only measure that matters, which is whether you are passing it.
		var distance := offset.x * offset.x + offset.z * offset.z
		if distance < best_distance:
			best_distance = distance
			best = i
	if best < 0:
		return {}
	var entry: Dictionary = (landmarks[best] as Dictionary).duplicate()
	entry["distance"] = sqrt(best_distance)
	return entry


func summary() -> String:
	if manifest.is_empty():
		return "%d chunks" % chunks
	return "%d buildings in %d chunks, %d solid, %d named" % [
		manifest.get("buildings", 0), chunks, solid_chunks, landmarks.size()]


func _read_json(path: String) -> Dictionary:
	if path == "":
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return {}
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}
