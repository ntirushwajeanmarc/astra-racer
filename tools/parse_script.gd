extends SceneTree
# Parses one script and exits non-zero if Godot's parser rejects it.
#
# Loading the script is the only way to get GDScript's real verdict:
# `godot --check-only --script X` exits 0 and prints nothing even for a file
# that cannot be parsed, so a build step built on it is a check that cannot fail.
# Loading one does report the error, but from inside a running tree, so this
# wrapper turns that into the exit code a caller can test.
#
#   godot --headless --path racer -s res://tools/parse_script.gd -- res://path/x.gd
#   -> "PARSE_SCRIPT=OK <path>"   exit 0
#   -> "PARSE_SCRIPT=FAIL <path>" exit 1

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("PARSE_SCRIPT=FAIL (no script given) (loaded=false can_instantiate=false)")
		quit(2)
		return
	var path: String = args[0]
	# The load prints the parser's own message, which is what makes a failure
	# diagnosable rather than just red. Note that it still hands back an object
	# when the script could not be parsed - a GDScript resource that exists and is
	# invalid - so "did load() return something" is not the question. Whether the
	# script can be instantiated is.
	var script: Variant = load(path)
	var loaded := script != null
	var instantiable := false
	if script is GDScript:
		instantiable = (script as GDScript).can_instantiate()
	var ok := loaded and instantiable
	print("PARSE_SCRIPT=%s %s (loaded=%s can_instantiate=%s)" % [
		"OK" if ok else "FAIL", path, loaded, instantiable,
	])
	quit(0 if ok else 1)
