extends SceneTree
# Inspector: dumps the node tree of chosen models (to find separately-named
# wheels on the car) and, for track pieces, an ASCII footprint of where the
# asphalt actually sits in the XZ plane.
#   godot --headless --path . --script res://tools/inspect_models.gd

const CAR := "res://assets/models/raceCarRed.glb"
const TREE_MODELS := [
	"res://assets/models/roadStraight.glb",
	"res://assets/models/roadCornerLarge.glb",
	"res://assets/models/roadCurved.glb",
	"res://assets/models/roadStart.glb",
	"res://assets/models/roadStartPositions.glb",
]


func _tree(node: Node, depth: int) -> void:
	var pad := "  ".repeat(depth)
	var extra := ""
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var surf := mi.mesh.get_surface_count() if mi.mesh != null else 0
		var local: AABB = mi.get_aabb()
		extra = "  mesh surfaces=%d aabb(min=%s size=%s) mat=%s" % [
			surf,
			"(%.2f,%.2f,%.2f)" % [local.position.x, local.position.y, local.position.z],
			"(%.2f,%.2f,%.2f)" % [local.size.x, local.size.y, local.size.z],
			str(mi.mesh.surface_get_material(0).resource_name) if surf > 0 else "-",
		]
	print("%s%s [%s]%s" % [pad, node.name, node.get_class(), extra])
	for c in node.get_children():
		_tree(c, depth + 1)


func _footprint(model: String, cells: int = 16, span: float = 3.0) -> void:
	# Rasterise every triangle's XZ extent plus sample points into a coarse grid.
	var ps: PackedScene = load(model)
	if ps == null:
		return
	var inst: Node3D = ps.instantiate()
	var grid: Array = []
	for z in range(cells):
		var row: Array = []
		for x in range(cells):
			row.append(".")
		grid.append(row)
	var stack: Array = [inst]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var faces: PackedVector3Array = (n as MeshInstance3D).mesh.get_faces()
			var xf := _accum(inst, n)
			for v: Vector3 in faces:
				var w: Vector3 = xf * v
				var cx := int(round((w.x - (-span)) / (2.0 * span) * (cells - 1)))
				var cz := int(round((w.z - (-span)) / (2.0 * span) * (cells - 1)))
				if cx >= 0 and cx < cells and cz >= 0 and cz < cells:
					grid[cz][cx] = "#"
		for c in n.get_children():
			stack.append(c)
	print("--- footprint of %s (x from %.1f..%.1f left->right, z rows top->bottom) ---" % [
		model.get_file(), -span, span,
	])
	for row: Array in grid:
		print("  " + "".join(row))
	inst.free()


func _accum(root: Node3D, target: Node) -> Transform3D:
	var chain: Array = []
	var n: Node = target
	while n != null and n != root:
		chain.append(n)
		n = n.get_parent()
	var xf := Transform3D.IDENTITY
	for i in range(chain.size() - 1, -1, -1):
		xf = xf * (chain[i] as Node3D).transform
	return xf


func _initialize() -> void:
	print("=== car node tree (looking for separately named wheels) ===")
	var ps: PackedScene = load(CAR)
	var car: Node3D = ps.instantiate()
	_tree(car, 0)
	car.free()

	for m: String in TREE_MODELS:
		_footprint(m)
	quit(0)
