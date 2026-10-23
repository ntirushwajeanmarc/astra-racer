class_name GltfFix
extends RefCounted
# One engine quirk, named and fixed in one place.
#
# Godot's glTF importer decides per material whether the meshes using it carry
# vertex colours, and it gets the answer wrong for the *first* primitive it
# reads in a file: that material comes back with `vertex_color_use_as_albedo`
# off. Every other material in the same file is correct, which is what makes it
# a quirk of the importer rather than a mistake in the asset.
#
# It is not a subtle failure. Both of this project's generated assets carry all
# of their colour in vertex colours over grey textures, with the brightness
# factored into the material - so a material that ignores its vertex colours
# renders as the bare texture multiplied by that brightness and comes out white.
# It cost the city its flat roofs and the terrain its entire hillside, twice,
# because the repair lived in the code that mounts the city and the checks that
# render either asset on its own never went through it.
#
# So it lives here, and everything that loads one of those assets calls it: the
# track builder for the terrain, City for the city, and the checks for both.

# Asserts that every material under `root` uses its vertex colours as albedo.
# Returns how many distinct materials it touched, which is what a check can
# assert on. Materials are shared across the chunks of an asset, so this walks
# the whole tree but only visits each material once.
static func use_vertex_colours(root: Node) -> int:
	var seen := {}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is MeshInstance3D):
			continue
		var mesh: Mesh = (node as MeshInstance3D).mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var material := mesh.surface_get_material(i) as StandardMaterial3D
			if material == null or seen.has(material.get_instance_id()):
				continue
			seen[material.get_instance_id()] = true
			material.vertex_color_use_as_albedo = true
	return seen.size()
