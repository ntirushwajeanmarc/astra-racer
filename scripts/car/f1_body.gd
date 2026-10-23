class_name F1Body
extends Node3D
# A Formula One car, generated at load time rather than loaded from a kit.
#
# Two things force a generated body. The physics measures the car off its own
# four named wheel nodes - wheelbase, track width, wheel radius, the ground rays
# - so the artwork has to expose those nodes rather than be one welded mesh; and
# direction has to be readable. From a chase camera one of the kit's cars driven
# forwards looks identical to the same car driven backwards, which is why "which
# end is the front?" had no answer. A Formula One car answers it in silhouette:
# a wide, low front wing at one end, a narrow, tall rear wing with a rain light
# on it at the other, a helmet and halo in between. Nothing about it is
# symmetric front to back, so the shape itself carries the information.
#
# Everything is in metres and the car's own -Z is forward, as everywhere else in
# Godot. The builder reports the dimensions and the bounds of what it actually
# emitted, and the physics re-measures them from the finished nodes, so the art
# cannot quietly drift away from the car that drives.

const LIVERIES := {
	"red": {
		"primary": Color(0.80, 0.07, 0.06),
		"secondary": Color(0.10, 0.10, 0.12),
		"accent": Color(0.98, 0.86, 0.30),
	},
	"white": {
		"primary": Color(0.93, 0.94, 0.96),
		"secondary": Color(0.05, 0.28, 0.65),
		"accent": Color(0.90, 0.13, 0.17),
	},
	"green": {
		"primary": Color(0.04, 0.42, 0.22),
		"secondary": Color(0.87, 0.93, 0.15),
		"accent": Color(0.95, 0.95, 0.95),
	},
	"orange": {
		"primary": Color(0.97, 0.40, 0.04),
		"secondary": Color(0.05, 0.09, 0.18),
		"accent": Color(0.16, 0.72, 0.96),
	},
}
const DEFAULT_LIVERY := "red"

# The dimensions the body is built to. Named because the geometry needs numbers
# to build from; the car measures the finished nodes back again.
const FRONT_AXLE_Z := -1.45
const REAR_AXLE_Z := 1.45
const FRONT_TRACK := 1.50
const REAR_TRACK := 1.60
const FRONT_TYRE_WIDTH := 0.30
const REAR_TYRE_WIDTH := 0.40
const TYRE_RADIUS := 0.36
const RIM_RADIUS := 0.23
const FRONT_WING_WIDTH := 1.86
const REAR_WING_WIDTH := 1.04
# Where the boost flame comes out. Shared with the visuals rather than guessed at
# from the body's length, which would put it on the rear wing.
const EXHAUST := Vector3(0.0, 0.50, 1.70)

const MAT_BODY := "body"
const MAT_TRIM := "trim"
const MAT_ACCENT := "accent"
const MAT_CARBON := "carbon"
const MAT_TYRE := "tyre"
const MAT_RIM := "rim"
const MAT_LIGHT := "light"

var primary := Color(0.80, 0.07, 0.06)
var secondary := Color(0.10, 0.10, 0.12)
var accent := Color(0.98, 0.86, 0.30)

var wheel_nodes: Array[Node3D] = []
var bounds := AABB()                     # every vertex emitted, in this node's space
var groups := {}                         # named part -> AABB of that part alone

var _banks := {}
var _materials := {}
var _bounds := AABB()
var _bounds_started := false
var _group := ""
var _group_bounds := AABB()
var _group_started := false


func _init(livery := DEFAULT_LIVERY) -> void:
	var skin: Dictionary = LIVERIES.get(livery, LIVERIES[DEFAULT_LIVERY])
	primary = skin["primary"]
	secondary = skin["secondary"]
	accent = skin["accent"]
	name = "F1Body"


func build() -> void:
	_begin()
	_build_floor()
	_build_front_wing()
	_build_nose()
	_build_monocoque()
	_build_cockpit()
	_build_sidepods()
	_build_engine_cover()
	_build_rear_wing()
	_flush(self)
	bounds = _bounds

	# The four wheels, in the order the car expects: front left, front right,
	# back left, back right. The front pair steers and the back pair lays the skid
	# marks, so the order is part of the contract.
	var plan := [
		{"name": "wheelFrontLeft", "x": -FRONT_TRACK * 0.5, "z": FRONT_AXLE_Z, "w": FRONT_TYRE_WIDTH},
		{"name": "wheelFrontRight", "x": FRONT_TRACK * 0.5, "z": FRONT_AXLE_Z, "w": FRONT_TYRE_WIDTH},
		{"name": "wheelBackLeft", "x": -REAR_TRACK * 0.5, "z": REAR_AXLE_Z, "w": REAR_TYRE_WIDTH},
		{"name": "wheelBackRight", "x": REAR_TRACK * 0.5, "z": REAR_AXLE_Z, "w": REAR_TYRE_WIDTH},
	]
	for wheel: Dictionary in plan:
		var node := Node3D.new()
		node.name = wheel["name"]
		node.position = Vector3(wheel["x"], TYRE_RADIUS, wheel["z"])
		add_child(node)
		_begin()
		_build_wheel(node, wheel["w"])
		_flush(node)
		bounds = bounds.merge(AABB(_bounds.position + node.position, _bounds.size))
		wheel_nodes.append(node)


# ------------------------------------------------------------------ geometry

# The front-most and rear-most points of the bodywork, and the two wings' own
# boxes. A car you cannot tell the ends of is the bug these exist to test.
func nose_z() -> float:
	return (groups.get("front_wing", AABB()) as AABB).position.z


func tail_z() -> float:
	var wing: AABB = groups.get("rear_wing", AABB())
	return wing.position.z + wing.size.z


func wing_box(group: String) -> AABB:
	return groups.get(group, AABB())


func _build_floor() -> void:
	# Floor, plank and diffuser. The plank is the lowest point of the car, as it
	# is on a real one, and the diffuser ramps up towards the rear.
	_box(MAT_CARBON, Vector3(0.0, 0.075, 0.02), Vector3(1.02, 0.055, 3.44))
	_box(MAT_CARBON, Vector3(0.0, 0.048, 0.30), Vector3(0.30, 0.035, 2.20))
	_box(MAT_CARBON, Vector3(0.0, 0.20, 1.90), Vector3(1.00, 0.24, 0.60), -0.22)
	# Floor edge fences, the two strakes that give the underbody its bite.
	for side: float in [-1.0, 1.0]:
		_box(MAT_CARBON, Vector3(side * 0.49, 0.13, 0.10), Vector3(0.03, 0.10, 2.60))


func _build_front_wing() -> void:
	_begin_group("front_wing")
	_box(MAT_BODY, Vector3(0.0, 0.075, -2.24), Vector3(FRONT_WING_WIDTH, 0.045, 0.44))
	_box(MAT_TRIM, Vector3(0.0, 0.145, -2.20), Vector3(FRONT_WING_WIDTH, 0.042, 0.22), -0.30)
	for side: float in [-1.0, 1.0]:
		# Endplates, and the two pylons that carry the wing off the nose.
		_box(MAT_TRIM, Vector3(side * 0.93, 0.16, -2.24), Vector3(0.035, 0.28, 0.52))
		_box(MAT_CARBON, Vector3(side * 0.10, 0.18, -1.99), Vector3(0.07, 0.24, 0.14))
	_end_group()


func _build_nose() -> void:
	_block(MAT_BODY, Vector2(0.22, 0.14), Vector2(0.60, 0.30),
		Vector3(0.0, 0.24, -2.10), Vector3(0.0, 0.34, -0.55))


func _build_monocoque() -> void:
	_block(MAT_BODY, Vector2(0.60, 0.30), Vector2(0.70, 0.44),
		Vector3(0.0, 0.34, -0.55), Vector3(0.0, 0.42, 0.62))


func _build_cockpit() -> void:
	# Aperture, headrest, then the halo - a ring around the driver's head with a
	# pillar down to the nose, which is as much of the silhouette as the wings.
	_box(MAT_CARBON, Vector3(0.0, 0.58, -0.10), Vector3(0.56, 0.10, 0.80))
	_box(MAT_CARBON, Vector3(0.0, 0.60, 0.30), Vector3(0.34, 0.22, 0.18))

	var halo := TorusMesh.new()
	halo.inner_radius = 0.318
	halo.outer_radius = 0.382
	halo.rings = 28
	halo.ring_segments = 8
	_mesh_instance(self, halo, MAT_CARBON, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.79, -0.10)))
	_box(MAT_CARBON, Vector3(0.0, 0.66, -0.45), Vector3(0.075, 0.30, 0.09))

	var helmet := SphereMesh.new()
	helmet.radius = 0.155
	helmet.height = 0.31
	helmet.radial_segments = 20
	helmet.rings = 10
	_mesh_instance(self, helmet, MAT_ACCENT, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.63, -0.02)))
	_box(MAT_CARBON, Vector3(0.0, 0.66, -0.16), Vector3(0.22, 0.075, 0.04))


func _build_sidepods() -> void:
	for side: float in [-1.0, 1.0]:
		_block(MAT_TRIM, Vector2(0.36, 0.32), Vector2(0.26, 0.30),
			Vector3(side * 0.42, 0.34, -0.30), Vector3(side * 0.40, 0.36, 1.05))
		# The undercut that makes a sidepod a sidepod, and the inlet lip above it.
		_box(MAT_CARBON, Vector3(side * 0.45, 0.19, 0.15), Vector3(0.30, 0.18, 1.10))
		_box(MAT_ACCENT, Vector3(side * 0.42, 0.48, -0.31), Vector3(0.38, 0.05, 0.10))


func _build_engine_cover() -> void:
	_box(MAT_CARBON, Vector3(0.0, 0.90, 0.28), Vector3(0.28, 0.26, 0.26))
	_block(MAT_BODY, Vector2(0.66, 0.50), Vector2(0.30, 0.22),
		Vector3(0.0, 0.60, 0.45), Vector3(0.0, 0.44, 1.66))
	# Shark fin, and the exhaust it hangs over.
	_box(MAT_BODY, Vector3(0.0, 0.72, 1.15), Vector3(0.035, 0.26, 0.95))
	var pipe := CylinderMesh.new()
	pipe.top_radius = 0.06
	pipe.bottom_radius = 0.06
	pipe.height = 0.14
	pipe.radial_segments = 12
	_mesh_instance(self, pipe, MAT_CARBON,
		Transform3D(Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0)), EXHAUST))


func _build_rear_wing() -> void:
	_begin_group("rear_wing")
	_box(MAT_CARBON, Vector3(0.0, 0.66, 1.90), Vector3(0.11, 0.42, 0.18))
	_box(MAT_BODY, Vector3(0.0, 0.98, 2.06), Vector3(REAR_WING_WIDTH, 0.05, 0.44), -0.20)
	_box(MAT_ACCENT, Vector3(0.0, 1.14, 2.18), Vector3(REAR_WING_WIDTH, 0.045, 0.24), -0.28)
	for side: float in [-1.0, 1.0]:
		_box(MAT_TRIM, Vector3(side * 0.53, 1.02, 2.06), Vector3(0.035, 0.44, 0.56))
	# The rain light. Not decoration: it is the one part of the car that is lit,
	# and it is at the back, so even in the dark the back is the end you can name.
	_box(MAT_LIGHT, Vector3(0.0, 0.60, 2.30), Vector3(0.18, 0.11, 0.05))
	_end_group()


func _build_wheel(node: Node3D, width: float) -> void:
	# A cylinder is Y-aligned; a quarter turn about Z lays its axis along X, which
	# is the axis the wheel node spins about when the car moves.
	var axle := Basis.from_euler(Vector3(0.0, 0.0, PI * 0.5))
	var tyre := CylinderMesh.new()
	tyre.top_radius = TYRE_RADIUS
	tyre.bottom_radius = TYRE_RADIUS
	tyre.height = width
	tyre.radial_segments = 24
	_mesh_instance(node, tyre, MAT_TYRE, Transform3D(axle, Vector3.ZERO))

	var disc := CylinderMesh.new()
	disc.top_radius = RIM_RADIUS
	disc.bottom_radius = RIM_RADIUS
	disc.height = 0.02
	disc.radial_segments = 20
	var nut := CylinderMesh.new()
	nut.top_radius = 0.075
	nut.bottom_radius = 0.075
	nut.height = 0.035
	nut.radial_segments = 12
	for side: float in [-1.0, 1.0]:
		_mesh_instance(node, disc, MAT_RIM,
			Transform3D(axle, Vector3(side * (width * 0.5 - 0.012), 0.0, 0.0)))
		_mesh_instance(node, nut, MAT_CARBON,
			Transform3D(axle, Vector3(side * (width * 0.5 - 0.006), 0.0, 0.0)))
		# A bar across the sidewall. Without something on the wheel to count,
		# a wheel at 200 km/h and a wheel standing still look the same.
		_box(MAT_ACCENT, Vector3(side * (width * 0.5 + 0.004), 0.0, 0.0),
			Vector3(0.014, 0.30, 0.06))


# -------------------------------------------------------------------- meshes

# One rectangular solid. `pitch` and `yaw` turn it about its own centre, which
# is what gives the wing planes their angle of attack.
func _box(mat: String, centre: Vector3, size: Vector3, pitch := 0.0, yaw := 0.0) -> void:
	var xf := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	var h := size * 0.5
	var p: Array[Vector3] = []
	for k in 8:
		p.append(centre + xf * Vector3(
			h.x if (k & 1) != 0 else -h.x,
			h.y if (k & 2) != 0 else -h.y,
			h.z if (k & 4) != 0 else -h.z
		))
	for face: Array in [
		[0, 2, 6, 4, Vector3(-1.0, 0.0, 0.0)],
		[1, 5, 7, 3, Vector3(1.0, 0.0, 0.0)],
		[0, 4, 5, 1, Vector3(0.0, -1.0, 0.0)],
		[2, 3, 7, 6, Vector3(0.0, 1.0, 0.0)],
		[0, 1, 3, 2, Vector3(0.0, 0.0, -1.0)],
		[4, 6, 7, 5, Vector3(0.0, 0.0, 1.0)],
	]:
		_quad(mat, p[face[0]], p[face[1]], p[face[2]], p[face[3]], xf * (face[4] as Vector3))


# One solid whose two ends differ in size: the same primitive is a nose cone, an
# engine cover tapering to the rear, or a sidepod. `front` and `back` are the
# centres of the two end faces, front being the more negative Z.
func _block(mat: String, front_size: Vector2, back_size: Vector2,
		front: Vector3, back: Vector3) -> void:
	var fh := front_size * 0.5
	var bh := back_size * 0.5
	var f: Array[Vector3] = [
		Vector3(front.x - fh.x, front.y - fh.y, front.z),
		Vector3(front.x + fh.x, front.y - fh.y, front.z),
		Vector3(front.x + fh.x, front.y + fh.y, front.z),
		Vector3(front.x - fh.x, front.y + fh.y, front.z),
	]
	var b: Array[Vector3] = [
		Vector3(back.x - bh.x, back.y - bh.y, back.z),
		Vector3(back.x + bh.x, back.y - bh.y, back.z),
		Vector3(back.x + bh.x, back.y + bh.y, back.z),
		Vector3(back.x - bh.x, back.y + bh.y, back.z),
	]
	_quad(mat, f[0], f[1], f[2], f[3], Vector3(0.0, 0.0, -1.0))
	_quad(mat, b[0], b[1], b[2], b[3], Vector3(0.0, 0.0, 1.0))
	_quad(mat, f[0], f[3], b[3], b[0], Vector3(-1.0, 0.0, 0.0))
	_quad(mat, f[1], b[1], b[2], f[2], Vector3(1.0, 0.0, 0.0))
	_quad(mat, f[0], b[0], b[1], f[1], Vector3(0.0, -1.0, 0.0))
	_quad(mat, f[3], f[2], b[2], b[3], Vector3(0.0, 1.0, 0.0))


# Appends one quad as two triangles, wound so that the side it is lit and shaded
# from - and, wherever a face is used for collision, the side it is solid from -
# is the side `outward` points to. Godot's plane normal for (p1, p2, p3) is
# (p1 - p3) x (p1 - p2), which is the negation of the triangle's own cross
# product, hence the inverted test below.
func _quad(mat: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3) -> void:
	var n := outward.normalized()
	if (b - a).cross(c - a).dot(n) < 0.0:
		_tri(mat, a, b, c, n)
		_tri(mat, a, c, d, n)
	else:
		_tri(mat, a, c, b, n)
		_tri(mat, a, d, c, n)


func _tri(mat: String, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	var bank := _bank(mat)
	(bank["verts"] as Array[Vector3]).append(a)
	(bank["verts"] as Array[Vector3]).append(b)
	(bank["verts"] as Array[Vector3]).append(c)
	(bank["norms"] as Array[Vector3]).append(n)
	(bank["norms"] as Array[Vector3]).append(n)
	(bank["norms"] as Array[Vector3]).append(n)
	_grow(a)
	_grow(b)
	_grow(c)


func _mesh_instance(parent: Node3D, mesh: Mesh, mat: String, xform: Transform3D) -> void:
	var mi := MeshInstance3D.new()
	mi.name = String(mat).capitalize()
	mi.mesh = mesh
	mi.material_override = _material(mat)
	mi.transform = xform
	parent.add_child(mi)
	_merge(xform * mesh.get_aabb())


# ------------------------------------------------------------------ assembly

func _begin() -> void:
	_banks.clear()
	_bounds = AABB()
	_bounds_started = false


func _bank(mat: String) -> Dictionary:
	if not _banks.has(mat):
		var verts: Array[Vector3] = []
		var norms: Array[Vector3] = []
		_banks[mat] = {"verts": verts, "norms": norms}
	return _banks[mat]


func _flush(parent: Node3D) -> void:
	for mat: String in _banks:
		var bank: Dictionary = _banks[mat]
		var verts: Array[Vector3] = bank["verts"]
		if verts.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(verts)
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(bank["norms"] as Array[Vector3])
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, _material(mat))
		var mi := MeshInstance3D.new()
		mi.name = String(mat).capitalize()
		mi.mesh = mesh
		parent.add_child(mi)


func _grow(p: Vector3) -> void:
	_merge(AABB(p, Vector3.ZERO))
	if _group != "":
		if _group_started:
			_group_bounds = _group_bounds.expand(p)
		else:
			_group_bounds = AABB(p, Vector3.ZERO)
			_group_started = true


func _merge(box: AABB) -> void:
	if _bounds_started:
		_bounds = _bounds.merge(box)
	else:
		_bounds = box
		_bounds_started = true


func _begin_group(group: String) -> void:
	_group = group
	_group_bounds = AABB()
	_group_started = false


func _end_group() -> void:
	if _group != "" and _group_started:
		groups[_group] = _group_bounds
	_group = ""


func _material(mat: String) -> StandardMaterial3D:
	if not _materials.has(mat):
		var m := StandardMaterial3D.new()
		match mat:
			MAT_TRIM:
				m.albedo_color = secondary
				m.metallic = 0.25
				m.roughness = 0.32
			MAT_ACCENT:
				m.albedo_color = accent
				m.metallic = 0.20
				m.roughness = 0.34
			MAT_CARBON:
				m.albedo_color = Color(0.055, 0.055, 0.065)
				m.metallic = 0.15
				m.roughness = 0.52
			MAT_TYRE:
				m.albedo_color = Color(0.035, 0.035, 0.042)
				m.metallic = 0.0
				m.roughness = 0.95
			MAT_RIM:
				m.albedo_color = Color(0.60, 0.62, 0.66)
				m.metallic = 0.85
				m.roughness = 0.26
			MAT_LIGHT:
				m.albedo_color = Color(0.90, 0.06, 0.05)
				m.emission_enabled = true
				m.emission = Color(1.0, 0.08, 0.05)
				m.emission_energy_multiplier = 5.0
			_:
				m.albedo_color = primary
				m.metallic = 0.30
				m.roughness = 0.28
		_materials[mat] = m
	return _materials[mat]
