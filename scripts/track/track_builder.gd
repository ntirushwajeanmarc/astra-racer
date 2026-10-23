class_name TrackBuilder
extends Node3D
# Builds a whole circuit from a TrackData definition: the road ribbon (asphalt,
# kerbs, verge), its collision, the barrier walls, the scenery, the start gantry
# and the starting grid.
#
# The road is generated rather than tiled from the Kenney pieces on purpose: in
# that kit the road tile is one unit wide and the car is 0.73 units wide, so
# tiled corners can never be wider than about one and a half cars. A generated
# ribbon gives real corner radii, elevation changes and a road wide enough to
# race five cars on - and the kit's models become scenery, which is what they
# are best at.

const SPACING := 2.0                     # metres between centreline samples
const MODEL_DIR := "res://assets/models/"
const KERB_WIDTH := 1.0
const KERB_HEIGHT := 0.075
const CENTRE_LINE_WIDTH := 0.16
const VERGE_WIDTH := 130.0
const WALL_OFFSET := 1.6                 # outside the kerb
const WALL_THICKNESS := 0.55             # a wall a car can be inside of is not a wall
const WALL_HEIGHT := 1.4
const WALL_STAND := 1.0                  # how far it stands proud of a bank
# The Kenney barrier segment measures 0.250 x 0.131 x 0.123 units, long axis
# first, and is placed at this scale: 2.60 m of barrier, 1.36 m tall, 1.28 m
# deep - a segment every 2.6 m, so the line closes.
const BARRIER_SCALE := 10.4
const BARRIER_DEPTH := 0.123 * BARRIER_SCALE
const BARRIER_SPACING := 0.250 * BARRIER_SCALE
const BARRIER_CHUNK := 200.0             # metres of lap per barrier MultiMesh
const BARRIER_DRAW_DISTANCE := 420.0

var info: TrackInfo
var track: Dictionary = {}
var start_grid: Array[Transform3D] = []
var ground_y := 0.0
var start_transform := Transform3D.IDENTITY
var road_faces := 0
var verge_faces := 0
var wall_faces := 0

var _rng := RandomNumberGenerator.new()
var _road_body: StaticBody3D
var _verge_body: StaticBody3D
var terrain_node: Node3D
var _shoulders: Dictionary = {}
var scenery_bodies := 0
var terrain_bodies := 0
var city: City


func build(definition: Dictionary) -> void:
	track = definition
	_rng.seed = 20260918
	var control := TrackData.control_points(track)
	var loop := TrackData.sample_loop(control, SPACING)
	var half_width := float(track.get("half_width", 7.0))
	info = TrackInfo.new()
	info.build_from(loop, half_width, SPACING, float(track.get("start_s", 45.0)))
	info.make_checkpoints(int(track.get("checkpoints", 12)), float(track.get("start_s", 45.0)))

	ground_y = info.min_y - 4.0
	_build_road()
	# A real elevation model replaces the generated verge: that slope is a stand-in
	# for ground the circuit now actually has, and leaving both in puts a fake
	# hillside through the real one. The verge's *collision* stays either way,
	# because the car still needs something to land on if it leaves the road.
	# With a real elevation model in, the generated verge goes entirely - mesh
	# *and* collision. That collision was the reason a car that left the road
	# drove underneath the hillside it could see: it was a slope running from the
	# road edge down to one flat height for the whole circuit, while the ground
	# being drawn was the real one, tens of metres away from it. The terrain now
	# carries its own collision, so it is both what you see and what you land on.
	var terrain: Dictionary = track.get("terrain", {})
	_load_shoulders(terrain)
	_build_verge(terrain.is_empty())
	_build_walls()
	_build_start_line()
	_build_grid()
	_build_scenery()
	start_transform = _transform_at(float(track.get("start_s", 45.0)), 0.0)
	if not terrain.is_empty():
		_build_scenery_model(terrain, "Terrain")
	var buildings: Dictionary = track.get("buildings", {})
	if not buildings.is_empty():
		city = City.new()
		city.name = "Buildings"
		if city.mount(buildings):
			add_child(city)
			print("[track] city: %s" % city.summary())
		else:
			city = null


func _build_scenery_model(spec: Dictionary, node_name: String) -> void:
	# A prebuilt model dropped into the circuit's own frame - the elevation model,
	# or the city that stands on it. Visual only: a 25 m elevation model is far too
	# coarse to drive on, so the road ribbon keeps the collision and these are the
	# view. Both are placed at the same offset because they were built in one
	# frame, which is what stops the city floating above its own hillside.
	var packed: PackedScene = load(str(spec.get("model", "")))
	if packed == null:
		push_warning("TrackBuilder: cannot load %s" % spec.get("model", ""))
		return
	var node: Node3D = packed.instantiate()
	node.name = node_name
	node.position = spec.get("position", Vector3.ZERO)
	add_child(node)
	if node_name == "Terrain":
		terrain_node = node
		_dress_terrain(node)



# The ground the importer just built, made into ground the game understands.
#
# Three things have to be said about it that the glb cannot carry.
#
# Its material has to be told to use its vertex colours - see GltfFix. The
# ground has exactly one material, so it is always the one the importer drops
# the flag on, and without this the whole valley renders white.
#
# Its bodies are grass, not tarmac. The car reads `surface` off whatever its
# wheel rays hit and defaults to "road", so an unlabelled hillside would have
# the grip of the racing line.
#
# And it casts no shadow: a 30 m elevation model has no feature small enough to
# throw a shadow worth seeing inside the 330 m the directional light reaches, so
# casting only buys a second pass over the largest mesh on the circuit.
func _dress_terrain(node: Node3D) -> void:
	terrain_bodies = 0
	GltfFix.use_vertex_colours(node)
	for child in node.get_children():
		if child is GeometryInstance3D:
			(child as GeometryInstance3D).cast_shadow = \
				GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_filter_anisotropically(child as GeometryInstance3D)
		for sub in child.get_children():
			if sub is StaticBody3D:
				(sub as StaticBody3D).set_meta("surface", "grass")
				terrain_bodies += 1
		if child is StaticBody3D:
			(child as StaticBody3D).set_meta("surface", "grass")
			terrain_bodies += 1


# The ground is the one surface in the game seen almost entirely edge-on, and
# a tiled detail texture viewed at a grazing angle is where trilinear filtering
# gives up: the tiles a hundred metres ahead fall between mip levels and crawl
# as a moire pattern across the whole valley. Anisotropic filtering is the
# answer to exactly that case, and this is the only mesh that needs it.
func _filter_anisotropically(node: GeometryInstance3D) -> void:
	var mesh: Mesh = (node as MeshInstance3D).mesh if node is MeshInstance3D else null
	if mesh == null:
		return
	for i in mesh.get_surface_count():
		var material := mesh.surface_get_material(i) as BaseMaterial3D
		if material != null:
			material.texture_filter = \
				BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC


# --------------------------------------------------------------- cross-sections

func _surface_normal(i: int) -> Vector3:
	var n := info.rights[i].cross(info.tangents[i]).normalized()
	if n.y < 0.0:
		n = -n
	return n


func _point(i: int, lateral: float, height: float) -> Vector3:
	return info.points[i] + info.rights[i] * lateral + _surface_normal(i) * height


func _flat_point(i: int, lateral: float, y_absolute: float) -> Vector3:
	var p := info.points[i] + info.rights[i] * lateral
	return Vector3(p.x, y_absolute, p.z)


# ------------------------------------------------------------------------ road

func _build_road() -> void:
	var hw := info.half_width
	# Lateral bands, inner edge first, then the colour each one is painted.
	var bands: Array = [
		{"from": -hw - KERB_WIDTH, "to": -hw, "kind": "kerb", "h0": KERB_HEIGHT, "h1": 0.0},
		{"from": -hw, "to": hw, "kind": "asphalt", "h0": 0.0, "h1": 0.0},
		{"from": hw, "to": hw + KERB_WIDTH, "kind": "kerb", "h0": 0.0, "h1": KERB_HEIGHT},
		{"from": -CENTRE_LINE_WIDTH, "to": CENTRE_LINE_WIDTH, "kind": "centre", "h0": 0.012, "h1": 0.012},
	]

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()
	var faces := PackedVector3Array()
	for band: Dictionary in bands:
		for i in info.count:
			var j := (i + 1) % info.count
			var a := _point(i, band["from"], band["h0"])
			var b := _point(i, band["to"], band["h1"])
			var c := _point(j, band["to"], band["h1"])
			var d := _point(j, band["from"], band["h0"])
			var colour := _band_colour(band["kind"], i)
			var n := _surface_normal(i)
			_append_quad(verts, normals, colours, indices, a, b, c, d, n,
				colour, colour, colour, colour)
			if band["kind"] != "centre":
				faces.append(a)
				faces.append(b)
				faces.append(c)
				faces.append(a)
				faces.append(c)
				faces.append(d)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color.WHITE
	material.roughness = 0.94
	material.metallic = 0.0
	var mesh := _make_mesh(verts, normals, colours, indices, material)

	_road_body = StaticBody3D.new()
	_road_body.name = "Road"
	_road_body.set_meta("surface", "road")
	var mi := MeshInstance3D.new()
	mi.name = "RoadMesh"
	mi.mesh = mesh
	_road_body.add_child(mi)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	# Two-sided: a surface that can only be hit from above is a surface a car that
	# spawns a millimetre low will fall straight through and never come back from.
	shape.backface_collision = true
	road_faces = faces.size() / 3
	var cs := CollisionShape3D.new()
	cs.shape = shape
	_road_body.add_child(cs)
	add_child(_road_body)


func debug_report() -> String:
	var parts := PackedStringArray()
	parts.append("samples=%d length=%.0fm half_width=%.1f ground_y=%.1f grid=%d checkpoints=%d" % [
		info.count, info.length, info.half_width, ground_y, start_grid.size(),
		info.checkpoint_indices.size(),
	])
	for child in get_children():
		if child is StaticBody3D:
			parts.append("%s: %s" % [(child as Node).name, _shape_bounds(child)])
	return "\n  ".join(parts)


func _shape_bounds(body: Node) -> String:
	for c in body.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is ConcavePolygonShape3D:
			var faces: PackedVector3Array = ((c as CollisionShape3D).shape as ConcavePolygonShape3D).get_faces()
			if faces.is_empty():
				return "EMPTY SHAPE"
			var box := AABB(faces[0], Vector3.ZERO)
			for v: Vector3 in faces:
				box = box.expand(v)
			return "x[%.1f..%.1f] y[%.1f..%.1f] z[%.1f..%.1f] tris=%d" % [
				box.position.x, box.position.x + box.size.x,
				box.position.y, box.position.y + box.size.y,
				box.position.z, box.position.z + box.size.z,
				faces.size() / 3,
			]
	return "no concave shape"


func _band_colour(kind: String, i: int) -> Color:
	match kind:
		"kerb":
			var red := int(floor(float(i) * SPACING / 3.0)) % 2 == 0
			return Color(0.72, 0.09, 0.07) if red else Color(0.90, 0.90, 0.88)
		"centre":
			return Color(0.82, 0.82, 0.80) if (i % 4) < 2 else Color(0.17, 0.17, 0.18)
		_:
			var shade := 0.155 + 0.012 * float(i % 7) / 7.0
			return Color(shade, shade, shade * 1.05)


# Appends one quad (two triangles) to explicit mesh arrays. Building the arrays
# by hand rather than through SurfaceTool: the SurfaceTool-built surfaces of this
# track would not draw at all, while every other mesh in the scene did.
func _append_quad(verts: PackedVector3Array, normals: PackedVector3Array,
		colours: PackedColorArray, indices: PackedInt32Array,
		a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3,
		ca: Color, cb: Color, cc: Color, cd: Color) -> void:
	var base := verts.size()
	verts.append(a)
	verts.append(b)
	verts.append(c)
	verts.append(d)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	colours.append(ca)
	colours.append(cb)
	colours.append(cc)
	colours.append(cd)
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 1)
	indices.append(base)
	indices.append(base + 3)
	indices.append(base + 2)


func _make_mesh(verts: PackedVector3Array, normals: PackedVector3Array,
		colours: PackedColorArray, indices: PackedInt32Array, material: Material) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


# ----------------------------------------------------------------------- verge

func _build_verge(draw_surface: bool = true) -> void:
	# `draw_surface` is false exactly when a terrain model is providing the
	# ground, and in that case there is nothing for this to build at all.
	if not draw_surface:
		return
	var hw := info.half_width + KERB_WIDTH
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()
	var faces := PackedVector3Array()
	for side: float in [-1.0, 1.0]:
		var inner := side * hw
		var outer := side * (hw + VERGE_WIDTH)
		for i in info.count:
			var j := (i + 1) % info.count
			var a := _point(i, inner, 0.0)
			var b := _flat_point(i, outer, ground_y)
			var c := _flat_point(j, outer, ground_y)
			var d := _point(j, inner, 0.0)
			var n := _surface_normal(i).lerp(Vector3.UP, 0.75).normalized()
			var col := Color(0.20 + 0.03 * float(i % 5) / 5.0, 0.38 + 0.04 * float(i % 3) / 3.0, 0.16)
			var far := col.darkened(0.25)
			# Inner edge bright, outer edge darker: the slope reads as distance.
			_append_quad(verts, normals, colours, indices, a, b, c, d, n, col, far, far, col)
			var mid_i := a.lerp(b, 0.55)
			var mid_j := d.lerp(c, 0.55)
			faces.append(a)
			faces.append(mid_i)
			faces.append(mid_j)
			faces.append(a)
			faces.append(mid_j)
			faces.append(d)
			faces.append(mid_i)
			faces.append(b)
			faces.append(c)
			faces.append(mid_i)
			faces.append(c)
			faces.append(mid_j)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color.WHITE
	material.roughness = 1.0
	var mesh := _make_mesh(verts, normals, colours, indices, material)

	_verge_body = StaticBody3D.new()
	_verge_body.name = "Verge"
	_verge_body.set_meta("surface", "grass")
	if draw_surface:
		var mi := MeshInstance3D.new()
		mi.name = "VergeMesh"
		mi.mesh = mesh
		_verge_body.add_child(mi)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	verge_faces = faces.size() / 3
	var cs := CollisionShape3D.new()
	cs.shape = shape
	_verge_body.add_child(cs)
	add_child(_verge_body)

	# The distant ground plane, so the horizon is not a void. Skipped when a
	# terrain model is in: it would slice through the real hills, and the fog is
	# dense enough that the model's own edge is out of sight anyway.
	if not draw_surface:
		return
	var plane := PlaneMesh.new()
	plane.size = Vector2(6000, 6000)
	var plane_mi := MeshInstance3D.new()
	plane_mi.name = "Horizon"
	plane_mi.mesh = plane
	var plane_mat := StandardMaterial3D.new()
	plane_mat.albedo_color = Color(0.17, 0.31, 0.14)
	plane_mat.roughness = 1.0
	plane_mi.material_override = plane_mat
	plane_mi.position = Vector3(info.points[0].x, ground_y - 0.05, info.points[0].z)
	add_child(plane_mi)


# ----------------------------------------------------------------------- walls

# The lateral distance from the centreline to the face of the barrier a car
# meets from the road. Everything that places or tests the wall uses this, so the
# collision, the barrier models and the tests cannot drift apart.
func wall_face_lateral() -> float:
	return info.half_width + KERB_WIDTH + WALL_OFFSET


# How tall the barrier has to be at one sample, on one side.
#
# Normally WALL_HEIGHT: a 1.4 m ribbon standing on the tarmac, which is a
# barrier because the ground outside it is the same height as the road.
#
# Where it is not, it is not a barrier. On the Kigali lap the circuit runs back
# alongside itself for half a kilometre, twenty metres away and three metres
# higher, and the elevation model has to bank the ground between the two roads
# up to one of them - so beside the lower road that bank climbs over the top of
# its barrier at about one in seven. A car drove off the tarmac, up its own
# shoulder, over its own barrier, and into the oncoming road. Nothing caught
# it: the ground was continuous, the road was clear of it, and the one place
# the barrier was ever driven into was a quarter of the way round the lap.
#
# The ground cannot be reshaped out of the way - the elevation model's step is
# 12.5 m and the barrier stands at 7.6 m, so the whole shoulder is inside one
# cell of it and carving there pulls the support out from under the road. So
# the barrier grows instead, to stand `WALL_STAND` proud of whatever the ground
# beside it does. Where that happens it ends up buried in a bank the player can
# see, which is the right way round: the car is stopped by a hillside that is
# visibly there, rather than passing through one that is.
# The public form, by distance along the lap: the checks need to know how tall
# the barrier is somewhere in order to ask whether the ground beside it is
# taller, and reaching into a private helper to find out is how a test ends up
# testing its own copy of the answer.
func wall_height_at_distance(s: float, side: float) -> float:
	return _wall_height_at(info.index_at(s), side)


func _wall_height_at(i: int, side: float) -> float:
	if _shoulders.is_empty():
		return WALL_HEIGHT
	var key := "right" if side > 0.0 else "left"
	var profile: Array = _shoulders.get(key, [])
	if profile.is_empty():
		return WALL_HEIGHT
	# The profile is sampled at the spacing the circuit is resampled at, so the
	# indices line up - but it is looked up by distance along the lap rather
	# than by index, so a profile built at a different spacing still lands in
	# the right place instead of silently sliding round the circuit.
	var s := float(i) * info.spacing / float(_shoulders.get("spacing", info.spacing))
	var k := clampi(int(round(s)), 0, profile.size() - 1)
	return maxf(WALL_HEIGHT, float(profile[k]) + WALL_STAND)


# The shoulder profile written by tools/build_terrain.py: how far the ground
# stands above the road just outside the barrier, at every sample of the lap.
func _load_shoulders(spec: Dictionary) -> void:
	_shoulders = {}
	var path := str(spec.get("shoulders", ""))
	if path == "" or not ResourceLoader.exists(path):
		return
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		_shoulders = parsed


func _build_walls() -> void:
	# A closed ribbon - inner face, outer face, top, bottom - every face wound so
	# that it faces *outward*, with no mesh: collision only.
	#
	# The winding is derived from the direction each face is supposed to face
	# rather than written by hand. It used to be written by hand, and every face of
	# the ribbon came out pointing the same way in world space: correct for the
	# left-hand barrier, backwards for the right-hand one. A concave shape only
	# collides along its face normals, so the right-hand barrier presented its back
	# to the road and a car drove a whole car length into it before the outboard
	# face stopped it. Deriving the winding makes that class of mistake impossible.
	var faces := PackedVector3Array()
	for side: float in [-1.0, 1.0]:
		var inner_l := side * wall_face_lateral()
		var outer_l := inner_l + side * WALL_THICKNESS
		for i in info.count:
			var j := (i + 1) % info.count
			var inward := -side * info.rights[i]     # from the wall towards the road
			var inner_a := _point(i, inner_l, 0.0)
			var inner_b := _point(j, inner_l, 0.0)
			var outer_a := _point(i, outer_l, 0.0)
			var outer_b := _point(j, outer_l, 0.0)
			var rise_a := Vector3.UP * _wall_height_at(i, side)
			var rise_b := Vector3.UP * _wall_height_at(j, side)
			_wall_quad(faces, inner_a, inner_a + rise_a, inner_b + rise_b, inner_b, inward)
			_wall_quad(faces, outer_a, outer_a + rise_a, outer_b + rise_b, outer_b, -inward)
			_wall_quad(faces, inner_a + rise_a, outer_a + rise_a, outer_b + rise_b, inner_b + rise_b, Vector3.UP)
			_wall_quad(faces, inner_a, outer_a, outer_b, inner_b, Vector3.DOWN)

	var body := StaticBody3D.new()
	body.name = "BarrierWalls"
	body.set_meta("surface", "wall")
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	# The winding above is already right; this also makes the barrier solid from
	# the outside, for a car that has been launched over it or dropped in from
	# above.
	shape.backface_collision = true
	wall_faces = faces.size() / 3
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)
	# On OBSTACLE and not on the world. A car hits this; nothing may stand on it.
	# Its top face is 1.4 m above the road, and a car that takes its ride height
	# off that face ends up balanced on the barrier with a wheel down either side.
	# See scripts/core/layers.gd.
	Layers.mark_obstacle(body)

	# Decorative barriers, in MultiMeshes chunked along the lap.
	#
	# One MultiMesh for the whole circuit is the obvious way to build this and it
	# is what this used to do. It is also the single most expensive thing on the
	# Kigali circuit: a MultiMesh is culled as one object against one bounding
	# box, so a 14.4 km lap of them means 11 000 barrier segments - 1.5 million
	# triangles, over half of everything in the frame - drawn every frame no
	# matter which way the car is pointing. Chunked into BARRIER_CHUNK-metre
	# runs, each chunk gets its own box and all but a handful are culled.
	var placements := {}
	for side: float in [-1.0, 1.0]:
		# Sit the segment's inner face flush against the collision wall's, so the
		# barrier a car can see and the barrier it hits are the same barrier.
		# Offsetting by the model's own half depth keeps that true if the scale
		# below ever changes.
		var offset := side * (wall_face_lateral() + BARRIER_DEPTH * 0.5)
		var s := 0.0
		while s < info.length:
			var i := info.index_at(s)
			var t := _transform_at(s, offset)
			# The segment's long axis is its *local X*, and `_transform_at` puts
			# local X across the track - so it has to be turned a quarter turn
			# first or it is laid broadside on: 2.6 m of barrier reaching out
			# into the verge, 1.3 m of it along the track, and a 1.3 m gap to
			# the next one. Turned, segments on BARRIER_SPACING close into the
			# continuous line the collision wall behind them already is.
			var basis := t.basis.rotated(t.basis.y.normalized(), PI * 0.5) \
				.scaled(Vector3(BARRIER_SCALE, BARRIER_SCALE, BARRIER_SCALE))
			var xform := Transform3D(basis, t.origin)
			var period := int(floor(s / BARRIER_SPACING))
			var colour := "red" if period % 2 == 0 else "white"
			var key := "%s_%03d" % [colour, int(s / BARRIER_CHUNK)]
			if not placements.has(key):
				placements[key] = []
			(placements[key] as Array).append(xform)
			s += BARRIER_SPACING

	var barriers := Node3D.new()
	barriers.name = "Barriers"
	add_child(barriers)
	for key: String in placements:
		var colour: String = key.split("_")[0]
		var node := _multimesh(MODEL_DIR + "barrier" + colour.capitalize() + ".glb",
			placements[key], "Barrier" + key.capitalize())
		if node == null:
			continue
		# A barrier is knee high and half a metre of it fills a pixel at 400 m,
		# so there is nothing to see past that - and it casts no shadow, because
		# a shadow from something knee high beside a road nobody is looking at
		# is a second pass over 1.5 million triangles for no picture at all.
		#
		# The cut is hard, not faded. A faded visibility range is dithered, and
		# dithering puts the material in the transparent pass - which for a
		# kilometre of knee-high strips seen almost edge on is enormous overdraw
		# with no depth prepass to stop it. Measured, that alone took the frame
		# from 22 ms to 133. At 420 m through this fog the pop cannot be seen.
		node.visibility_range_end = BARRIER_DRAW_DISTANCE
		node.visibility_range_end_margin = 0.0
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		barriers.add_child(node)


# Appends one quad as two triangles, wound so the side it collides from is the
# side `outward` points to. Godot's plane normal for the triangle (p1, p2, p3) is
# (p1 - p3) x (p1 - p2), and a concave shape only collides along that normal, so
# the order the four corners are listed in is what decides which side is solid.
func _wall_quad(faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		outward: Vector3) -> void:
	# (b - a) x (c - a) is the negation of the triangle's own normal, hence the
	# inverted test: negative dot means (a, b, c) already faces outward.
	if (b - a).cross(c - a).dot(outward) < 0.0:
		faces.append(a)
		faces.append(b)
		faces.append(c)
		faces.append(a)
		faces.append(c)
		faces.append(d)
	else:
		faces.append(a)
		faces.append(c)
		faces.append(b)
		faces.append(a)
		faces.append(d)
		faces.append(c)


# ------------------------------------------------------- helpers for placement

# The public form of `_transform_at`. The checks outside this file need to ask
# the circuit where a point on it is - to drop a car beside the road, or to aim
# one at a barrier - and reaching into a private helper to do it is how a test
# ends up asserting something the game never does.
func get_transform_at(s: float, lateral: float) -> Transform3D:
	return _transform_at(s, lateral)


func _transform_at(s: float, lateral: float) -> Transform3D:
	var sample := info.point_at(s)
	var pos: Vector3 = sample["position"]
	var tangent: Vector3 = sample["tangent"]
	var right: Vector3 = sample["right"]
	var up := right.cross(tangent).normalized()
	if up.y < 0.0:
		up = -up
	pos += right * lateral
	return Transform3D(Basis(right, up, -tangent), pos)


func _multimesh(model_path: String, transforms: Array, node_name: String,
		solid := "") -> MultiMeshInstance3D:
	if transforms.is_empty():
		return null
	var packed: PackedScene = load(model_path)
	if packed == null:
		push_warning("TrackBuilder: cannot load %s" % model_path)
		return null
	var inst: Node3D = packed.instantiate()
	var mesh: Mesh = null
	var mesh_xform := Transform3D.IDENTITY
	var stack: Array = [inst]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			mesh = (n as MeshInstance3D).mesh
			mesh_xform = _relative_transform(inst, n)
			break
		for c in n.get_children():
			stack.append(c)
	var offset := Transform3D.IDENTITY
	if mesh != null:
		var box: AABB = mesh_xform * mesh.get_aabb()
		# Sit the model on the ground and centre its footprint on the transform.
		offset = Transform3D(Basis.IDENTITY, Vector3(-box.get_center().x, -box.position.y, -box.get_center().z))
	inst.free()
	if mesh == null:
		return null

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, (transforms[i] as Transform3D) * offset)
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = mm
	if solid != "":
		_make_solid(transforms, offset, mesh_xform * mesh.get_aabb(), solid,
			node_name)
	return node


func _relative_transform(root: Node3D, target: Node) -> Transform3D:
	var chain: Array = []
	var n: Node = target
	while n != null and n != root:
		chain.append(n)
		n = n.get_parent()
	var xf := Transform3D.IDENTITY
	for i in range(chain.size() - 1, -1, -1):
		xf = xf * (chain[i] as Node3D).transform
	return xf


# ---------------------------------------------------------------- start line

func _build_start_line() -> void:
	var start_s := float(track.get("start_s", 45.0))
	var t := _transform_at(start_s, 0.0)

	# Gantry: the kit's start piece, scaled to straddle the road.
	var gantry_node := _multimesh(MODEL_DIR + "roadStart.glb", [t], "StartGantry")
	if gantry_node != null:
		var mm := gantry_node.multimesh
		mm.set_instance_transform(0, t * Transform3D(Basis.IDENTITY.scaled(Vector3(1.0, 1.0, 1.0)), Vector3.ZERO))
		gantry_node.scale = Vector3(1.05 * info.half_width, 5.4, 1.4)
		add_child(gantry_node)

	# Grid markings on the road from the kit's start-positions piece.
	var ground := _transform_at(start_s - 16.0, 0.0)
	var grid_node := _multimesh(MODEL_DIR + "roadStartPositions.glb", [ground], "GridMarkings")
	if grid_node != null:
		grid_node.scale = Vector3(1.0 * info.half_width, 1.0, 4.0)
		add_child(grid_node)

	# Checkered flag poles either side of the line.
	var flags: Array = []
	for side: float in [-1.0, 1.0]:
		flags.append(_transform_at(start_s, side * (info.half_width + 1.2)))
	var flag_node := _multimesh(MODEL_DIR + "flagCheckers.glb", flags, "StartFlags")
	if flag_node != null:
		flag_node.scale = Vector3(6.0, 6.0, 6.0)
		add_child(flag_node)


func _build_grid() -> void:
	start_grid.clear()
	var start_s := float(track.get("start_s", 45.0))
	var rows := 4
	for row in rows:
		for side: float in [-1.0, 1.0]:
			var s := start_s - 14.0 - float(row) * 9.0
			var lateral := side * info.half_width * 0.34
			var slot := _transform_at(s, lateral)
			# Drop the grid in from just above the road: spawning exactly on the
			# surface leaves every car a hair inside it.
			slot.origin += Vector3.UP * 0.6
			start_grid.append(slot)


# -------------------------------------------------------------------- scenery

func _build_scenery() -> void:
	# Roadside scenery, laid out from the circuit's own `scenery` block. The
	# defaults below are the parkland a purpose-built track sits in: trees out to
	# forty metres, pylons down the straights, grandstands every hundred or so.
	#
	# A street circuit is not that. Kigali overrides these because the thing
	# beside its road is a city, and fourteen grandstands and a forest scattered
	# through it look exactly like what they are - the furniture of a different
	# track left standing in someone's street. What that circuit keeps is a thin
	# line of street trees inside the corridor cleared for the road, and a
	# grandstand at the start line, where a real street race puts one.
	var scenery: Dictionary = track.get("scenery", {})
	var tree_chance := float(scenery.get("tree_chance", 0.34))
	var tree_offset: Vector2 = scenery.get("tree_offset", Vector2(6.0, 40.0))
	var tree_scale: Vector2 = scenery.get("tree_scale", Vector2(8.0, 13.0))
	var tree_large_share := float(scenery.get("tree_large_share", 0.45))
	var grandstand_limit := int(scenery.get("grandstands", 14))
	var grandstand_near_start := float(scenery.get("grandstand_near_start", 0.0))
	var want_pylons := bool(scenery.get("pylons", true))
	var want_lamps := bool(scenery.get("lamps", true))

	var hw := info.half_width + KERB_WIDTH + WALL_OFFSET
	var trees_large: Array = []
	var trees_small: Array = []
	var pylons: Array = []
	var lamps: Array = []
	var seats: Array = []

	var s := 0.0
	while s < info.length:
		var i := info.index_at(s)
		var curvature := absf(info.curvature[i])
		for side: float in [-1.0, 1.0]:
			var roll := _rng.randf()
			var offset := hw + tree_offset.x + _rng.randf() * maxf(0.0, tree_offset.y - tree_offset.x)
			if roll < tree_chance:
				var t := _transform_at(s + _rng.randf() * 3.0, side * offset)
				var scale := tree_scale.x + _rng.randf() * maxf(0.0, tree_scale.y - tree_scale.x)
				var xf := Transform3D(t.basis.scaled(Vector3(scale, scale, scale)), t.origin)
				if _clear_of_the_circuit(t.origin):
					if _rng.randf() < tree_large_share:
						trees_large.append(xf)
					else:
						trees_small.append(xf)
		# Pylons run along the straights, lamp posts and grandstands appear where
		# the track is straighter - the scenery follows the corners.
		if want_pylons and curvature < 0.006 and fmod(s, 26.0) < SPACING:
			var side := -1.0 if fmod(s, 52.0) < 26.0 else 1.0
			var t := _transform_at(s, side * (hw + 3.4))
			if _clear_of_the_circuit(t.origin):
				pylons.append(Transform3D(t.basis.scaled(Vector3(9.0, 9.0, 9.0)), t.origin))
		if want_lamps and curvature < 0.005 and fmod(s, 64.0) < SPACING:
			var t := _transform_at(s, -(hw + 5.0))
			if _clear_of_the_circuit(t.origin):
				lamps.append(Transform3D(t.basis.scaled(Vector3(6.0, 6.0, 6.0)), t.origin))
		if curvature < 0.004 and fmod(s, 118.0) < SPACING and seats.size() < grandstand_limit \
				and _near_start(s, grandstand_near_start):
			var t := _transform_at(s, -(hw + float(scenery.get("grandstand_offset", 22.0))))
			var basis := t.basis.rotated(Vector3.UP, PI * 0.5).scaled(Vector3(15.0, 15.0, 15.0))
			if _clear_of_the_circuit(t.origin):
				seats.append(Transform3D(basis, t.origin))
		s += 11.0

	# `solid` is what the scenery is made of as far as a car is concerned.
	#
	# All of this used to be decoration and nothing else: a MultiMesh draws, and
	# that is all it does. So a car drove through a tree, through a lamp post
	# and through a grandstand without so much as a scrape - which on a circuit
	# with a line of street trees down both sides is the single most obvious
	# thing wrong with the world, because the trees are the nearest object to
	# the road that is not the road.
	#
	# Two things are deliberately left as decoration. A pylon is a marker - it
	# is meant to be knocked over, and a solid one is a wall the width of the
	# escape road. And a grandstand stands twenty metres beyond a barrier a car
	# cannot get over, so nothing can reach it: a solid one is a box fifteen
	# times the size of the model it was built from, which on the first attempt
	# reached back across the circuit and turned the self-test into a pile-up.
	for entry: Array in [
		[trees_large, "treeLarge.glb", "TreesLarge", "trunk"],
		[trees_small, "treeSmall.glb", "TreesSmall", "trunk"],
		[pylons, "pylon.glb", "Pylons", ""],
		[lamps, "lightPostModern.glb", "Lamps", "post"],
		[seats, "grandStand.glb", "Grandstands", ""],
	]:
		var node := _multimesh(MODEL_DIR + entry[1], entry[0], entry[2],
			str(entry[3]))
		if node != null:
			add_child(node)


# Collision for a MultiMesh of scenery: one body, one shape per instance.
#
# One StaticBody3D rather than one per tree, because a thousand bodies is a
# thousand things for the physics server to keep track of and they never move
# relative to each other. The shapes are derived from the model's own bounds so
# they cannot drift from the art, and they are deliberately *narrower* than it:
# a tree is a trunk with a canopy over it, and a car that clips the canopy of a
# tree four metres off the road has not hit anything - the trunk is what is
# solid.
#
#   trunk  a narrow cylinder up the middle of a tree
#   post   the same, thinner: a lamp post is all post
#
# The shapes are placed in world space rather than parented under a scaled
# node, because a CollisionShape3D under a scaled transform is something
# Godot's physics warns about and gets wrong - and the scale here runs from
# four to fifteen.
#
# `placement` is the same offset the MultiMesh draws with, and `bounds` the
# same bounds it was computed from. Both are passed in rather than read back
# off the built MultiMesh: doing that returned identity transforms, so every
# trunk came out unscaled and sitting on the racing line, which the self-test
# noticed as a field of cars that all had accidents and nothing else did.
func _make_solid(transforms: Array, placement: Transform3D, bounds: AABB,
		kind: String, label: String) -> void:
	var body := StaticBody3D.new()
	body.name = label + "Solid"
	body.set_meta("surface", "scenery")
	var slenderness := 0.06 if kind == "post" else 0.075
	for xform: Transform3D in transforms:
		var box: AABB = (xform * placement) * bounds
		var cylinder := CylinderShape3D.new()
		cylinder.radius = clampf(minf(box.size.x, box.size.z) * slenderness,
			0.08, 1.2)
		cylinder.height = maxf(0.5, box.size.y)
		var shape := CollisionShape3D.new()
		shape.shape = cylinder
		shape.position = box.get_center()
		body.add_child(shape)
	add_child(body)
	# A trunk or a post is something to hit, not something to stand on. The larger
	# trees are twenty metres tall, so a wheel ray that caught the top of one would
	# not put a car on a barrier - it would put it on the canopy.
	Layers.mark_obstacle(body)
	scenery_bodies += body.get_child_count()


# Whether a piece of scenery can stand here without being on the circuit.
#
# Offsetting sideways from the centreline is not the same as ending up beside
# the road, and on this game's two hardest circuits it is routinely not. Inside
# a corner tighter than the offset the point folds past the centre of the
# corner and comes out on the far side of it; and where the Kigali lap runs
# back alongside itself, twenty metres away, a tree fifteen metres off one pass
# is five metres onto the other one - which is the racing line.
#
# So the offset is not trusted. The point is asked how far it really is from
# the nearest part of the lap - any part of it - and anything that is not
# outside the barrier is thrown away. Nothing here was solid before, so this
# was only ever a tree standing in the road; now they have trunks it would be
# a tree standing in the road that stops a car at 200 km/h.
func _clear_of_the_circuit(point: Vector3, margin := 1.0) -> bool:
	var near := info.nearest(point)
	return absf(near["lateral"]) >= wall_face_lateral() + WALL_THICKNESS + margin


# Whether a point on the lap is close enough to the start line to put a
# grandstand at. A window of zero means anywhere, which is what a circuit with
# no city around it wants.
func _near_start(s: float, window: float) -> bool:
	if window <= 0.0:
		return true
	var start := float(track.get("start_s", 45.0))
	var offset := absf(s - start)
	return minf(offset, info.length - offset) <= window
