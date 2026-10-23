class_name Layers
extends RefCounted
# The physics layers, in one place, because the difference between two of them
# is the difference between a circuit and a climbing frame.
#
# There were none at all to begin with: everything sat on Godot's default layer
# 1 and every mask was "everything". That is fine until something has to be
# able to see one part of the world and not another, and two things do.
#
# **A car must not take its ride height off a wall.** `Car` decides what it is
# standing on with four downward rays, and then `_apply_ground` moves the body
# to that height directly - it is a placement, not a force, so nothing stops
# it. A barrier is a closed ribbon with a top face, so a ray that catches that
# top face tells the car the ground is 1.4 m higher than it is; the car rises,
# more rays catch the wall, and it ratchets up until it is balanced on the
# barrier with its wheels hanging down either side. That is not a theory, it is
# a screenshot. So `OBSTACLE` is everything a car should hit but never stand
# on - barrier walls, buildings, tree trunks, lamp posts - and the ground rays
# are masked to `WORLD` alone.
#
# **A car must not ride up another car.** `CARS` is separate for the same
# reason: the rays ignore it, so a car tucked into someone's gearbox cannot
# take its ride height off their bodywork.
#
# `WORLD` is Godot's own default, so everything that *is* ground - the road,
# the kerbs, the verge, the terrain - is on it without having to say so, and
# anything new is ground until it opts out.
#
# Three layers, and every solid body in the world is put on one of them:
#
#   WORLD      the road, the kerbs and the verge, built by TrackBuilder, and the
#              terrain, which arrives as an imported scene. Left on Godot's
#              default, so none of it has to opt in.
#   CARS       the cars, and only the cars.
#   OBSTACLE   the barrier ribbon, the tree trunks, the lamp posts and the city's
#              buildings: everything a car hits, and none of it anything a car is
#              allowed to stand on.

const WORLD := 1       # bit 1: things a car drives on
const CARS := 2        # bit 2: the cars themselves
const OBSTACLE := 4    # bit 3: things a car hits and must never stand on

# What a car's body collides with: all of it.
const CAR_MASK := WORLD | CARS | OBSTACLE

# What a car's ground rays look for: the ground, and nothing else.
const GROUND_MASK := WORLD


# Put one body on the obstacle layer: something a car hits and must never take
# its ride height off.
#
# One body at a time, and deliberately not a walk of everything below a node. The
# version of this that moved every StaticBody3D under its argument onto OBSTACLE
# was written for the city, whose collision bodies the glTF importer creates and
# which therefore cannot be reached by name - but the terrain arrives the same
# way, and the terrain *is* ground. Pointed at the circuit it would have put the
# road and the hillside on OBSTACLE as well, the ground rays would have found
# nothing at all, and the car would have fallen out of the world. What a body is
# decides its layer; where it came from does not.
static func mark_obstacle(body: CollisionObject3D) -> void:
	body.collision_layer = OBSTACLE
