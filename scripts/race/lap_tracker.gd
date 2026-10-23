class_name LapTracker
extends RefCounted
# Validates a car's progress around the lap and times it.
#
# Checkpoints are crossed in order: only the next expected plane counts, so
# cutting the infield or driving backwards cannot complete a lap, and a lap time
# is only recorded when every gate was passed in sequence. This is the whole
# anti-cheat for the leaderboard, and it is pure logic with no engine
# dependencies, so the tests drive it directly.

var total_checkpoints := 0
var laps_target := 3

var next_checkpoint := 0
var lap := 0
var laps_done := 0
var finished := false
var lap_start_time := 0.0
var lap_times: Array[float] = []
var best_lap := 0.0
var last_lap := 0.0
var total_time := 0.0
var wrong_way_time := 0.0
var previous_position := Vector3.ZERO
var started := false
var last_checkpoint_time := 0.0
var missed_reset := 0

signal lap_completed(lap_number: int, lap_time: float)
signal race_finished(total_time: float, laps: Array)


func setup(track: TrackInfo, target_laps: int) -> void:
	total_checkpoints = track.checkpoint_indices.size()
	laps_target = target_laps
	next_checkpoint = 1 % maxi(1, total_checkpoints)
	lap = 1
	laps_done = 0
	finished = false
	lap_times.clear()
	best_lap = 0.0
	last_lap = 0.0
	total_time = 0.0
	started = false


func start(now: float) -> void:
	started = true
	lap_start_time = now
	last_checkpoint_time = now
	lap = 1
	next_checkpoint = 1 % maxi(1, total_checkpoints)


# Returns "checkpoint", "lap" or "" - what (if anything) happened this step.
func update(track: TrackInfo, position: Vector3, now: float) -> String:
	var event := ""
	if not started:
		previous_position = position
		return ""
	if total_checkpoints > 0:
		var index := track.checkpoint_indices[next_checkpoint]
		if track.crossed_checkpoint(index, previous_position, position):
			if next_checkpoint == 0:
				_complete_lap(now)
				event = "lap"
			else:
				event = "checkpoint"
			next_checkpoint = (next_checkpoint + 1) % total_checkpoints
			last_checkpoint_time = now
	previous_position = position
	return event


func _complete_lap(now: float) -> void:
	var lap_time := now - lap_start_time
	# A lap shorter than the minimum possible on foot is a teleport/respawn, not
	# a lap: throw it away rather than poisoning the best-lap table.
	if lap_time < 3.0:
		missed_reset += 1
		lap_start_time = now
		return
	lap_times.append(lap_time)
	last_lap = lap_time
	if best_lap <= 0.0 or lap_time < best_lap:
		best_lap = lap_time
	laps_done += 1
	lap_start_time = now
	lap = laps_done + 1
	lap_completed.emit(laps_done, lap_time)
	if laps_done >= laps_target and not finished:
		finished = true
		total_time = 0.0
		for t: float in lap_times:
			total_time += t
		race_finished.emit(total_time, lap_times.duplicate())


func lap_progress(track: TrackInfo, position: Vector3) -> float:
	if total_checkpoints == 0:
		return 0.0
	var done := float(laps_done) + float(next_checkpoint) / float(total_checkpoints)
	return done


func time_display() -> String:
	return format_time(last_lap if laps_done > 0 else current_lap_time())


func current_lap_time() -> float:
	return maxf(0.0, total_time + last_lap) if finished else 0.0


static func format_time(seconds: float) -> String:
	if seconds <= 0.0:
		return "--:--.---"
	var minutes := int(seconds) / 60
	var rest := seconds - float(minutes * 60)
	return "%d:%06.3f" % [minutes, rest]
