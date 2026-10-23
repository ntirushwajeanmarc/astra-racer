class_name RaceRules
extends RefCounted
# Race control: the rules the circuit is raced under, and what happens when a
# driver breaks them.
#
# The game had almost none. Laps were validated by ordered checkpoints, which
# stops a lap being *completed* out of sequence, and that was the whole of it:
# the gates on Kigali are a kilometre apart, so between two of them a car could
# leave the road, drive where it liked and rejoin, and nothing noticed. Nothing
# noticed a car that was moving before the lights went out either, and hitting
# a barrier at 200 km/h cost a little speed and no time at all.
#
# So this is the part of the game that watches. It holds one record per car and
# is stepped once per physics frame by RaceManager, and it produces three kinds
# of consequence:
#
#   * **time penalties**, added to the car's race time. They are what a driver
#     pays for gaining an advantage - cutting the circuit, or jumping the start
#     - and they are shown as they are given, not sprung at the end.
#   * **damage**, which the car spends as engine power and top speed. That is
#     what a driver pays for hitting something, and it is paid in lap time by
#     being slower, which is the punishment that fits.
#   * **disqualification**, for a driver who will not stop doing it.
#
# Everything here is deterministic and reads only public state off the car, so
# the AI is judged by exactly the same rules as the player - which it has to
# be, because the self-test drives the player's car with an AI and would
# otherwise be testing a different game.

# --- track limits -----------------------------------------------------------
const LIMITS_GRACE := 0.45       # seconds fully off the road before it counts
const LIMITS_FREE := 2           # offences allowed per lap before it costs
const LIMITS_PENALTY := 2.0      # seconds, per offence after that
const LIMITS_REARM := 1.0        # seconds back on the road before it can recur

# --- the start --------------------------------------------------------------
const JUMP_DISTANCE := 0.6       # metres of movement before GO that is a jump
const JUMP_PENALTY := 5.0

# --- contact ----------------------------------------------------------------
const CONTACT_FLOOR := 6.0       # m/s of closing speed before it is a shunt
const CONTACT_HEAVY := 16.0      # m/s at which one hit is most of a car
const DAMAGE_REPAIR := 0.012     # per second, nursed back while driving clean

# --- wrong way --------------------------------------------------------------
const WRONG_WAY_WARN := 3.0      # seconds before race control says so
const WRONG_WAY_DQ := 18.0       # seconds, cumulative, before it is over

const DQ_PENALTY_SECONDS := 30.0 # total penalty that ends a driver's race

# One driver's record. Public, because the HUD and the results read it.
class Record extends RefCounted:
	var penalty := 0.0                  # seconds added to this car's race time
	var limits_offences := 0            # this lap
	var limits_total := 0               # the whole race
	var contacts := 0
	var damage := 0.0
	var jumped := false
	var disqualified := false
	var wrong_way_total := 0.0
	var notice := ""                    # what race control last said
	var notice_time := 0.0              # how long it has been saying it

	var _off_time := 0.0
	var _on_time := 0.0
	var _armed := true
	var _wrong_way_said := false


var records := {}                       # Car -> Record
var started := false                    # have the lights gone out
var log: Array[String] = []             # one line per ruling, for the results

var _grid := {}                         # Car -> where it was put on the grid


func watch(car: Car) -> void:
	records[car] = Record.new()
	_grid[car] = car.global_position
	car.impacted.connect(_on_impact.bind(car))
	# Off the car's own signal rather than off the player's reset key: the AI
	# respawns itself when it gets stuck, and a rule that only repairs the car
	# whose driver pressed a button is a different rule for the AI.
	car.respawned.connect(on_reset.bind(car))


func record(car: Car) -> Record:
	return records.get(car, null)


func penalty_for(car: Car) -> float:
	var r: Record = records.get(car, null)
	return 0.0 if r == null else r.penalty


# The lights go out. Anything that moved before this has already been booked.
func start() -> void:
	started = true


# ----------------------------------------------------------------- the rules

func step(delta: float, racing: bool) -> void:
	for car: Car in records:
		var r: Record = records[car]
		if r.notice_time > 0.0:
			r.notice_time = maxf(0.0, r.notice_time - delta)
			if r.notice_time <= 0.0:
				r.notice = ""
		if not started:
			_check_jump_start(car, r)
			continue
		if not racing or r.disqualified or car.finished:
			continue
		_check_track_limits(car, r, delta)
		_check_wrong_way(car, r, delta)
		_repair(car, r, delta)


# **Jump start.** The grid is not held: a car is free from the moment the scene
# comes up, so a driver *can* creep, and creeping is the thing being judged. A
# car that has moved more than JUMP_DISTANCE from where it was gridded before
# the lights go out has jumped the start, and pays for it once.
func _check_jump_start(car: Car, r: Record) -> void:
	if r.jumped or not _grid.has(car):
		return
	# Horizontally. A car is placed on its grid slot and then settles onto the
	# road under its own ride height, and measuring that settle as movement
	# would book the entire field before anyone had touched anything.
	var from: Vector3 = _grid[car]
	var moved := Vector2(car.global_position.x - from.x,
		car.global_position.z - from.z).length()
	if moved <= JUMP_DISTANCE:
		return
	r.jumped = true
	_book(car, r, JUMP_PENALTY, "JUMP START")


# **Track limits.** All four wheels off the road, for longer than a moment, is
# leaving the circuit. Two are free every lap, because a car can be put on the
# grass by someone else and that is racing; from the third it costs time.
#
# It is measured on the wheels rather than on the distance from the centreline
# because the kerb is part of the circuit and the grass beside it is not, and
# the wheels are the only thing that knows which is which.
func _check_track_limits(car: Car, r: Record, delta: float) -> void:
	var off := car.on_ground and car.wheels_on_ground > 0 and car.wheels_on_road == 0
	if off:
		r._on_time = 0.0
		r._off_time += delta
		if r._armed and r._off_time >= LIMITS_GRACE:
			r._armed = false
			r.limits_offences += 1
			r.limits_total += 1
			if r.limits_offences > LIMITS_FREE:
				_book(car, r, LIMITS_PENALTY, "TRACK LIMITS")
			else:
				_say(r, "TRACK LIMITS - WARNING %d/%d"
					% [r.limits_offences, LIMITS_FREE])
	else:
		r._off_time = 0.0
		r._on_time += delta
		if r._on_time >= LIMITS_REARM:
			r._armed = true


# **Wrong way.** Already shown on the HUD, and previously that was all it was.
# The ordered checkpoints mean driving backwards cannot complete a lap, but a
# driver who sits the wrong way round on a racing line is a hazard to everyone
# else, so it is warned and then it ends the race.
func _check_wrong_way(car: Car, r: Record, delta: float) -> void:
	if not car.wrong_way or car.speed_kmh() < 12.0:
		return
	r.wrong_way_total += delta
	if not r._wrong_way_said and r.wrong_way_total >= WRONG_WAY_WARN:
		r._wrong_way_said = true
		_say(r, "WRONG WAY - TURN AROUND")
	if r.wrong_way_total >= WRONG_WAY_DQ:
		_disqualify(car, r, "driving against the circuit")


# **Contact.** Anything solid: a barrier, a building, a tree, another car. The
# car reports the closing speed of its worst hit this frame and that is the
# whole scale - a brush at 6 m/s is nothing, a 16 m/s shunt is most of a car.
#
# The consequence is damage, not a time penalty. A driver who hits a wall has
# already lost the time; taking more on top of it is punishing the same mistake
# twice. What damage does is make the *next* corner slower too, which is what
# an accident actually costs.
func _on_impact(strength: float, car: Car) -> void:
	var r: Record = records.get(car, null)
	if r == null or r.disqualified:
		return
	if strength < CONTACT_FLOOR:
		return
	r.contacts += 1
	var share := clampf((strength - CONTACT_FLOOR)
		/ (CONTACT_HEAVY - CONTACT_FLOOR), 0.0, 1.0)
	r.damage = clampf(r.damage + share * 0.55, 0.0, 1.0)
	car.damage = r.damage
	if share > 0.35:
		_say(r, "DAMAGE %d%%" % int(round(r.damage * 100.0)))


# Damage is nursed back, slowly, by driving cleanly. Not repaired - a car that
# can undo a shunt by waiting has not been punished - but a driver who has one
# accident early should not be driving a broken car for six minutes.
func _repair(car: Car, r: Record, delta: float) -> void:
	if r.damage <= 0.0:
		return
	if car.speed_kmh() < 25.0:
		return
	r.damage = maxf(0.0, r.damage - DAMAGE_REPAIR * delta)
	car.damage = r.damage


# A car reset by its driver comes back whole, and gives up the time it takes.
func on_reset(car: Car) -> void:
	var r: Record = records.get(car, null)
	if r == null:
		return
	r.damage = 0.0
	car.damage = 0.0


# The start of a new lap: the two free excursions come back.
func on_lap(car: Car) -> void:
	var r: Record = records.get(car, null)
	if r != null:
		r.limits_offences = 0


# ---------------------------------------------------------------- the rulings

func _book(car: Car, r: Record, seconds: float, reason: String) -> void:
	r.penalty += seconds
	_say(r, "%s  +%.0fs" % [reason, seconds])
	log.append("%s: %s, +%.0fs" % [car.driver_name, reason.to_lower(), seconds])
	if r.penalty >= DQ_PENALTY_SECONDS:
		_disqualify(car, r, "accumulated penalties")


func _disqualify(car: Car, r: Record, reason: String) -> void:
	if r.disqualified:
		return
	r.disqualified = true
	_say(r, "DISQUALIFIED")
	log.append("%s: disqualified - %s" % [car.driver_name, reason])


func _say(r: Record, text: String) -> void:
	r.notice = text
	r.notice_time = 3.5


# What the results screen and the self-test print. One line per driver who was
# ruled against, and nothing at all for a clean race - which is the point of
# the race being clean.
func summary() -> Array[String]:
	return log.duplicate()
