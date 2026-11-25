extends Node2D
## PROTOTYPE v2: soldier-by-soldier fighting inside formations.
## Every man has his own health and swings on his own timer, but he keeps his
## place in his squad's block: only the men at the edge that touches an enemy
## step out (a short lunge) to fight. Blocks keep their shape, so lines and
## flanks stay readable. Flank and rear are judged against the block's facing.
## Run this scene on its own (F6 in the editor).
##
## Left-click / drag: select squads      Right-click: move (on an enemy: attack)
## Right-drag: move + facing      1-4: select      Space: pause      R: restart
## Wheel / middle-drag: camera      Home: reset camera

const PLAYER_COLOR := Color(0.3, 0.6, 1.0)
const ENEMY_COLOR := Color(0.9, 0.3, 0.3)
const FLANK_COLOR := Color(1.0, 0.45, 0.2)

# Soldiers
const HP := 10.0
const MAN_SPEED := 95.0 # men keep up with their block (and step out to fight)
const FLEE_SPEED := 78.0
const REACH := 12.0 # melee range, centre to centre
const LUNGE := 7.0 # how far a man steps out of his place to fight
const SWING_TIME := 1.1
const HIT_CHANCE := 0.5
const RETARGET_TIME := 0.3
const SPACING := 11.0
const FOE_GAP := 8.0 # men of opposing sides never get closer than this

# Where a hit lands, judged against the struck block's facing
const SIDE_MULT := 1.5
const REAR_MULT := 2.5
const SIDE_HIT_BONUS := 0.12
const REAR_HIT_BONUS := 0.25

# Squads
const SPEED := 55.0
const TURN := 3.0 # rad/s marching
const ENGAGED_TURN := 0.5 # rad/s while moving in contact
const MAX_SHOVE := 30.0 # px/s: how fast blocks pushing each other can move
const SLIDE_SPEED := 0.3 # speed fraction while edging round to our side in contact
const SLIDE_DONE := 14.0 # px from our spot counts as in place
const ROUT_AT := 15.0
const MORALE_PER_DEATH := 10.0 # x 10 / starting size
const ENGAGED_DRAIN := 0.6
const FLANK_DRAIN := 3.0 # per second while being hit in the flank or rear
const RECOVERY := 3.0
const ROUT_SHOCK := 10.0
const ROUT_SHOCK_RADIUS := 160.0
const BREAK_OFF_MORALE := 6.0
const BREAK_OFF_BURST := 1.3
const BREAK_OFF_TIME := 2.0
const FLANK_SHOW := 1.2 # seconds the flank marker lingers after the last flank hit

const View3DScript := preload("res://scripts/proto/view3d.gd")

## Draw the fight in 3D (proto_skirmish_3d.tscn) instead of the 2.5D canvas.
@export var render_3d := false

const CAM_MIN := 1.0
const CAM_MAX := 3.0
const GRID := 24.0


class Unit:
	var pos: Vector2
	var face := Vector2.RIGHT
	var hp := 10.0
	var team := 0
	var sq: Sq
	var target: Unit = null
	var retarget := 0.0
	var cool := 0.0
	var swing := 0.0
	var flash := 0.0
	var alive := true
	var dead_for := 0.0
	var home := Vector2.ZERO # his place in the block this frame


class Sq:
	var name := ""
	var team := 0
	var color := Color.WHITE
	var units: Array[Unit] = []
	var start := 0
	var morale := 100.0
	var routing := false
	var pos := Vector2.ZERO # middle of the block
	var facing := 0.0
	var goal := Vector2.ZERO
	var goal_facing := NAN
	var attack: Sq = null
	var selected := false
	var marching := false
	var march_time := 0.0
	var in_contact := false
	var fighting := 0 # men with a foe in reach, last frame
	var flank_t := 0.0 # > 0: hit in the flank or rear recently
	var flank_dir := Vector2.ZERO # from the block toward whoever is flanking it
	var flank_rear := false
	var attack_dir := Vector2.ZERO # which side of the target we close on (from its middle)
	var side_timer := 0.0

	func alive() -> Array[Unit]:
		var out: Array[Unit] = []
		for u in units:
			if u.alive:
				out.append(u)
		return out

	func center() -> Vector2:
		return pos

	func gone() -> bool:
		return routing or alive().is_empty()


var squads: Array[Sq] = []
var units: Array[Unit] = []
var sparks: Array[Dictionary] = []
var field: Battlefield
var cam: Camera2D
var _zoom := 1.0
var _panning := false
var _drag := false
var _drag_a := Vector2.ZERO
var _drag_b := Vector2.ZERO
var _rdrag := false
var _rdrag_a := Vector2.ZERO
var _rdrag_b := Vector2.ZERO
var _grid := {}
var _ai_clock := 0.0
var _result: Label
var _paused_label: Label
var _over := false
var view # View3D when render_3d
var _ui: CanvasLayer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not render_3d:
		field = Battlefield.new()
		field.z_index = -1
		add_child(field)
		cam = Camera2D.new()
		add_child(cam)
		cam.make_current()
		_reset_camera()

	var ours := [["Aldric", 15], ["Mira", 25], ["Tobin", 10], ["Wren", 10]]
	for i in ours.size():
		_spawn(ours[i][0], 0, ours[i][1], Vector2(230, 330 + i * 160), 0.0)
	var theirs := [12, 14, 15, 16, 18]
	for i in theirs.size():
		_spawn("Enemy %d" % (i + 1), 1, theirs[i], Vector2(580, 260 + i * 150), PI)

	var ui := CanvasLayer.new()
	add_child(ui)
	_ui = ui
	var help := Label.new()
	help.text = "PROTOTYPE v2  ·  soldiers fight in formation      Left-drag select   Right-click move / attack   Right-drag facing   1-4 select   Space pause   R restart"
	help.add_theme_font_size_override("font_size", 13)
	help.add_theme_color_override("font_color", Color(0.95, 0.9, 0.75))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	help.add_theme_stylebox_override("normal", sb)
	help.size = Vector2(1280, 30)
	ui.add_child(help)
	_result = Label.new()
	_result.add_theme_font_size_override("font_size", 34)
	_result.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result.position = Vector2(0, 300)
	_result.size = Vector2(1280, 60)
	_result.visible = false
	ui.add_child(_result)
	_paused_label = Label.new()
	_paused_label.text = "PAUSED"
	_paused_label.add_theme_font_size_override("font_size", 18)
	_paused_label.add_theme_color_override("font_color", Color(1, 0.95, 0.8))
	_paused_label.position = Vector2(600, 44)
	_paused_label.visible = false
	ui.add_child(_paused_label)

	if render_3d:
		view = View3DScript.new(self)
		add_child(view)
		var ov := Control.new()
		ov.set_anchors_preset(Control.PRESET_FULL_RECT)
		ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ov.draw.connect(func() -> void: view.draw_overlay(ov))
		_ui.add_child(ov)
		_ui.move_child(ov, 0) # under the help bar and result text
		view.overlay = ov
		help.text = "PROTOTYPE 3D  ·  Left-drag select   Right-click move / attack   Right-drag facing   1-4 select   Space pause   R restart      Camera: WASD   Q/E turn   wheel zoom   middle-drag orbit"

	Sound.music("music_battle")
	Sound.loop("amb_field", -18.0)


func _spawn(name: String, team: int, n: int, at: Vector2, facing: float) -> void:
	var s := Sq.new()
	s.name = name
	s.team = team
	s.color = PLAYER_COLOR if team == 0 else ENEMY_COLOR
	s.start = n
	s.pos = at
	s.goal = at
	s.facing = facing
	for i in n:
		var u := Unit.new()
		u.hp = HP
		u.team = team
		u.sq = s
		u.cool = randf_range(0.0, SWING_TIME)
		u.face = Vector2.from_angle(facing)
		s.units.append(u)
		units.append(u)
	var alive := s.alive()
	for i in alive.size():
		alive[i].pos = _place(s, i, n)
		alive[i].home = alive[i].pos
	squads.append(s)


# --- Block geometry -----------------------------------------------------------

func _cols(n: int) -> int:
	return maxi(1, ceili(sqrt(n * 1.8)))


## Man i of n's place: rank 0 is the front.
func _place(s: Sq, i: int, n: int) -> Vector2:
	var cols := _cols(n)
	var rows := ceili(float(n) / cols)
	var fwd := Vector2.from_angle(s.facing)
	var side := fwd.orthogonal()
	var col := i % cols
	var row := i / cols
	var in_row := cols if row < rows - 1 else n - cols * (rows - 1)
	var x := (col - (in_row - 1) / 2.0) * SPACING
	var y := (row - (rows - 1) / 2.0) * SPACING
	return s.pos + side * x - fwd * y


## Half width and half depth of the block.
func _half(n: int) -> Vector2:
	var cols := _cols(n)
	var rows := ceili(float(n) / cols)
	return Vector2(cols * SPACING / 2.0, rows * SPACING / 2.0)


# --- Simulation -----------------------------------------------------------

func _process(delta: float) -> void:
	if not render_3d:
		_pan_keys(delta)
	if not get_tree().paused and not _over:
		_step(delta)
	queue_redraw()


func _step(delta: float) -> void:
	_build_grid()
	_ai_clock += delta
	if _ai_clock > 1.0:
		_think_enemy()

	for s in squads:
		if s.attack != null and s.attack.gone():
			s.attack = null
			s.attack_dir = Vector2.ZERO
			s.goal = s.pos
			s.goal_facing = NAN
		s.flank_t = maxf(0.0, s.flank_t - delta)
		if not s.routing:
			_move_block(s, delta)
	_separate_blocks(delta)

	var fighting := 0
	for s in squads:
		var alive := s.alive()
		var contact := false
		for i in alive.size():
			var u := alive[i]
			if s.routing:
				_flee(u, delta)
				continue
			u.home = _place(s, i, alive.size())
			if not s.marching:
				_choose_target(u, delta)
			else:
				u.target = null
			var want := u.home
			if u.target != null:
				contact = true
				fighting += 1
				var to := u.target.pos - u.home
				var d := to.length()
				# Step out of his place toward the foe, but only so far
				want = u.home + to / maxf(d, 0.01) * clampf(d - REACH + 2.0, 0.0, LUNGE)
				u.face = (u.target.pos - u.pos).normalized()
				_swing(u, delta)
			else:
				u.face = u.face.lerp(Vector2.from_angle(s.facing), minf(1.0, 6.0 * delta)).normalized()
			u.pos = u.pos.move_toward(want, MAN_SPEED * delta)
			# Never stand inside a foe: the lines meet, they don't mesh
			if u.target != null:
				for e in _near(u.pos, FOE_GAP, 1 - u.team):
					var off := u.pos - e.pos
					var d := maxf(off.length(), 0.01)
					u.pos += off / d * (FOE_GAP - d) * 0.5
		s.in_contact = contact
		var busy := 0
		for u in alive:
			if u.target != null:
				busy += 1
		s.fighting = busy
		_morale(s, delta)

	for u in units:
		u.swing = maxf(0.0, u.swing - delta)
		u.flash = maxf(0.0, u.flash - delta)
		if not u.alive:
			u.dead_for += delta
	for i in range(units.size() - 1, -1, -1):
		var u := units[i]
		if not u.alive and u.dead_for > 6.0:
			if field != null:
				field.add_fallen(u.pos, u.sq.color)
			elif view != null and u.dead_for < 900.0:
				view.add_corpse(u.pos, u.sq.color, u.face)
			units.remove_at(i)
		elif u.sq.routing and u.alive and not Rect2(Vector2(-40, -40), View.MAP_SIZE + Vector2(80, 80)).has_point(u.pos):
			u.alive = false
			u.dead_for = 999.0
	for i in range(sparks.size() - 1, -1, -1):
		sparks[i].left -= delta
		if sparks[i].left <= 0.0:
			sparks.remove_at(i)

	Sound.loop("battle_din", -80.0 if fighting == 0 else -24.0 + minf(fighting / 6.0, 6.0) * 2.0)
	_check_end()


## The block as a whole: march to a spot, close with the squad it was sent
## at, or hold. In melee it can only turn slowly.
func _move_block(s: Sq, delta: float) -> void:
	var dest := s.goal
	var face_to := s.goal_facing
	var hold := false
	if s.attack != null:
		# Close on a free SIDE of the target, not its middle: a second squad
		# wraps round to the flank instead of shoving the first one from behind
		s.side_timer -= delta
		if s.side_timer <= 0.0 or s.attack_dir == Vector2.ZERO:
			s.attack_dir = _pick_side(s, s.attack)
			s.side_timer = 0.5
		dest = _contact_spot(s, s.attack, s.attack_dir)
		face_to = (s.attack.pos - dest).angle()
		# Stand and fight once in place; caught on a corner short of our side,
		# keep edging round to it (slowly, fighting as we go)
		var front := _cols(s.alive().size())
		hold = s.in_contact and (s.pos.distance_to(dest) < SLIDE_DONE or s.fighting >= front * 0.6)
	elif not s.marching and s.in_contact:
		hold = true # attacked while standing: stand and fight where we face

	var turn := ENGAGED_TURN if s.in_contact else TURN
	if s.marching:
		s.march_time += delta
	if not hold:
		var wp := Terrain.waypoint(s.pos, dest)
		var to := wp - s.pos
		var d := to.length()
		if d > 1.0:
			var burst := BREAK_OFF_BURST if s.marching and s.march_time < BREAK_OFF_TIME else 1.0
			if s.in_contact and not s.marching:
				burst = SLIDE_SPEED
			var step := to / d * minf(d, SPEED * burst * Terrain.speed_mult(s.pos) * delta)
			if not Terrain.in_water(s.pos + step):
				s.pos += step
			if d > 8.0:
				s.facing = lerp_angle(s.facing, to.angle(), minf(1.0, turn * delta))
		elif s.marching:
			s.marching = false
	# A block locked in melee can't wheel round: its facing stays put (pull it
	# out and re-form to face a new threat). Otherwise it turns at the end of a move.
	if not is_nan(face_to) and not s.in_contact and (hold or s.pos.distance_to(dest) <= 20.0):
		s.facing = lerp_angle(s.facing, face_to, minf(1.0, turn * delta))


## How far from the target's middle its edge is, in direction `dir`.
func _reach_of(t: Sq, dir: Vector2) -> float:
	var h := _half(t.alive().size())
	var f := Vector2.from_angle(t.facing)
	return absf(dir.dot(f)) * h.y + absf(dir.dot(f.orthogonal())) * h.x


## Where squad s stands to fight t from side `dir`: its front rank on t's edge.
func _contact_spot(s: Sq, t: Sq, dir: Vector2) -> Vector2:
	return t.pos + dir * (_reach_of(t, dir) + _half(s.alive().size()).y + REACH * 0.5)


## The side of t to attack from: one of its four real sides (front, left,
## right, rear), nearest to us first, skipping any another block already
## holds. Square to the side, so the whole front rank gets to fight.
func _pick_side(s: Sq, t: Sq) -> Vector2:
	var base := (s.pos - t.pos).normalized()
	if base == Vector2.ZERO:
		base = Vector2.from_angle(s.facing + PI)
	var f := Vector2.from_angle(t.facing)
	var sides: Array[Vector2] = [f, -f, f.orthogonal(), -f.orthogonal()]
	sides.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.dot(base) > b.dot(base))
	var tries: Array[Vector2] = []
	if s.attack_dir != Vector2.ZERO:
		# keep the side we chose (it turns with the target) if it's still free
		var best_keep := sides[0]
		for d in sides:
			if d.dot(s.attack_dir) > best_keep.dot(s.attack_dir):
				best_keep = d
		tries.append(best_keep)
	tries.append_array(sides)
	var mine := _half(s.alive().size()).length()
	for dir in tries:
		var spot := _contact_spot(s, t, dir)
		var free := true
		for o in squads:
			if o == s or o == t or o.gone():
				continue
			var there := o.pos
			if o.attack == t and o.attack_dir != Vector2.ZERO:
				there = _contact_spot(o, t, o.attack_dir) # where it's going, not where it is
			if there.distance_to(spot) < (mine + _half(o.alive().size()).length()) * 0.8:
				free = false
				break
		if free:
			return dir
	return sides[0]


func _nearest_foe_squad(s: Sq) -> Sq:
	var best: Sq = null
	var best_d := INF
	for o in squads:
		if o.team != s.team and not o.gone():
			var d := o.pos.distance_to(s.pos)
			if d < best_d:
				best_d = d
				best = o
	return best


## Blocks don't overlap: any two men of different squads closer than their
## spacing push their whole squads apart.
func _separate_blocks(delta: float) -> void:
	var push := {}
	for u in units:
		if not u.alive or u.sq.routing:
			continue
		for o in _near(u.home, SPACING - 1.0, -1):
			if o.sq == u.sq or o.sq.routing:
				continue
			var off := u.home - o.home
			var d := maxf(off.length(), 0.01)
			var p: Vector2 = off / d * (SPACING - 1.0 - d)
			push[u.sq] = push.get(u.sq, Vector2.ZERO) + p
	for s in push:
		var v: Vector2 = push[s] / maxf(sqrt(s.alive().size()), 1.0) * minf(1.0, 12.0 * delta)
		v = v.limit_length(MAX_SHOVE * delta) # bodies give way slowly: no chain-shoving
		if not Terrain.in_water(s.pos + v):
			s.pos += v
			if s.attack == null and s.pos.distance_to(s.goal) < 20.0:
				s.goal += v # settled: don't walk back into the shove


## The man picks a foe within reach of his place (plus a short lunge),
## preferring the one he already has.
func _choose_target(u: Unit, delta: float) -> void:
	u.retarget -= delta
	var reach := REACH + LUNGE
	var ok := u.target != null and u.target.alive and not u.target.sq.routing \
		and u.home.distance_to(u.target.pos) <= reach + 2.0
	if ok and u.retarget > 0.0:
		return
	u.retarget = RETARGET_TIME * randf_range(0.8, 1.2)
	var best: Unit = null
	var best_score := INF
	for e in _near(u.home, reach, 1 - u.team):
		if e.sq.routing and e.pos.distance_to(u.pos) > REACH + 4.0:
			continue
		var score := u.home.distance_to(e.pos) + (6.0 if e != u.target else 0.0)
		if score < best_score:
			best_score = score
			best = e
	u.target = best


func _swing(u: Unit, delta: float) -> void:
	u.cool -= delta
	var t := u.target
	if u.cool > 0.0 or u.pos.distance_to(t.pos) > REACH + 1.5:
		return
	u.cool = SWING_TIME * randf_range(0.85, 1.15)
	u.swing = 0.22
	# Which side of HIS BLOCK is the blow coming from?
	var from := (u.pos - t.sq.pos).normalized()
	var dot := from.dot(Vector2.from_angle(t.sq.facing))
	var mult := 1.0
	var chance := HIT_CHANCE
	var flank := false
	if dot < -0.35:
		mult = REAR_MULT
		chance += REAR_HIT_BONUS
		flank = true
		t.sq.flank_rear = true
	elif dot < 0.5:
		mult = SIDE_MULT
		chance += SIDE_HIT_BONUS
		flank = true
		t.sq.flank_rear = false
	if flank:
		t.sq.flank_t = FLANK_SHOW
		t.sq.flank_dir = t.sq.flank_dir.lerp(from, 0.3).normalized() if t.sq.flank_dir != Vector2.ZERO else from
	if t.sq.routing:
		chance = 0.9
	if randf() > chance:
		Sound.play("clash", -8.0, 0.12, 60)
		return
	t.hp -= mult * Terrain.damage_mult(u.pos, t.pos)
	t.flash = 0.12
	sparks.append({ "pos": t.pos.lerp(u.pos, 0.4), "left": 0.15, "flank": flank })
	Sound.play("clash", -4.0, 0.12, 45)
	if t.hp <= 0.0:
		_kill(t)


func _kill(t: Unit) -> void:
	t.alive = false
	t.target = null
	Sound.play("hit", 0.0, 0.12, 70)
	t.sq.morale -= MORALE_PER_DEATH * 10.0 / maxf(t.sq.start, 1.0)


func _morale(s: Sq, delta: float) -> void:
	if s.routing or s.alive().is_empty():
		return
	if s.in_contact:
		s.morale -= ENGAGED_DRAIN * delta
	if s.flank_t > FLANK_SHOW - 0.5:
		s.morale -= FLANK_DRAIN * (1.6 if s.flank_rear else 1.0) * delta
	if not s.in_contact:
		s.morale = minf(100.0, s.morale + RECOVERY * delta)
	if s.morale < ROUT_AT:
		s.routing = true
		s.selected = false
		Sound.play("rout", 0.0 if s.team == 0 else -2.0, 0.0)
		for o in squads:
			if o != s and o.team == s.team and not o.routing and o.pos.distance_to(s.pos) < ROUT_SHOCK_RADIUS:
				o.morale -= ROUT_SHOCK


func _flee(u: Unit, delta: float) -> void:
	u.target = null
	var edge := Vector2(-200.0 if u.team == 0 else View.MAP_SIZE.x + 200.0, u.pos.y)
	var wp := Terrain.waypoint(u.pos, edge)
	u.face = (wp - u.pos).normalized()
	var step := u.face * FLEE_SPEED * Terrain.speed_mult(u.pos) * delta
	if not Terrain.in_water(u.pos + step):
		u.pos += step
	elif not Terrain.in_water(u.pos + Vector2(0, step.y)):
		u.pos.y += step.y


func _build_grid() -> void:
	_grid.clear()
	for u in units:
		if not u.alive:
			continue
		var k := Vector2i(floori(u.pos.x / GRID), floori(u.pos.y / GRID))
		if not _grid.has(k):
			_grid[k] = []
		_grid[k].append(u)


func _near(p: Vector2, r: float, team: int) -> Array[Unit]:
	var out: Array[Unit] = []
	var a := Vector2i(floori((p.x - r) / GRID), floori((p.y - r) / GRID))
	var b := Vector2i(floori((p.x + r) / GRID), floori((p.y + r) / GRID))
	for gx in range(a.x, b.x + 1):
		for gy in range(a.y, b.y + 1):
			var cell: Array = _grid.get(Vector2i(gx, gy), [])
			for o: Unit in cell:
				if (team < 0 or o.team == team) and o.pos.distance_to(p) <= r:
					out.append(o)
	return out


## Bare-bones enemy: each free squad goes for our nearest squad.
func _think_enemy() -> void:
	for s in squads:
		if s.team != 1 or s.gone() or s.attack != null:
			continue
		var best: Sq = null
		var best_d := INF
		for o in squads:
			if o.team == 0 and not o.gone():
				var d := s.pos.distance_to(o.pos)
				if d < best_d:
					best_d = d
					best = o
		s.attack = best
		s.attack_dir = Vector2.ZERO


func _check_end() -> void:
	var standing := [false, false]
	for s in squads:
		if not s.gone():
			standing[s.team] = true
	if standing[0] and standing[1]:
		return
	_over = true
	Sound.loop("battle_din", -80.0)
	Sound.play("victory" if standing[0] else "defeat")
	var left := 0
	for u in units:
		if u.alive and u.team == 0 and not u.sq.routing:
			left += 1
	_result.text = ("VICTORY" if standing[0] else "DEFEAT") + "   -   %d of ours still standing.   R to restart" % left
	_result.add_theme_color_override("font_color", Color(0.7, 0.95, 0.55) if standing[0] else Color(1.0, 0.5, 0.42))
	_result.visible = true


# --- Orders -----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	var screen := get_viewport().get_mouse_position()
	var mouse: Vector2 = view.pick(screen) if render_3d else get_global_mouse_position()
	# In 3D the selection box lives on the screen; in 2D on the map
	var drag_pt := screen if render_3d else mouse
	if render_3d and event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		return # the 3D camera handles these
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if event.pressed:
					_drag = true
					_drag_a = drag_pt
					_drag_b = drag_pt
				elif _drag:
					_drag = false
					_select_box(Rect2(_drag_a, drag_pt - _drag_a).abs(), event.shift_pressed)
			MOUSE_BUTTON_RIGHT:
				if event.pressed:
					_rdrag = true
					_rdrag_a = mouse
					_rdrag_b = mouse
				elif _rdrag:
					_rdrag = false
					_order(mouse, screen)
			MOUSE_BUTTON_MIDDLE:
				_panning = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_zoom_by(1.15)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_zoom_by(1.0 / 1.15)
	elif event is InputEventMouseMotion:
		if _panning and not render_3d:
			cam.position -= event.relative / cam.zoom
			_clamp_camera()
		if _drag:
			_drag_b = drag_pt
		if _rdrag:
			_rdrag_b = mouse
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				get_tree().paused = not get_tree().paused
				_paused_label.visible = get_tree().paused
			KEY_R:
				get_tree().paused = false
				get_tree().reload_current_scene()
			KEY_HOME:
				if not render_3d:
					_reset_camera()
			KEY_1, KEY_2, KEY_3, KEY_4:
				var ours := _ours()
				var i: int = event.keycode - KEY_1
				if i < ours.size() and not ours[i].gone():
					for s in squads:
						s.selected = false
					ours[i].selected = true
					Sound.play("ui_select")


func _ours() -> Array[Sq]:
	var out: Array[Sq] = []
	for s in squads:
		if s.team == 0:
			out.append(s)
	return out


func _select_box(r: Rect2, add: bool) -> void:
	if not add:
		for s in squads:
			s.selected = false
	var click := r.size.length() < 6.0
	if click:
		r = r.grow(10.0)
	var any := false
	for s in _ours():
		if s.gone():
			continue
		for u in s.alive():
			if r.has_point(view.to_screen(u.pos) if render_3d else u.pos):
				s.selected = true
				any = true
				break
		if click and s.selected:
			break
	if any:
		Sound.play("ui_select")


func _order(at: Vector2, screen := Vector2.ZERO) -> void:
	var picked: Array[Sq] = []
	for s in _ours():
		if s.selected and not s.gone():
			picked.append(s)
	if picked.is_empty():
		return
	Sound.play("order", 0.0, 0.06, 80)
	var dragged := _rdrag_a.distance_to(at) > 12.0
	if not dragged:
		var hit: Unit = null
		if render_3d:
			hit = view.enemy_at_screen(screen, 1) # bodies stand up: pick on screen
		else:
			for u in _near(at, 14.0, 1):
				if not u.sq.gone():
					hit = u
					break
		if hit != null:
			for s in picked:
				s.attack = hit.sq
				s.attack_dir = Vector2.ZERO
				s.marching = false
			return
	var dest := _rdrag_a if dragged else at
	var c := Vector2.ZERO
	for s in picked:
		c += s.pos
	c /= picked.size()
	var facing: float = (at - _rdrag_a).angle() if dragged else (dest - c).angle()
	var side := Vector2.from_angle(facing).orthogonal()
	var widths: Array[float] = []
	var total := 0.0
	for s in picked:
		var w := _half(s.alive().size()).x * 2.0 + 14.0
		widths.append(w)
		total += w
	var x := -total / 2.0
	for i in picked.size():
		var s := picked[i]
		if s.in_contact:
			s.morale -= BREAK_OFF_MORALE # turning your back on a fight costs nerve
		s.attack = null
		s.goal = dest + side * (x + widths[i] / 2.0)
		s.goal_facing = facing
		s.marching = true
		s.march_time = 0.0
		x += widths[i]


# --- Camera -----------------------------------------------------------------

func _reset_camera() -> void:
	_zoom = 1.0
	cam.position = View.MAP_SIZE / 2.0
	cam.zoom = Vector2(_zoom, _zoom * View.TILT)


func _zoom_by(f: float) -> void:
	var off := get_viewport().get_mouse_position() - get_viewport_rect().size / 2.0
	var before := cam.position + off / cam.zoom
	_zoom = clampf(_zoom * f, CAM_MIN, CAM_MAX)
	cam.zoom = Vector2(_zoom, _zoom * View.TILT)
	cam.position = before - off / cam.zoom
	_clamp_camera()


func _clamp_camera() -> void:
	var half := get_viewport_rect().size / 2.0 / cam.zoom
	cam.position = cam.position.clamp(half, (View.MAP_SIZE - half).max(half))


func _pan_keys(delta: float) -> void:
	var d := Vector2(
		float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT)),
		float(Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_UP)))
	if d != Vector2.ZERO:
		cam.position += d * 700.0 * delta / cam.zoom
		_clamp_camera()


# --- Drawing ----------------------------------------------------------------

func _draw() -> void:
	if render_3d:
		return # the 3D view draws everything
	# On the ground: each block's footprint, its facing, flank markers
	for s in squads:
		if not s.gone():
			_draw_footprint(s)
	# Attack lines while closing in
	for s in squads:
		if s.team == 0 and s.attack != null and not s.gone() and not s.in_contact:
			draw_dashed_line(s.pos, s.attack.pos, Color(1.0, 0.55, 0.45, 0.7), 2.0, 8.0)

	# Men, back to front
	var order := units.duplicate()
	order.sort_custom(func(a: Unit, b: Unit) -> bool: return a.pos.y < b.pos.y)
	var up := View.upright_scale()
	for u: Unit in order:
		draw_set_transform(u.pos, 0.0, up)
		if not u.alive:
			_draw_body(u)
		else:
			_draw_man(u)
	draw_set_transform(Vector2.ZERO)

	for sp in sparks:
		var p: Vector2 = sp.pos
		var a: float = sp.left / 0.15
		var col := Color(1.0, 0.6, 0.25, a) if sp.flank else Color(1, 0.95, 0.6, a)
		draw_set_transform(p, 0.0, up)
		for k in 4:
			var dir := Vector2.from_angle(k * PI / 2.0 + 0.6)
			draw_line(dir * 1.5 + Vector2(0, -7), dir * (5.5 if sp.flank else 4.5) + Vector2(0, -7), col, 1.3)
	draw_set_transform(Vector2.ZERO)

	# Tags above the blocks
	var font := ThemeDB.fallback_font
	for s in squads:
		if s.gone():
			continue
		var h := _half(s.alive().size())
		var at := s.pos - Vector2(0, h.length() + 4.0)
		draw_set_transform(at, 0.0, up / _zoom) # same size on screen at any zoom
		var m := clampf(s.morale / 100.0, 0.0, 1.0)
		if s.team == 0:
			draw_string(font, Vector2(-60, -14), "%s %d" % [s.name, s.alive().size()], HORIZONTAL_ALIGNMENT_CENTER, 120, 11, Color(0.85, 0.9, 1.0))
		draw_rect(Rect2(-18, -10, 36, 3), Color(0, 0, 0, 0.6))
		draw_rect(Rect2(-18, -10, 36 * m, 3), Color(1.0 - m, 0.4 + 0.5 * m, 0.3))
		if s.flank_t > 0.0:
			var tag := "REAR!" if s.flank_rear else "FLANKED"
			# Ours flanked: a warning. Theirs: your plan working.
			var tc := Color(1.0, 0.5, 0.3) if s.team == 0 else Color(0.6, 1.0, 0.5)
			draw_string(font, Vector2(-60, -28 if s.team == 0 else -14), tag, HORIZONTAL_ALIGNMENT_CENTER, 120, 11, Color(tc, minf(1.0, s.flank_t)))
	draw_set_transform(Vector2.ZERO)

	if _drag and _drag_a.distance_to(_drag_b) > 6.0:
		var r := Rect2(_drag_a, _drag_b - _drag_a).abs()
		draw_rect(r, Color(0.6, 1.0, 0.6, 0.1), true)
		draw_rect(r, Color(0.6, 1.0, 0.6, 0.8), false, 1.0)
	if _rdrag and _rdrag_a.distance_to(_rdrag_b) > 12.0:
		draw_line(_rdrag_a, _rdrag_b, Color(0.6, 1.0, 0.6, 0.9), 2.0)


## The block's footprint on the ground, a facing chevron at its front, and a
## bright arc on the side where it's being flanked.
func _draw_footprint(s: Sq) -> void:
	var h := _half(s.alive().size()) + Vector2(5, 5)
	var fwd := Vector2.from_angle(s.facing)
	var side := fwd.orthogonal()
	var corners := PackedVector2Array([
		s.pos + fwd * h.y + side * h.x, s.pos + fwd * h.y - side * h.x,
		s.pos - fwd * h.y - side * h.x, s.pos - fwd * h.y + side * h.x])
	var edge := Color(0.6, 1.0, 0.6, 0.8) if s.selected else Color(s.color, 0.45)
	draw_colored_polygon(corners, Color(s.color, 0.08))
	var outline := corners.duplicate()
	outline.append(corners[0])
	draw_polyline(outline, edge, 1.5 if s.selected else 1.0)
	# Facing chevron
	var tip := s.pos + fwd * (h.y + 9.0)
	draw_colored_polygon(PackedVector2Array([tip, tip - fwd * 6.0 + side * 6.0, tip - fwd * 6.0 - side * 6.0]), Color(s.color.lightened(0.2), 0.8))
	# Flank marker: a thick arc on the threatened side
	if s.flank_t > 0.0:
		var r := h.length() + 6.0
		var a0 := s.flank_dir.angle()
		var alpha := minf(1.0, s.flank_t)
		draw_arc(s.pos, r, a0 - 0.6, a0 + 0.6, 14, Color(FLANK_COLOR, 0.9 * alpha), 4.0)
		draw_arc(s.pos, r + 5.0, a0 - 0.35, a0 + 0.35, 10, Color(FLANK_COLOR, 0.5 * alpha), 2.0)


func _draw_man(u: Unit) -> void:
	var c := u.sq.color
	if u.flash > 0.0:
		c = c.lerp(Color.WHITE, 0.7)
	if u.sq.routing:
		c = c.darkened(0.25)
	var outline := Color(0.08, 0.08, 0.1)
	var face := Vector2(u.face.x, u.face.y * View.TILT).normalized()
	var away := face.y < -0.25
	var wood := Color(0.55, 0.42, 0.26)
	var metal := Color(0.85, 0.85, 0.8)
	var thrust := sin(u.swing / 0.22 * PI) * 5.0 if u.swing > 0.0 else 0.0
	var shield_at := Vector2(0, -6.0) + face * 3.4
	var spear_a := Vector2(0, -5.0) - face * 3.0 + face * thrust
	var spear_b := Vector2(0, -12.0) + face * (9.0 + thrust)
	if u.sq.routing:
		spear_b = spear_a + Vector2(0, -6)
	draw_circle(Vector2(0, 0.5), 4.0, Color(0, 0, 0, 0.2))
	if away:
		draw_line(spear_a, spear_b, wood, 1.1)
		draw_circle(spear_b, 1.0, metal)
		draw_circle(shield_at, 3.0, outline)
		draw_circle(shield_at, 2.3, c.darkened(0.25))
	draw_circle(Vector2(0, -3.2), 3.6, outline)
	draw_circle(Vector2(0, -6.2), 3.6, outline)
	draw_circle(Vector2(0, -3.2), 2.8, c)
	draw_circle(Vector2(0, -6.2), 2.8, c)
	draw_circle(Vector2(-1.0, -7.0), 1.1, c.lightened(0.35))
	draw_circle(Vector2(0, -11.0), 2.7, outline)
	draw_circle(Vector2(0, -11.0), 2.0, c.darkened(0.25).lerp(Color(0.6, 0.6, 0.62), 0.45))
	if not away:
		draw_line(spear_a, spear_b, wood, 1.1)
		draw_circle(spear_b, 1.0, metal)
		draw_circle(shield_at, 3.0, outline)
		draw_circle(shield_at, 2.3, c.darkened(0.25))
		draw_circle(shield_at, 0.8, metal)
	if u.hp < HP and u.sq.selected:
		var f := clampf(u.hp / HP, 0.0, 1.0)
		draw_rect(Rect2(-5, -17, 10, 2), Color(0, 0, 0, 0.6))
		draw_rect(Rect2(-5, -17, 10 * f, 2), Color(1.0 - f, 0.85 * f + 0.15, 0.2))


func _draw_body(u: Unit) -> void:
	var a := clampf(1.0 - (u.dead_for - 4.0) / 2.0, 0.0, 1.0)
	var c := Color(u.sq.color.darkened(0.45), a)
	var side := 1.0 if u.face.x >= 0 else -1.0
	draw_circle(Vector2(-3 * side, -1), 2.6, c)
	draw_circle(Vector2(1 * side, -1), 2.6, c)
	draw_circle(Vector2(5 * side, -1.5), 2.0, Color(0.45, 0.45, 0.47, a))
