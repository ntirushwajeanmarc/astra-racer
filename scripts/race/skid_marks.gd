class_name SkidMarks
extends MultiMeshInstance3D
# A fixed pool of flat dark quads used as a ring buffer: old marks are recycled
# once the pool is full. Fixed size keeps the cost constant no matter how long
# the race runs, and the marks live in world space so they stay where the tyres
# left them.

const POOL := 1200

var _next := 0
var _quad: PlaneMesh


func _ready() -> void:
	_quad = PlaneMesh.new()
	_quad.size = Vector2(1.0, 1.0)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.045, 0.045, 0.05, 0.62)
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	_quad.material = material

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _quad
	mm.instance_count = POOL
	var hidden := Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), Vector3(0, -500, 0))
	for i in POOL:
		mm.set_instance_transform(i, hidden)
	multimesh = mm
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func add_segment(from: Vector3, to: Vector3, width := 0.34) -> void:
	if multimesh == null:
		return
	var delta := to - from
	var length := delta.length()
	if length < 0.02:
		return
	var forward := delta / length
	var up := Vector3.UP
	var right := forward.cross(up).normalized()
	if right.length_squared() < 0.01:
		right = Vector3.RIGHT
	up = right.cross(forward).normalized()
	var basis := Basis(right, up, -forward).scaled(Vector3(width, 1.0, length))
	var origin := (from + to) * 0.5 + up * 0.03
	multimesh.set_instance_transform(_next, Transform3D(basis, origin))
	_next = (_next + 1) % POOL


func clear() -> void:
	if multimesh == null:
		return
	var hidden := Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), Vector3(0, -500, 0))
	for i in POOL:
		multimesh.set_instance_transform(i, hidden)
	_next = 0
