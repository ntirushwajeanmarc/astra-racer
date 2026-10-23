class_name SpeedDial
extends Control
# Speed, gear and boost drawn as a dial rather than a number in a box: the arc
# length is readable at a glance while you are looking at the road.

var speed_kmh := 0.0
var max_kmh := 230.0
var gear := 1
var boost := 1.0
var rpm := 0.15
var slip := 0.0

var _shown := -1.0
var _shown_boost := -1.0
var _shown_gear := -99


func _process(_delta: float) -> void:
	if absf(_shown - speed_kmh) > 0.4 or absf(_shown_boost - boost) > 0.01 or _shown_gear != gear:
		_shown = speed_kmh
		_shown_boost = boost
		_shown_gear = gear
		queue_redraw()


func _draw() -> void:
	var centre := size * 0.5
	var radius := minf(size.x, size.y) * 0.40
	var start := deg_to_rad(138.0)
	var sweep := deg_to_rad(264.0)

	# Dial track and the speed arc.
	draw_arc(centre, radius, start, start + sweep, 72, Color(1, 1, 1, 0.14), 11.0, true)
	var fraction := clampf(speed_kmh / max_kmh, 0.0, 1.0)
	if fraction > 0.005:
		var colour := Color(0.36, 0.92, 0.48).lerp(Color(1.0, 0.34, 0.22), fraction)
		draw_arc(centre, radius, start, start + sweep * fraction, 72, colour, 11.0, true)
	# Redline ticks.
	for i in 9:
		var angle := start + sweep * (0.55 + 0.45 * float(i) / 8.0)
		var inner := centre + Vector2(cos(angle), sin(angle)) * (radius - 16.0)
		var outer := centre + Vector2(cos(angle), sin(angle)) * (radius - 8.0)
		draw_line(inner, outer, Color(1, 1, 1, 0.22), 2.0)

	# Boost ring inside the dial; glows when it is full and unused.
	var boost_colour := Color(0.35, 0.78, 1.0, 0.9)
	draw_arc(centre, radius * 0.70, start, start + sweep, 48, Color(1, 1, 1, 0.10), 6.0, true)
	draw_arc(centre, radius * 0.70, start, start + sweep * clampf(boost, 0.0, 1.0), 48, boost_colour, 6.0, true)

	var font := ThemeDB.fallback_font
	draw_string(font, centre + Vector2(-60, 26), "%d" % int(round(speed_kmh)),
		HORIZONTAL_ALIGNMENT_CENTER, 120, 46, Color(1, 1, 1, 0.96))
	draw_string(font, centre + Vector2(-60, 48), "km/h",
		HORIZONTAL_ALIGNMENT_CENTER, 120, 15, Color(1, 1, 1, 0.7))
	var gear_text := "R" if gear == 0 else str(gear)
	draw_string(font, centre + Vector2(-60, -18), gear_text,
		HORIZONTAL_ALIGNMENT_CENTER, 120, 30, Color(1.0, 0.94, 0.66, 0.95))
