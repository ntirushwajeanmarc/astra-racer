extends SceneTree
# Measuring tool: prints the world-space AABB of every Kenney model so track
# tiles can be laid out on exact spacing and wheels/colliders placed by number
# rather than by eye. Run with:
#   godot --headless --path . --script res://tools/measure_models.gd

const MODEL_DIR := "res://assets/models"

func _v(v: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [v.x, v.y, v.z]


func _aabb(root: Node) -> AABB:
	var total: AABB = AABB()
	var have := false
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while stack.size() > 0:
		var pair: Array = stack.pop_back()
		var cur: Node = pair[0]
		var cxf: Transform3D = pair[1]
		if cur is Node3D:
			cxf = cxf * (cur as Node3D).transform
		if cur is MeshInstance3D:
			var box: AABB = cxf * (cur as MeshInstance3D).get_aabb()
			if have:
				total = total.merge(box)
			else:
				total = box
				have = true
		for c in cur.get_children():
			stack.append([c, cxf])
	return total


func _initialize() -> void:
	var files: Array[String] = []
	var dir := DirAccess.open(MODEL_DIR)
	if dir == null:
		print("MEASURE_FAIL: cannot open ", MODEL_DIR)
		quit(1)
		return
	for f in dir.get_files():
		if f.ends_with(".glb"):
			files.append(f)
	files.sort()
	var ok := 0
	print("--- model AABBs (metres; size = extent, min = origin offset) ---")
	for f: String in files:
		var ps: PackedScene = load("%s/%s" % [MODEL_DIR, f])
		if ps == null:
			print("LOAD FAILED: ", f)
			continue
		ok += 1
		var inst: Node3D = ps.instantiate()
		var box: AABB = _aabb(inst)
		var tris := 0
		var stack: Array = [inst]
		while stack.size() > 0:
			var n: Node = stack.pop_back()
			if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
				tris += (n as MeshInstance3D).mesh.get_faces().size() / 3
			for c in n.get_children():
				stack.append(c)
		print("%-28s size=%s  min=%s  max=%s  tris=%d" % [
			f, _v(box.size), _v(box.position), _v(box.position + box.size), tris,
		])
		inst.free()
	print("MEASURED_OK=%d OF %d" % [ok, files.size()])
	quit(0)
