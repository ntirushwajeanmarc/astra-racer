class_name MiniMap
extends Control
# The circuit outline with every car on it. Drawn from the same centreline the
# physics uses, so it cannot disagree with the track - and it is the fastest way
# for a player to understand a new circuit.

var info: TrackInfo
var cars: Array[Car] = []
var player: Car

# The smallest gap, in pixels, between two kept points of the outline. The
# circuit is sampled every two metres, which on a 14 km lap is 7 181 points, and
# a map 200 pixels wide cannot show a tenth of them: keeping them all is a
# polyline of 7 181 antialiased segments redrawn every frame for a picture
# identical to one with 300. This is the difference between a minimap that costs
# nothing and one that is the most expensive thing on the Kigali HUD.
const MIN_STEP_PX := 1.5

var _path := PackedVector2Array()
var _bounds := Rect2()
var _margin := 8.0

# The outline already projected into this control's pixels. The track does not
# move, so this is built once and rebuilt only if the control is resized.
var _screen_path := PackedVector2Array()
var _screen_size := Vector2.ZERO
var _scale := 0.0
var _offset := Vector2.ZERO


func setup(p_info: TrackInfo, p_cars: Array[Car], p_player: Car) -> void:
	info = p_info
	cars = p_cars
	player = p_player
	_path = info.grid_path_2d()
	_bounds = Rect2(_path[0], Vector2.ZERO)
	for p: Vector2 in _path:
		_bounds = _bounds.expand(p)
	_screen_size = Vector2.ZERO          # force a rebuild at the next draw


func _process(_delta: float) -> void:
	queue_redraw()


# Projects the circuit into this control and drops the points too close together
# to see. Closing the loop explicitly matters: the last kept point is rarely the
# last point of the lap, so without it the outline has a gap at the start line.
func _rebuild_screen_path() -> void:
	_screen_size = size
	var inner := Rect2(
		Vector2(_margin, _margin),
		size - Vector2(_margin * 2.0, _margin * 2.0)
	)
	_scale = minf(inner.size.x / _bounds.size.x, inner.size.y / _bounds.size.y)
	_offset = inner.position + (inner.size - _bounds.size * _scale) * 0.5
	_screen_path = PackedVector2Array()
	var last := Vector2.INF
	for p: Vector2 in _path:
		var q := (p - _bounds.position) * _scale + _offset
		if last == Vector2.INF or q.distance_squared_to(last) >= MIN_STEP_PX * MIN_STEP_PX:
			_screen_path.append(q)
			last = q
	if _screen_path.size() > 1:
		_screen_path.append(_screen_path[0])


func _draw() -> void:
	if _path.is_empty() or _bounds.size.x <= 0.0:
		return
	if _screen_size != size or _screen_path.is_empty():
		_rebuild_screen_path()
	var scale := _scale
	var offset := _offset

	draw_polyline(_screen_path, Color(1, 1, 1, 0.30), 3.0, true)
	draw_circle(_to_screen(info.points[info.start_index], scale, offset), 3.0,
		Color(1, 1, 1, 0.85))
	for car in cars:
		var colour := _car_colour(car)
		var pos := _to_screen(car.global_position, scale, offset)
		# A dot says where a car is; only a nose says which way it is pointing, and
		# on a map seen from above that is the difference between racing and
		# looking like you are driving backwards.
		var forward := -car.global_transform.basis.z
		var heading := Vector2(forward.x, forward.z).normalized()
		if car == player:
			_draw_arrow(pos, heading, colour)
		else:
			draw_circle(pos, 2.6, colour)
			draw_line(pos, pos + heading * 5.5, colour, 1.6, true)


func _car_colour(car: Car) -> Color:
	match car.colour:
		"red": return Color(0.95, 0.25, 0.22)
		"green": return Color(0.35, 0.85, 0.40)
		"orange": return Color(0.98, 0.62, 0.18)
		"white": return Color(0.92, 0.92, 0.94)
	return Color(0.95, 0.95, 0.95)


# The player is the one car you have to be able to read at a glance, so it is a
# nose rather than a dot, outlined so it stays legible over the track line.
func _draw_arrow(pos: Vector2, heading: Vector2, colour: Color) -> void:
	var nose := pos + heading * 7.0
	var back := pos - heading * 3.5
	var side := Vector2(-heading.y, heading.x) * 4.2
	var shape := PackedVector2Array([nose, back + side, back - side])
	draw_colored_polygon(shape, colour)
	draw_polyline(PackedVector2Array([nose, back + side, back - side, nose]),
		Color(0.05, 0.05, 0.06, 0.75), 1.0, true)


func _to_screen(world: Vector3, scale: float, offset: Vector2) -> Vector2:
	var flat := Vector2(world.x, world.z)
	return (flat - _bounds.position) * scale + offset
