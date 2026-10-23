class_name TrackInfo
extends RefCounted
# The geometry of one circuit, sampled evenly so that "distance along the lap"
# is just an array index times spacing. Everything that needs to know where it is
# - the AI's racing line, lap validation, the wrong-way warning, the minimap -
# asks this object, so there is exactly one description of the track.

var points: PackedVector3Array = PackedVector3Array()
var tangents: PackedVector3Array = PackedVector3Array()   # 3D, includes hills
var flat_tangents: PackedVector3Array = PackedVector3Array()
var rights: PackedVector3Array = PackedVector3Array()     # flat, +X of the car
var curvature: PackedFloat32Array = PackedFloat32Array()  # signed 1/r, + = left
var count := 0
var spacing := 2.0
var half_width := 6.0
var length := 0.0
var min_y := 0.0
var max_y := 0.0
var checkpoint_indices: PackedInt32Array = PackedInt32Array()
var start_index := 0

var _cells := {}
var _cell_size := 32.0
var _coarse_step := 8


func build_from(centerline: PackedVector3Array, p_half_width: float, p_spacing: float, start_s := 0.0) -> void:
	points = centerline
	spacing = p_spacing
	half_width = p_half_width
	count = points.size()
	length = float(count) * spacing
	tangents.resize(count)
	flat_tangents.resize(count)
	rights.resize(count)
	curvature.resize(count)

	min_y = INF
	max_y = -INF
	for p: Vector3 in points:
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)

	for i in count:
		var a := points[(i - 1 + count) % count]
		var b := points[(i + 1) % count]
		var t := (b - a).normalized()
		tangents[i] = t
		var flat := Vector3(t.x, 0.0, t.z)
		if flat.length_squared() < 0.0001:
			flat = Vector3.FORWARD
		flat = flat.normalized()
		flat_tangents[i] = flat
		rights[i] = Vector3(-flat.z, 0.0, flat.x)

	for i in count:
		var prev := flat_tangents[(i - 1 + count) % count]
		var next := flat_tangents[(i + 1) % count]
		# Signed turn rate over the two samples either side: positive turns left.
		var cross_y := prev.cross(next).y
		var dot := clampf(prev.dot(next), -1.0, 1.0)
		curvature[i] = atan2(cross_y, dot) / (2.0 * spacing)

	start_index = wrapi(int(round(start_s / spacing)), 0, maxi(1, count))
	_build_grid()


func _build_grid() -> void:
	_cells.clear()
	for i in count:
		var key := _cell_key(points[i])
		if not _cells.has(key):
			_cells[key] = PackedInt32Array()
		(_cells[key] as PackedInt32Array).append(i)


func _cell_key(p: Vector3) -> Vector2i:
	return Vector2i(int(floor(p.x / _cell_size)), int(floor(p.z / _cell_size)))


func wrap_index(i: int) -> int:
	if count == 0:
		return 0
	return wrapi(i, 0, count)


func index_at(s: float) -> int:
	if count == 0:
		return 0
	return wrap_index(int(floor(s / spacing)))


# Sample the centreline at a distance along the lap, interpolating between
# samples so the AI's look-ahead point moves smoothly rather than stepping.
func point_at(s: float) -> Dictionary:
	var i := index_at(s)
	var j := wrap_index(i + 1)
	var f := clampf((s - float(i) * spacing) / spacing, 0.0, 1.0)
	var p := points[i].lerp(points[j], f)
	var t := flat_tangents[i].lerp(flat_tangents[j], f).normalized()
	return {
		"position": p,
		"tangent": t,
		"curvature": lerpf(curvature[i], curvature[j], f),
		"right": Vector3(-t.z, 0.0, t.x),
		"s": s,
	}


func nearest(pos: Vector3) -> Dictionary:
	# Grid lookup with a coarse fallback, so a car that has thrown itself into the
	# scenery still gets a sensible answer instead of a wrong one.
	var best := -1
	var best_d := INF
	var key := _cell_key(pos)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var bucket: Variant = _cells.get(key + Vector2i(dx, dz))
			if bucket == null:
				continue
			for i: int in (bucket as PackedInt32Array):
				var d := _flat_distance_sq(pos, points[i])
				if d < best_d:
					best_d = d
					best = i
	if best < 0:
		var step := maxi(1, _coarse_step)
		var i := 0
		while i < count:
			var d := _flat_distance_sq(pos, points[i])
			if d < best_d:
				best_d = d
				best = i
			i += step
		if best >= 0:
			for k in range(maxi(0, best - step), mini(count, best + step + 1)):
				var d := _flat_distance_sq(pos, points[k])
				if d < best_d:
					best_d = d
					best = k
	if best < 0:
		return {"index": 0, "s": 0.0, "position": points[0] if count > 0 else Vector3.ZERO,
			"tangent": Vector3.FORWARD, "curvature": 0.0, "lateral": 0.0}
	var to_pos := pos - points[best]
	return {
		"index": best,
		"s": float(best) * spacing,
		"position": points[best],
		"tangent": flat_tangents[best],
		"curvature": curvature[best],
		"lateral": to_pos.dot(rights[best]),
	}


func _flat_distance_sq(a: Vector3, b: Vector3) -> float:
	var dx := a.x - b.x
	var dz := a.z - b.z
	return dx * dx + dz * dz


# Lateral distance from the centreline, positive to the right of the lap.
func lateral_of(pos: Vector3) -> float:
	var near := nearest(pos)
	return pos.dot(rights[near["index"]]) - points[near["index"]].dot(rights[near["index"]])


# Signed forward distance from one lap position to another, handling the wrap.
func forward_delta(from_s: float, to_s: float) -> float:
	var d := to_s - from_s
	if d > length * 0.5:
		d -= length
	elif d < -length * 0.5:
		d += length
	return d


func make_checkpoints(number: int, from_s := 0.0) -> void:
	checkpoint_indices = PackedInt32Array()
	if number <= 0 or count == 0:
		return
	var step := length / float(number)
	for k in number:
		checkpoint_indices.append(index_at(from_s + step * float(k)))


# True when the car crosses checkpoint `index`'s plane inside the road, in the
# direction of travel. Plane crossing rather than a trigger volume: it cannot be
# missed at 200 km/h and it cannot be cheated by cutting across the infield.
func crossed_checkpoint(index: int, previous: Vector3, current: Vector3) -> bool:
	var i := wrap_index(index)
	var here := (current - points[i]).dot(flat_tangents[i])
	var before := (previous - points[i]).dot(flat_tangents[i])
	if before > 0.0 or here < 0.0:
		return false
	var mid := current.lerp(previous, 0.5)
	var lateral := (mid - points[i]).dot(rights[i])
	return absf(lateral) <= half_width * 2.2


func grid_path_2d() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Vector3 in points:
		out.append(Vector2(p.x, p.z))
	return out
