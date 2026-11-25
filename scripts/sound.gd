extends Node
## Every sound in the game goes through here (autoload "Sound").
##   Sound.play("clash")          a one-shot (variants clash1..4 are picked at random)
##   Sound.loop("fire", -12)      a looping bed, faded to that volume (-80 = off)
##   Sound.music("music_battle")  crossfades to that track
## M mutes everything. The files live in res://audio (see tools/gen_audio.py).

const DIR := "res://audio/"
## Names with numbered variants: "clash" -> clash1.wav .. clash4.wav
const VARIANTS := { "clash": 4, "hit": 3 }
## Mix: how loud each sound sits (dB). Tweak here.
const LEVEL := {
	"ui_click": -8.0, "ui_select": -10.0, "coin": -8.0, "order": -9.0, "signal": -6.0,
	"battle_start": -3.0, "rout": -8.0, "rally": -7.0, "clash": -15.0, "hit": -14.0,
	"bell": -7.0, "burned": -5.0, "scout": -6.0, "victory": -3.0, "defeat": -3.0,
}
const MUSIC_DB := -13.0
const FADE_DB_PER_SEC := 40.0
const POOL_SIZE := 24

var muted := false
var _streams := {} # file name -> AudioStream
var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _last_ms := {} # rate limiting per name
var _loops := {} # name -> { player, target }
var _music: AudioStreamPlayer
var _music_old: AudioStreamPlayer
var _music_name := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS # UI sounds while paused too
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_M:
		muted = not muted
		AudioServer.set_bus_mute(0, muted)


## A one-shot. `gap_ms` skips it if the same sound played that recently
## (a dozen soldiers falling in one frame shouldn't be a dozen thuds).
func play(name: String, db_offset := 0.0, pitch_spread := 0.06, gap_ms := 0) -> void:
	var now := Time.get_ticks_msec()
	if gap_ms > 0 and now - int(_last_ms.get(name, -100000)) < gap_ms:
		return
	_last_ms[name] = now
	var file := name
	if VARIANTS.has(name):
		file = "%s%d" % [name, randi_range(1, VARIANTS[name])]
	var stream := _stream(file)
	if stream == null:
		return
	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()
	p.stream = stream
	p.volume_db = float(LEVEL.get(name, -8.0)) + db_offset
	p.pitch_scale = 1.0 + randf_range(-pitch_spread, pitch_spread)
	p.play()


## A looping bed. Fades toward `db`; -80 fades it out and stops it.
func loop(name: String, db: float) -> void:
	if not _loops.has(name):
		if db <= -79.0:
			return
		var stream := _stream(name)
		if stream == null:
			return
		var p := AudioStreamPlayer.new()
		p.stream = stream
		p.volume_db = -60.0
		add_child(p)
		p.play()
		_loops[name] = { "player": p, "target": db }
	_loops[name].target = db


func stop_loops() -> void:
	for name in _loops:
		_loops[name].target = -80.0


## Crossfade to a music track ("" for silence).
func music(name: String) -> void:
	if name == _music_name:
		return
	_music_name = name
	if _music_old != null:
		_music_old.queue_free()
	_music_old = _music
	_music = null
	if name == "":
		return
	var stream := _stream(name)
	if stream == null:
		return
	_music = AudioStreamPlayer.new()
	_music.stream = stream
	_music.volume_db = -50.0
	add_child(_music)
	_music.play()


func _process(delta: float) -> void:
	var step := FADE_DB_PER_SEC * delta
	for name in _loops.keys():
		var l: Dictionary = _loops[name]
		var p: AudioStreamPlayer = l.player
		p.volume_db = move_toward(p.volume_db, l.target, step)
		if l.target <= -79.0 and p.volume_db <= -60.0:
			p.queue_free()
			_loops.erase(name)
	if _music != null:
		_music.volume_db = move_toward(_music.volume_db, MUSIC_DB, step * 0.5)
	if _music_old != null:
		_music_old.volume_db = move_toward(_music_old.volume_db, -60.0, step * 0.5)
		if _music_old.volume_db <= -59.0:
			_music_old.queue_free()
			_music_old = null


func _stream(file: String) -> AudioStream:
	if _streams.has(file):
		return _streams[file]
	var stream: AudioStream = null
	for ext in [".ogg", ".wav"]:
		if ResourceLoader.exists(DIR + file + ext):
			stream = load(DIR + file + ext)
			break
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true # every .ogg here is a loop
	_streams[file] = stream
	return stream
