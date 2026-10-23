extends SceneTree
# Builds a circuit and reports what the meshes and materials actually are, since
# a rendered frame only tells you something is wrong, not what.
#   godot --headless --path . --script res://tools/inspect_track.gd

func _describe_mesh(label: String, node: Node) -> void:
	var mi: MeshInstance3D = null
	for c in node.get_children():
		if c is MeshInstance3D:
			mi = c
			break
	if mi == null:
		print("%s: NO MESH INSTANCE (children: %s)" % [label, _child_names(node)])
		return
	var mesh := mi.mesh
	if mesh == null:
		print("%s: mesh is null" % label)
		return
	var surfaces := mesh.get_surface_count()
	var box := mesh.get_aabb()
	print("%s: visible=%s surfaces=%d aabb(min=%s size=%s) material_override=%s" % [
		label, str(mi.visible), surfaces,
		"(%.1f,%.1f,%.1f)" % [box.position.x, box.position.y, box.position.z],
		"(%.1f,%.1f,%.1f)" % [box.size.x, box.size.y, box.size.z],
		str(mi.material_override != null),
	])
	for s in surfaces:
		var material: Material = mesh.surface_get_material(s)
		if material is StandardMaterial3D:
			var std := material as StandardMaterial3D
			print("   surface %d: albedo=%s vertex_colour_as_albedo=%s transparency=%d" % [
				s, str(std.albedo_color), str(std.vertex_color_use_as_albedo), std.transparency,
			])
		else:
			print("   surface %d: material is %s" % [s, str(material)])
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		print("   surface %d: %d vertices, %d colours, %d normals" % [
			s, verts.size(), colours.size(), normals.size(),
		])
		if verts.size() > 0:
			print("      v0=%s v1=%s v2=%s" % [
				str(verts[0]), str(verts[1 % verts.size()]), str(verts[2 % verts.size()]),
			])
		if colours.size() > 0:
			print("      c0=%s c1=%s" % [str(colours[0]), str(colours[1 % colours.size()])])
		if normals.size() > 0:
			print("      n0=%s" % str(normals[0]))


func _child_names(node: Node) -> String:
	var names := PackedStringArray()
	for c in node.get_children():
		names.append("%s(%s)" % [c.name, c.get_class()])
	return ", ".join(names)


func _initialize() -> void:
	var builder := TrackBuilder.new()
	get_root().add_child(builder)
	builder.build(TrackData.get_track(0))
	print("--- builder children: %s" % _child_names(builder))
	for name in ["Road", "Verge"]:
		var node := builder.get_node_or_null(name)
		if node == null:
			print("%s: MISSING" % name)
		else:
			_describe_mesh(name, node)
	var horizon := builder.get_node_or_null("Horizon")
	if horizon is MeshInstance3D:
		var h := horizon as MeshInstance3D
		var material: Material = h.material_override
		print("Horizon: mesh=%s override=%s" % [
			str(h.mesh), str((material as StandardMaterial3D).albedo_color) if material is StandardMaterial3D else "?",
		])
	# Where is the car looking at, and what is under it?
	# Where does each mesh's geometry actually sit relative to the centreline?
	# A verge whose vertices stray inside the road would cover the asphalt, and
	# that would be invisible in the mesh statistics above.
	for name in ["Road", "Verge"]:
		var body := builder.get_node_or_null(name)
		if body == null:
			continue
		for c in body.get_children():
			if not (c is MeshInstance3D):
				continue
			var arrays: Array = (c as MeshInstance3D).mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var lo := INF
			var hi := -INF
			var inside := 0
			var step := maxi(1, verts.size() / 400)
			var i := 0
			while i < verts.size():
				var lateral: float = absf(builder.info.nearest(verts[i])["lateral"])
				lo = minf(lo, lateral)
				hi = maxf(hi, lateral)
				if lateral < builder.info.half_width:
					inside += 1
				i += step
			print("%s vertices: |lateral| from %.2f to %.2f; %d sampled vertices sit INSIDE the road (half width %.1f)" % [
				name, lo, hi, inside, builder.info.half_width,
			])

	print("start_transform origin=%s" % str(builder.start_transform.origin))
	var probe := builder.start_transform.origin + Vector3.UP * 20.0
	var space := get_root().world_3d.direct_space_state
	var query := PhysicsRayQueryParameters3D.create(probe, probe - Vector3.UP * 40.0)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		print("probe: nothing under the start line!")
	else:
		print("probe: first thing under the start line is %s at y=%.2f" % [
			str((hit["collider"] as Node).name), (hit["position"] as Vector3).y,
		])
	quit(0)
