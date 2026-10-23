class_name TrackData
extends RefCounted
# The circuits, as control points. Each is a closed loop the builder smooths
# with Catmull-Rom and resamples at even spacing.
#
# Two design rules keep them drivable, and both are asserted by the test suite:
# no two parts of the centreline come closer than the road is wide (no invisible
# pinch points), and no corner demands more than the tyres can give.

const SUNSET := {
	"name": "Sunset Speedway",
	"blurb": "Long main straight, one huge sweeper, a chicane that rewards bravery.",
	"half_width": 6.0,
	"laps": 3,
	"start_s": 45.0,
	"checkpoints": 12,
	"sky_top": Color(0.16, 0.30, 0.62),
	"sky_horizon": Color(0.98, 0.63, 0.34),
	"sun_energy": 1.35,
	"sun_angle": Vector3(-24.0, 138.0, 0.0),
	"fog": Color(0.72, 0.60, 0.55),
	"points": [
		Vector3(0, 0, 60), Vector3(0, 0, -100), Vector3(0, 0, -250),
		Vector3(35, 0, -330), Vector3(120, 0, -372), Vector3(215, 0, -368),
		Vector3(292, 0, -322), Vector3(342, 0, -240), Vector3(362, 0, -140),
		Vector3(352, 1, -40), Vector3(310, 2, 50), Vector3(240, 3, 140),
		Vector3(160, 4, 178), Vector3(74, 3, 176), Vector3(8, 1, 122),
	],
}

const ALPINE := {
	"name": "Alpine Loop",
	"blurb": "The mirror of the Speedway, tighter and hilly - the technical one.",
	"half_width": 5.2,
	"laps": 3,
	"start_s": 40.0,
	"checkpoints": 14,
	"sky_top": Color(0.10, 0.22, 0.48),
	"sky_horizon": Color(0.72, 0.80, 0.86),
	"sun_energy": 1.15,
	"sun_angle": Vector3(-30.0, 40.0, 0.0),
	"fog": Color(0.70, 0.76, 0.80),
	"mirror": true,
	"scale": 0.82,
	"hill_amplitude": 6.5,
	"points": [],
}

const KIGALI := {
	"name": "KIGALI",
	"blurb": "Kigali, Rwanda - the 2025 World Championships local circuit, on the city's own streets.",
	"half_width": 5.0,
	"laps": 3,
	"start_s": 45.0,
	"checkpoints": 14,
	# A drawn sky rather than a gradient: over a city on a ridge the sky is a
	# third of the frame for most of the lap, and it is also the only light the
	# shadowed side of every hill gets. Built by tools/make_sky.py with the sun
	# at the same angle as the light below, so the glare and the shadows agree.
	"sky": "res://assets/sky/kigali_sky.png",
	"sky_energy": 1.2,
	"ambient": 0.85,
	"sun_energy": 1.45,
	"sun_colour": Color(1.0, 0.96, 0.89),
	"sun_angle": Vector3(-32.0, 120.0, 0.0),
	# Kigali's own haze: pale and slightly blue, not the beige of dust, and
	# thin, because the circuit's whole character is the view across the valley
	# to the city on the hill opposite.
	"fog": Color(0.74, 0.80, 0.86),
	"fog_density": 0.00030,
	"fog_sky_affect": 0.10,
		# The real ground, from a 30 m elevation model of Kigali, placed in this
		# circuit's own frame. Y is metres above the lowest point of the model, so
		# the 1392 m the circuit bottom sits at is 23.5 m above the model's zero.
		"terrain": {
			"model": "res://assets/terrain/kigali_terrain.glb",
			"position": Vector3(-305.5, -23.5, -311.1),
			# How far the ground stands above the road just outside the
			# barrier, at every sample of the lap. The barrier is built to
			# stand proud of it: see TrackBuilder._wall_height_at.
			"shoulders": "res://assets/terrain/kigali_shoulders.json",
		},
		# The city itself: every building OpenStreetMap knows about inside the
		# elevation model, 28 197 of them, with the roofs, materials and heights
		# their own tags describe. Built by `tools/build_city.py` into chunks so
		# the far half of Kigali costs nothing to not be looking at, and in the
		# same frame as the elevation model above so it stands on its own
		# hillside. The chunks near the racing line carry collision.
		"buildings": {
			"model": "res://assets/terrain/kigali_city.glb",
			"position": Vector3(-305.5, -23.5, -311.1),
			"manifest": "res://assets/terrain/kigali_city.json",
			"landmarks": "res://assets/terrain/kigali_city_landmarks.json",
			# Beyond this a chunk is not drawn. 1.6 km up a hillside is further
			# than the haze lets you see anyway, and it is the difference
			# between 185 chunks in the frustum and about twenty.
			"draw_distance": 1600.0,
		},
		# A street circuit's roadside is the city, not parkland. The defaults in
		# TrackBuilder scatter fourteen grandstands and a forest along the lap,
		# which on a street in Kigali reads as the furniture of a different
		# track left lying about. What stays is a thin line of street trees in
		# the corridor cleared for the road, and one grandstand at the start
		# line, which is where a real street race puts one.
		"scenery": {
			# An avenue, not a forest. Kigali plants its streets, and the strip
			# the city build leaves clear of buildings either side of the road
			# is exactly where those trees stand - so the band here is inside
			# that clearance, and inside the flat part of the graded corridor,
			# which is what keeps every trunk on the ground rather than
			# floating over a hillside the road does not follow.
			"tree_chance": 0.42,
			# Far enough out that the canopy clears the barrier. At 1 m the
			# trunks stood half a metre outside it and the canopies hung over
			# the racing line, which looked wrong and - now the trunks are
			# solid - would have been worse than wrong.
			"tree_offset": Vector2(2.6, 7.0),
			"tree_scale": Vector2(4.0, 8.0),
			"tree_large_share": 0.45,
			"grandstands": 3,
			"grandstand_near_start": 130.0,
			"grandstand_offset": 15.0,
			"pylons": false,
		},
	"points": [
		Vector3(-36.3, 100.5, 1186.7), Vector3(4.1, 102.0, 1206.4), Vector3(46.4, 103.1, 1221.8), Vector3(89.7, 103.9, 1233.9),
		Vector3(133.8, 104.2, 1242.8), Vector3(178.4, 104.6, 1248.9), Vector3(223.4, 105.2, 1250.3), Vector3(268.1, 105.9, 1247.9),
		Vector3(306.6, 105.9, 1225.0), Vector3(350.2, 106.2, 1214.3), Vector3(395.1, 106.4, 1212.8), Vector3(439.1, 106.3, 1203.3),
		Vector3(483.1, 106.7, 1194.0), Vector3(527.1, 107.0, 1184.6), Vector3(571.2, 106.9, 1175.4), Vector3(615.3, 106.4, 1166.7),
		Vector3(659.3, 105.8, 1157.3), Vector3(703.4, 104.7, 1148.3), Vector3(747.8, 103.1, 1140.7), Vector3(792.2, 101.1, 1133.4),
		Vector3(837.0, 99.2, 1130.0), Vector3(882.0, 97.0, 1130.3), Vector3(926.8, 95.0, 1134.9), Vector3(970.9, 93.5, 1143.8),
		Vector3(1014.8, 92.2, 1151.3), Vector3(1049.3, 90.8, 1123.7), Vector3(1067.7, 89.8, 1082.8), Vector3(1090.0, 88.9, 1043.8),
		Vector3(1119.4, 88.2, 1009.7), Vector3(1145.2, 87.1, 972.9), Vector3(1162.1, 85.8, 931.3), Vector3(1171.3, 85.2, 887.3),
		Vector3(1180.9, 84.7, 843.3), Vector3(1188.6, 84.3, 799.0), Vector3(1195.8, 84.2, 754.6), Vector3(1203.3, 83.9, 710.2),
		Vector3(1211.2, 83.1, 665.9), Vector3(1221.3, 82.6, 622.0), Vector3(1231.3, 83.0, 578.2), Vector3(1239.5, 83.4, 533.9),
		Vector3(1240.7, 83.0, 489.0), Vector3(1241.3, 82.6, 444.0), Vector3(1242.0, 82.0, 399.0), Vector3(1242.6, 81.3, 354.0),
		Vector3(1244.3, 80.3, 309.0), Vector3(1250.5, 80.0, 264.4), Vector3(1254.3, 80.0, 219.6), Vector3(1250.1, 79.3, 174.9),
		Vector3(1242.8, 78.7, 130.5), Vector3(1234.9, 78.0, 86.2), Vector3(1226.4, 76.6, 42.0), Vector3(1217.9, 75.1, -2.2),
		Vector3(1209.4, 73.8, -46.4), Vector3(1199.2, 72.5, -90.2), Vector3(1184.8, 71.2, -132.8), Vector3(1169.5, 68.9, -175.1),
		Vector3(1149.0, 66.8, -215.2), Vector3(1127.7, 64.6, -254.9), Vector3(1105.8, 62.0, -294.1), Vector3(1081.0, 59.9, -331.7),
		Vector3(1056.7, 57.3, -369.6), Vector3(1033.7, 54.9, -408.3), Vector3(1011.1, 53.0, -447.2), Vector3(988.5, 51.2, -486.0),
		Vector3(965.8, 50.3, -524.9), Vector3(942.6, 49.7, -563.5), Vector3(916.8, 49.7, -600.3), Vector3(889.2, 50.6, -635.8),
		Vector3(860.4, 52.1, -670.4), Vector3(826.6, 54.2, -700.1), Vector3(792.4, 56.9, -729.3), Vector3(758.8, 59.3, -759.2),
		Vector3(728.3, 61.6, -792.3), Vector3(702.4, 64.2, -829.1), Vector3(679.7, 66.3, -867.9), Vector3(662.7, 68.1, -909.5),
		Vector3(655.2, 70.0, -953.8), Vector3(657.7, 72.0, -998.7), Vector3(663.2, 73.5, -1043.3), Vector3(672.2, 73.6, -1087.4),
		Vector3(680.7, 73.8, -1131.6), Vector3(689.5, 73.7, -1175.7), Vector3(699.9, 73.1, -1219.5), Vector3(714.9, 72.8, -1261.9),
		Vector3(737.2, 72.6, -1300.9), Vector3(757.8, 71.5, -1340.9), Vector3(770.9, 69.8, -1383.9), Vector3(777.2, 68.0, -1428.4),
		Vector3(780.4, 66.2, -1473.3), Vector3(777.9, 64.4, -1518.1), Vector3(760.5, 62.3, -1559.4), Vector3(731.8, 60.5, -1594.0),
		Vector3(702.8, 58.3, -1628.4), Vector3(674.7, 56.6, -1663.6), Vector3(646.5, 55.3, -1698.6), Vector3(618.3, 54.6, -1733.7),
		Vector3(590.1, 54.8, -1768.8), Vector3(561.9, 55.6, -1803.8), Vector3(533.0, 57.0, -1838.3), Vector3(503.4, 58.6, -1872.2),
		Vector3(470.9, 60.1, -1903.1), Vector3(428.4, 61.5, -1916.8), Vector3(383.8, 61.8, -1912.5), Vector3(339.8, 61.6, -1903.2),
		Vector3(301.2, 60.6, -1880.9), Vector3(279.9, 58.1, -1841.6), Vector3(271.9, 55.4, -1797.6), Vector3(283.4, 52.5, -1754.2),
		Vector3(301.4, 50.2, -1714.2), Vector3(343.1, 47.7, -1714.9), Vector3(359.0, 45.6, -1755.7), Vector3(372.9, 44.0, -1797.6),
		Vector3(410.5, 42.8, -1818.7), Vector3(450.6, 41.7, -1802.2), Vector3(477.0, 41.7, -1765.8), Vector3(504.2, 42.2, -1730.1),
		Vector3(535.5, 42.7, -1697.7), Vector3(564.9, 42.8, -1663.7), Vector3(585.6, 42.7, -1624.0), Vector3(594.3, 42.5, -1580.0),
		Vector3(593.8, 41.8, -1535.0), Vector3(584.6, 40.6, -1491.1), Vector3(562.6, 39.4, -1452.3), Vector3(527.9, 38.1, -1423.9),
		Vector3(488.0, 35.9, -1403.0), Vector3(448.7, 34.0, -1381.3), Vector3(414.4, 32.5, -1352.3), Vector3(389.7, 31.2, -1315.0),
		Vector3(383.4, 30.7, -1271.1), Vector3(395.0, 30.5, -1227.7), Vector3(409.9, 30.7, -1185.3), Vector3(419.6, 30.4, -1141.4),
		Vector3(419.1, 30.0, -1096.6), Vector3(403.4, 30.2, -1054.8), Vector3(372.4, 29.8, -1022.6), Vector3(336.0, 29.1, -996.1),
		Vector3(302.1, 28.5, -966.6), Vector3(271.3, 27.2, -933.8), Vector3(245.8, 26.1, -896.8), Vector3(229.5, 24.9, -855.0),
		Vector3(224.8, 23.8, -810.4), Vector3(236.0, 22.3, -767.4), Vector3(264.7, 20.5, -733.2), Vector3(294.2, 18.4, -700.0),
		Vector3(298.8, 16.3, -656.7), Vector3(283.6, 14.2, -614.3), Vector3(271.3, 12.4, -571.1), Vector3(261.4, 10.7, -527.2),
		Vector3(251.0, 9.4, -483.4), Vector3(240.6, 8.7, -439.6), Vector3(230.9, 9.1, -395.7), Vector3(223.3, 10.4, -351.3),
		Vector3(216.8, 11.9, -306.8), Vector3(211.6, 13.6, -262.1), Vector3(210.5, 15.5, -217.2), Vector3(207.0, 17.4, -172.5),
		Vector3(189.3, 19.0, -131.5), Vector3(162.9, 20.9, -95.1), Vector3(133.7, 23.0, -60.9), Vector3(95.2, 24.7, -39.0),
		Vector3(50.5, 26.0, -35.8), Vector3(5.6, 27.7, -36.4), Vector3(-37.7, 29.3, -25.2), Vector3(-77.6, 30.7, -4.4),
		Vector3(-119.2, 31.8, 12.0), Vector3(-162.7, 32.7, 6.3), Vector3(-191.1, 32.8, -27.1), Vector3(-190.3, 32.8, -71.0),
		Vector3(-165.7, 32.2, -108.3), Vector3(-132.9, 31.2, -139.1), Vector3(-104.0, 29.4, -173.4), Vector3(-86.6, 26.8, -214.6),
		Vector3(-79.0, 24.2, -259.0), Vector3(-72.6, 21.6, -303.5), Vector3(-64.8, 19.7, -347.8), Vector3(-58.3, 18.8, -392.3),
		Vector3(-56.4, 18.5, -437.2), Vector3(-65.8, 19.3, -481.0), Vector3(-98.7, 20.9, -507.9), Vector3(-138.3, 23.2, -492.2),
		Vector3(-165.4, 26.5, -456.3), Vector3(-195.4, 31.1, -422.9), Vector3(-228.9, 36.0, -393.0), Vector3(-259.3, 41.0, -359.8),
		Vector3(-285.5, 45.9, -323.3), Vector3(-311.1, 50.2, -286.3), Vector3(-339.6, 54.4, -251.5), Vector3(-370.6, 58.6, -218.9),
		Vector3(-395.3, 62.7, -181.7), Vector3(-406.8, 66.4, -138.3), Vector3(-413.5, 69.1, -93.8), Vector3(-425.8, 71.5, -50.6),
		Vector3(-447.3, 73.6, -11.2), Vector3(-478.0, 75.3, 21.5), Vector3(-511.3, 76.8, 51.7), Vector3(-528.5, 77.3, 91.5),
		Vector3(-512.1, 77.1, 132.1), Vector3(-478.7, 76.9, 162.2), Vector3(-443.2, 76.5, 189.9), Vector3(-407.3, 76.3, 216.9),
		Vector3(-370.7, 75.8, 243.1), Vector3(-333.8, 75.5, 268.9), Vector3(-297.0, 76.0, 294.7), Vector3(-260.0, 76.3, 320.4),
		Vector3(-223.2, 77.1, 346.2), Vector3(-187.6, 78.1, 373.8), Vector3(-154.1, 78.8, 403.9), Vector3(-123.4, 80.3, 436.7),
		Vector3(-96.8, 81.5, 473.0), Vector3(-75.0, 82.4, 512.3), Vector3(-58.6, 83.2, 554.1), Vector3(-47.4, 83.4, 597.7),
		Vector3(-40.3, 84.2, 642.1), Vector3(-36.9, 85.2, 687.0), Vector3(-38.4, 85.6, 731.9), Vector3(-41.2, 85.6, 776.8),
		Vector3(-45.1, 85.4, 821.6), Vector3(-70.8, 85.5, 855.3), Vector3(-114.8, 85.8, 861.9), Vector3(-157.0, 85.7, 872.8),
		Vector3(-181.5, 85.0, 909.1), Vector3(-190.8, 83.3, 953.2), Vector3(-211.2, 81.0, 992.1), Vector3(-252.6, 78.8, 1001.7),
		Vector3(-293.2, 77.7, 982.7), Vector3(-332.0, 75.7, 960.0), Vector3(-372.3, 72.8, 939.9), Vector3(-413.6, 69.8, 922.1),
		Vector3(-455.8, 67.2, 906.4), Vector3(-498.4, 65.2, 892.0), Vector3(-541.4, 63.5, 878.6), Vector3(-585.0, 62.2, 867.6),
		Vector3(-629.3, 62.0, 859.8), Vector3(-673.8, 61.9, 853.5), Vector3(-718.3, 62.6, 846.7), Vector3(-763.0, 64.4, 841.2),
		Vector3(-807.4, 65.8, 845.7), Vector3(-847.3, 67.2, 865.8), Vector3(-888.1, 68.2, 883.4), Vector3(-930.0, 69.3, 872.3),
		Vector3(-963.3, 69.8, 842.1), Vector3(-994.6, 69.3, 809.8), Vector3(-1026.5, 68.0, 778.0), Vector3(-1058.2, 66.3, 746.2),
		Vector3(-1088.2, 64.2, 712.6), Vector3(-1115.8, 62.5, 677.1), Vector3(-1143.3, 60.1, 641.5), Vector3(-1171.8, 57.8, 606.7),
		Vector3(-1200.6, 55.1, 572.1), Vector3(-1229.4, 52.9, 537.5), Vector3(-1257.8, 50.4, 502.6), Vector3(-1286.1, 47.9, 467.6),
		Vector3(-1317.8, 45.2, 435.8), Vector3(-1354.8, 42.8, 410.3), Vector3(-1394.7, 39.8, 389.5), Vector3(-1435.7, 36.8, 371.0),
		Vector3(-1477.6, 33.5, 354.6), Vector3(-1520.4, 30.2, 340.6), Vector3(-1563.8, 26.7, 329.0), Vector3(-1607.6, 23.6, 318.4),
		Vector3(-1651.3, 20.6, 307.8), Vector3(-1694.9, 17.8, 296.6), Vector3(-1739.1, 14.4, 288.4), Vector3(-1783.9, 11.4, 289.7),
		Vector3(-1826.4, 8.7, 304.1), Vector3(-1861.9, 6.9, 331.3), Vector3(-1887.0, 6.1, 368.4), Vector3(-1900.1, 6.2, 411.3),
		Vector3(-1902.6, 7.2, 456.1), Vector3(-1878.7, 8.9, 490.7), Vector3(-1838.9, 11.6, 477.5), Vector3(-1822.5, 14.8, 436.3),
		Vector3(-1801.0, 18.7, 397.6), Vector3(-1760.4, 23.4, 381.6), Vector3(-1718.4, 28.3, 395.6), Vector3(-1683.7, 32.8, 424.0),
		Vector3(-1656.1, 36.8, 459.4), Vector3(-1633.4, 40.4, 498.3), Vector3(-1611.4, 44.4, 537.5), Vector3(-1589.4, 47.2, 576.8),
		Vector3(-1562.8, 49.7, 612.9), Vector3(-1525.5, 52.0, 637.4), Vector3(-1482.3, 54.1, 649.5), Vector3(-1438.2, 56.3, 658.9),
		Vector3(-1394.5, 58.4, 669.6), Vector3(-1352.0, 59.8, 684.2), Vector3(-1312.6, 61.3, 705.8), Vector3(-1276.8, 62.5, 732.9),
		Vector3(-1242.6, 64.0, 762.2), Vector3(-1208.6, 66.0, 791.8), Vector3(-1174.6, 68.0, 821.2), Vector3(-1140.5, 70.1, 850.6),
		Vector3(-1106.4, 71.7, 879.9), Vector3(-1072.3, 73.0, 909.3), Vector3(-1038.9, 74.4, 939.5), Vector3(-1004.8, 75.3, 968.8),
		Vector3(-962.4, 75.5, 980.9), Vector3(-923.8, 74.8, 960.6), Vector3(-892.4, 73.4, 928.4), Vector3(-859.2, 72.1, 898.0),
		Vector3(-822.4, 70.4, 872.3), Vector3(-779.4, 68.6, 860.2), Vector3(-734.6, 67.0, 863.1), Vector3(-690.2, 66.1, 870.1),
		Vector3(-645.6, 66.0, 876.4), Vector3(-601.2, 65.7, 883.5), Vector3(-557.4, 66.5, 893.6), Vector3(-514.3, 68.1, 906.5),
		Vector3(-471.6, 69.8, 920.7), Vector3(-429.2, 72.0, 936.0), Vector3(-387.7, 74.5, 953.4), Vector3(-347.3, 77.6, 973.1),
		Vector3(-308.2, 80.8, 995.3), Vector3(-269.2, 83.8, 1017.8), Vector3(-230.5, 87.3, 1040.7), Vector3(-193.5, 90.6, 1066.4),
		Vector3(-158.7, 93.3, 1094.9), Vector3(-124.1, 95.8, 1123.6), Vector3(-88.2, 98.4, 1150.8),
	],
}

const LIST := [SUNSET, ALPINE, KIGALI]


static func track_count() -> int:
	return LIST.size()


static func get_track(index: int) -> Dictionary:
	return LIST[clampi(index, 0, LIST.size() - 1)]


# The control points of one circuit, after any mirroring/scaling/hills, as a
# packed array the builder can smooth.
static func control_points(track: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	var source: Array = track["points"]
	if bool(track.get("mirror", false)) and source.is_empty():
		source = SUNSET["points"]
	var scale := float(track.get("scale", 1.0))
	var mirror := bool(track.get("mirror", false))
	var amplitude := float(track.get("hill_amplitude", 0.0))
	var n := source.size()
	for i in n:
		var p: Vector3 = source[i]
		var x := -p.x if mirror else p.x
		var y := p.y
		var t := float(i) / float(n)
		if amplitude > 0.0:
			# Whole numbers of cycles keep the loop closed and the seams smooth.
			y += amplitude * sin(TAU * 2.0 * t) * 0.6
			y += amplitude * 0.4 * sin(TAU * 3.0 * t + 0.7)
		out.append(Vector3(x * scale, y * maxf(0.4, scale), p.z * scale))
	# A mirrored loop runs the other way round, so reverse it to keep lap
	# direction consistent with the start line the builder places.
	if mirror:
		out.reverse()
	return out


# Catmull-Rom through the control points, closed, then resampled so the samples
# are *exactly* evenly spaced. The sample count is derived from the loop's true
# length rather than assumed, which is what stops a seam appearing where a walk
# runs out of polyline before the circuit is closed.
static func sample_loop(control: PackedVector3Array, spacing: float) -> PackedVector3Array:
	var n := control.size()
	if n < 3:
		return control
	var dense := PackedVector3Array()
	var per_segment := 24
	for i in n:
		var p0 := control[(i - 1 + n) % n]
		var p1 := control[i]
		var p2 := control[(i + 1) % n]
		var p3 := control[(i + 2) % n]
		for k in per_segment:
			dense.append(_catmull(p0, p1, p2, p3, float(k) / float(per_segment)))

	var segments := PackedFloat32Array()
	var total := 0.0
	for i in dense.size():
		var length := dense[i].distance_to(dense[(i + 1) % dense.size()])
		segments.append(length)
		total += length

	var count := maxi(16, int(round(total / maxf(0.01, spacing))))
	var step := total / float(count)
	var out := PackedVector3Array()
	var index := 0
	var walked := 0.0
	var travelled := 0.0
	var target := 0.0
	var guard := 0
	while out.size() < count and guard < count * 8:
		guard += 1
		var remaining := segments[index] - travelled
		if walked + remaining >= target:
			travelled += target - walked
			walked = target
			var t := clampf(travelled / maxf(segments[index], 0.0001), 0.0, 1.0)
			out.append(dense[index].lerp(dense[(index + 1) % dense.size()], t))
			target += step
		else:
			walked += remaining
			travelled = 0.0
			index = (index + 1) % dense.size()
	return out if not out.is_empty() else dense


static func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)
