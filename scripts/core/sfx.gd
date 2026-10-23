extends Node
# Sfx: the generated audio bank (see tools/make_audio.py - no downloaded
# samples). The engine and tyre loops are looping players whose pitch and
# volume are driven by the car; everything else is a one-shot.
#
# Looping is set here rather than in the .import files so the WAVs stay plain
# assets that any audio editor can open.

const BANK := {
	"engine": "res://audio/engine_loop.wav",
	"screech": "res://audio/screech_loop.wav",
	"impact": "res://audio/impact.wav",
	"beep_low": "res://audio/beep_low.wav",
	"beep_high": "res://audio/beep_high.wav",
	"chime": "res://audio/chime.wav",
	"click": "res://audio/click.wav",
}
const LOOPS := ["engine", "screech"]

var _streams: Dictionary = {}
var _oneshots: Array[AudioStreamPlayer] = []
var _pool_size := 8


func _ready() -> void:
	for name: String in BANK:
		var stream: AudioStream = load(BANK[name])
		if stream == null:
			push_warning("Sfx: missing audio asset %s" % BANK[name])
			continue
		if name in LOOPS and stream is AudioStreamWAV:
			var wav := stream as AudioStreamWAV
			wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
			wav.loop_begin = 0
			wav.loop_end = wav.data.size() / 2  # 16-bit mono: 2 bytes per frame
		_streams[name] = stream

	for i in _pool_size:
		var player := AudioStreamPlayer.new()
		add_child(player)
		_oneshots.append(player)


func has_sound(name: String) -> bool:
	return _streams.has(name)


# Cars own their own positional players and pull the shared streams from here,
# so one generated bank serves the whole grid with per-car pitch and panning.
func stream(name: String) -> AudioStream:
	return _streams.get(name)


func play(sound: String, volume_db := -6.0, pitch := 1.0) -> void:
	var stream: AudioStream = _streams.get(sound)
	if stream == null:
		return
	for player in _oneshots:
		if not player.playing:
			player.stream = stream
			player.volume_db = volume_db
			player.pitch_scale = pitch
			player.play()
			return
