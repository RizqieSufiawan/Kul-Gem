class_name Squad
extends Node2D
## A squad: one leader's soldiers in a block. Orders go to the squad; the
## fighting is man by man. Every soldier has his own health and swings on his
## own timer, but keeps his place in the block: only the men at the edge that
## touches an enemy step out (a short lunge) to fight. A blow's direction is
## judged against the struck block's facing, so flanks and rears pay off, and a
## block locked in melee can't wheel round to face a new threat.

signal died(squad: Squad) # removed from the battle (wiped out or fled the map)
signal routed(squad: Squad) # broke and started fleeing
## A man went down. `who` is his Soldier record (null for enemies);
## `wounded` = he'll live, if someone carries him off the field.
signal soldier_fell(pos: Vector2, color: Color, who: Soldier, wounded: bool)
signal rally_started(squad: Squad) # a fleeing squad reached the Commander's circle and turned back
signal rallied(squad: Squad, commander: Squad, count: int) # ...and has now joined the Commander's squad

## 0 = player, 1 = enemy
@export var team: int = 0
@export var soldier_count: int = 10
@export var move_speed: float = 60.0
@export var turn_speed: float = 5.0
@export var color: Color = Color(0.3, 0.6, 1.0)
## The Main Commander: a small bodyguard squad with a banner.
## Steadies nearby allies; direct orders are carried by messenger from here.
@export var is_commander := false
## The leader's Command: how many soldiers they lead at full effectiveness.
## Above it the squad is overloaded: clumsier, slower, and it bleeds more.
@export var command: int = 10

const SOLDIER_RADIUS := 4.0
const SPACING := 12.0
const COLUMNS := 5 # soldiers per rank (formation width)

# --- Soldiers -----------------------------------------------------------------
const MAN_HP := 10.0
const MAN_SPEED := 75.0 # how fast a soldier walks to his place (px/s), on top of the squad's pace
const REACH := 12.0 # melee range, centre to centre
const LUNGE := 7.0 # how far a man steps out of his place to fight
const SWING_TIME := 1.0 # seconds between a man's swings (each jittered)
const HIT_CHANCE := 0.5
const SIDE_MULT := 1.5 # damage from the side of the block...
const REAR_MULT := 2.5 # ...and from behind
const SIDE_HIT_BONUS := 0.12 # easier to land on men not facing you
const REAR_HIT_BONUS := 0.25
const RETARGET_TIME := 0.3
const FOE_GAP := 8.0 # men of opposing sides never stand closer than this
const MAX_SHOVE := 30.0 # px/s: how fast blocks pressing on each other give way
const FLASH_TIME := 0.12
const SWING_ANIM := 0.22

# --- Squads in melee ------------------------------------------------------------
const SLIDE_SPEED := 0.3 # speed fraction while edging round to our side, fighting
const SLIDE_DONE := 14.0 # px from our contact spot counts as in place
const SIDE_REPICK := 0.5 # seconds between re-choosing which side of the target to take

# --- Morale tuning ---
const MAX_MORALE := 100.0
const ROUT_THRESHOLD := 15.0 # break and flee below this
const STEADY_ROUT_THRESHOLD := 5.0 # ...or this, under a Steady leader
const INSPIRING_RADIUS := 150.0
const INSPIRING_REGEN := 0.9 # morale/s for allies near an Inspiring leader
const MORALE_PER_CASUALTY := 10.0 # lost for each soldier who falls (x 10 / starting size)
const MORALE_ENGAGED_DRAIN := 0.6 # per second just from being in melee
const MORALE_FLANK_DRAIN := 3.0 # per second while hit in the flank (x1.6 from the rear)
const FLANK_SHOW := 1.2 # seconds the flank marker lingers after the last flank hit
const MORALE_RECOVERY := 4.0 # per second while out of combat
const ROUT_SHOCK := 15.0 # lost by nearby allies when a squad routs
const ROUT_SHOCK_RADIUS := 150.0
const FLEE_SPEED_MULT := 1.3 # routers run faster than pursuers walk
const PLANNED_CHARGE_SHOCK := 20.0 # morale hit on first contact of a planned attack
const MIN_EFFICIENCY := 0.3
const FAMILIARITY_COMMAND_BONUS := 5.0 # extra effective Command at familiarity 100
const WOUNDED_CHANCE := 0.5 # share of casualties who are wounded rather than killed
const WOUNDED_CHANCE_FLEEING := 0.25 # men cut down while running mostly die

# --- Orders, rallying, the Commander ---------------------------------------------
const WITHDRAW_TIME := 1.6 # seconds a withdrawing squad ignores the fight and moves at full speed
const WITHDRAW_MORALE := 8.0 # turning your back on the enemy costs nerve
const REFORM_TIME := 1.2 # the enemy we left needs this long before it can follow
const RALLY_MORALE := 60.0 # morale of a fleeing squad that reaches the Commander's circle
const RALLY_SPEED_MULT := 1.15 # rallying men hurry to the Commander
const RALLY_JOIN_GAP := 16.0 # close enough to the Commander's squad to fall in
const COMMANDER_AURA_RADIUS := 160.0
const COMMANDER_AURA_REGEN := 0.75 # morale per second for allies near the commander, even in melee
const COMMANDER_LAST_STAND := 3 # the Commander only breaks once the guard is down to this
const COMMANDER_GUARD_DAMAGE := 2.0 # elite bodyguard hits twice as hard
const COMMANDER_GUARD_TOUGHNESS := 0.5 # ...and takes half the damage
const RALLY_MORALE_COST := 10.0 # Commander's squad morale lost when shaken routers join

const GRID := 24.0


## One soldier on the field.
class Man:
	var pos: Vector2
	var home := Vector2.ZERO # his place in the block this frame
	var hp := 10.0
	var cool := 0.0
	var swing := 0.0 # > 0 while the thrust animation plays
	var flash := 0.0
	var target: Man = null
	var retarget := 0.0
	var alive := true
	var sq: Squad


## Every man on the field by grid cell, rebuilt once a frame by the battle
## (before the squads move) so each man can find foes near him quickly.
static var grid := {}


static func build_grid(all: Array[Squad]) -> void:
	grid.clear()
	for s in all:
		if not is_instance_valid(s):
			continue
		for m in s._m:
			var k := Vector2i(floori(m.pos.x / GRID), floori(m.pos.y / GRID))
			if not grid.has(k):
				grid[k] = []
			grid[k].append(m)


## Living men of `team` (-1: anyone) within `r` of `p`.
static func men_near(p: Vector2, r: float, team_of: int) -> Array[Man]:
	var out: Array[Man] = []
	var a := Vector2i(floori((p.x - r) / GRID), floori((p.y - r) / GRID))
	var b := Vector2i(floori((p.x + r) / GRID), floori((p.y + r) / GRID))
	for gx in range(a.x, b.x + 1):
		for gy in range(a.y, b.y + 1):
			for o: Man in grid.get(Vector2i(gx, gy), []):
				if o.alive and is_instance_valid(o.sq) and (team_of < 0 or o.sq.team == team_of) \
						and o.pos.distance_to(p) <= r:
					out.append(o)
	return out


var target_position: Vector2
var target_facing: float = 0.0
var has_target_facing := false
var attack_target: Squad = null
## The squad most of our men are fighting right now (null: not in melee).
var engaged_with: Squad = null
var in_contact := false
var morale := MAX_MORALE
var routing := false

## Our side only: the leader and the soldiers (Soldier records). members[i]
## is the man _m[i].
var leader: Leader = null
var members: Array[Soldier] = []
var _m: Array[Man] = []
var _fighting := 0 # men with a foe in reach, last frame
var attack_dir := Vector2.ZERO # which side of the attack target we close on (from its middle)
var _side_timer := 0.0
## Flank feedback: > 0 when hit in the flank or rear recently
var flank_t := 0.0
var flank_dir := Vector2.ZERO # from our middle toward whoever is flanking us
var flank_rear := false
var _sparks: Array[Dictionary] = [] # { pos, left, flank } where our men were struck
var withdrawing := 0.0 # time left pulling out of a fight
var _reform := 0.0 # time left re-forming after the enemy pulled away
## Rallying: a squad that fled into the Commander's circle walks back to the
## Commander and joins its squad. Only once per squad.
var rallying := false
var _rallied_once := false
var _rally_to: Squad = null
var _start_count := 0 # soldiers at the start of battle, for morale scaling
var _planned_charge := false # next contact with attack_target is a planned surprise

## Unscouted enemy during planning: drawn as an unknown block, size hidden.
var concealed := false:
	set(value):
		concealed = value
		queue_redraw()

var selected: bool = false:
	set(value):
		selected = value
		queue_redraw()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	add_to_group("squads")
	_start_count = soldier_count
	_sync_men(true)
	if is_commander:
		add_to_group("commanders")
	target_position = global_position


func _exit_tree() -> void:
	for m in _m:
		m.alive = false # nobody keeps fighting a ghost


func _process(delta: float) -> void:
	if routing:
		_flee(delta)
	else:
		if attack_target != null and (not is_instance_valid(attack_target) or attack_target.soldier_count <= 0 or attack_target.routing):
			attack_target = null
			attack_dir = Vector2.ZERO
			target_position = global_position
			has_target_facing = false
		if rallying:
			_rally_step()
		if withdrawing > 0.0:
			withdrawing -= delta

	_update_men(delta)

	if not routing:
		if engaged_with != null:
			if _planned_charge and engaged_with == attack_target:
				_planned_charge = false
				engaged_with.morale_shock(PLANNED_CHARGE_SHOCK * (2.0 if has_trait("Ambusher") else 1.0))
			morale -= MORALE_ENGAGED_DRAIN * delta
		else:
			morale = minf(MAX_MORALE, morale + MORALE_RECOVERY * (0.5 + stat("charisma") / 100.0) * delta)
		if flank_t > FLANK_SHOW - 0.5:
			morale -= MORALE_FLANK_DRAIN * (1.6 if flank_rear else 1.0) * (0.5 if is_commander else 1.0) * delta
		if _near_inspiring_leader():
			morale = minf(MAX_MORALE, morale + INSPIRING_REGEN * delta)
		if _near_own_commander():
			morale = minf(MAX_MORALE, morale + COMMANDER_AURA_REGEN * delta)
		_move(delta)
		_check_rout()
	_dry_out()

	flank_t = maxf(0.0, flank_t - delta)
	for i in range(_sparks.size() - 1, -1, -1):
		_sparks[i].left -= delta
		if _sparks[i].left <= 0.0:
			_sparks.remove_at(i)
	queue_redraw() # soldiers and morale bar change every frame


# --- Soldiers -----------------------------------------------------------------

## Keep one Man per soldier. snap = put everyone straight in formation.
func _sync_men(snap: bool) -> void:
	while _m.size() < soldier_count:
		var m := Man.new()
		m.sq = self
		m.hp = MAN_HP
		m.cool = randf_range(0.0, SWING_TIME)
		m.pos = to_global(_slot(_m.size()))
		m.home = m.pos
		_m.append(m)
	while _m.size() > soldier_count:
		_m.pop_back().alive = false
	if snap:
		for i in _m.size():
			_m[i].pos = to_global(_slot(i))
			_m[i].home = _m[i].pos


## Each frame: every man finds his place in the block, picks a foe in reach
## (unless we're pulling out), steps out to him and swings. Also works out
## who we're mainly fighting, and shoves our block off enemy blocks.
func _update_men(delta: float) -> void:
	_sync_men(false)
	var n := _m.size()
	var fighting := 0
	var foes := {}
	var shove := Vector2.ZERO
	var pace := MAN_SPEED + move_speed * (FLEE_SPEED_MULT if routing else 1.0)
	for i in n:
		var m := _m[i]
		m.home = to_global(_slot(i))
		m.swing = maxf(0.0, m.swing - delta)
		m.flash = maxf(0.0, m.flash - delta)
		if routing or withdrawing > 0.0:
			m.target = null # backs turned: no fighting back
		else:
			_choose_target(m, delta)
		var want := m.home
		if m.target != null:
			fighting += 1
			foes[m.target.sq] = int(foes.get(m.target.sq, 0)) + 1
			var to := m.target.pos - m.home
			var d := to.length()
			# Step out of his place toward the foe, but only so far
			want = m.home + to / maxf(d, 0.01) * clampf(d - REACH + 2.0, 0.0, LUNGE)
			_swing(m, delta)
		m.pos = m.pos.move_toward(want, pace * delta)
		if m.target != null:
			# The lines meet, they don't mesh: never stand inside a foe, and
			# where two blocks overlap, our block gives way a little
			for e in men_near(m.pos, SPACING, 1 - team):
				var off := m.pos - e.pos
				var dd := maxf(off.length(), 0.01)
				if dd < FOE_GAP:
					m.pos += off / dd * (FOE_GAP - dd) * 0.5
				var hoff := m.home - e.home
				var hd := maxf(hoff.length(), 0.01)
				if hd < SPACING - 1.0:
					shove += hoff / hd * (SPACING - 1.0 - hd)
	_fighting = fighting
	in_contact = fighting > 0
	var best: Squad = null
	var most := 0
	for f in foes:
		if is_instance_valid(f) and foes[f] > most:
			most = foes[f]
			best = f
	engaged_with = best
	if shove != Vector2.ZERO and not routing:
		var v := shove / sqrt(maxf(n, 1.0)) * minf(1.0, 12.0 * delta)
		_step(v.limit_length(MAX_SHOVE * delta))


## The man picks a foe within reach of his place (plus a short lunge),
## keeping the one he has while it lasts. Runners only get cut down if they
## pass close; nobody fights across the water.
func _choose_target(m: Man, delta: float) -> void:
	m.retarget -= delta
	var reach := REACH + LUNGE
	var t := m.target
	var ok := t != null and t.alive and is_instance_valid(t.sq) and not t.sq.routing \
		and m.home.distance_to(t.pos) <= reach + 2.0
	if ok and m.retarget > 0.0:
		return
	m.retarget = RETARGET_TIME * randf_range(0.8, 1.2)
	var best: Man = null
	var best_score := INF
	for e in men_near(m.home, reach, 1 - team):
		if e.sq.routing and e.pos.distance_to(m.pos) > REACH + 4.0:
			continue
		if not _reachable(m.pos, e.pos):
			continue
		var score := m.home.distance_to(e.pos) + (6.0 if e != m.target else 0.0)
		if score < best_score:
			best_score = score
			best = e
	m.target = best


## Same bank, or one of them is on a crossing.
static func _reachable(a: Vector2, b: Vector2) -> bool:
	return Terrain.bank_side(a) == Terrain.bank_side(b) or Terrain.on_crossing(a) or Terrain.on_crossing(b)


func _swing(m: Man, delta: float) -> void:
	m.cool -= delta
	var t := m.target
	if m.cool > 0.0 or m.pos.distance_to(t.pos) > REACH + 1.5:
		return
	m.cool = SWING_TIME * randf_range(0.85, 1.15)
	m.swing = SWING_ANIM
	var foe := t.sq
	# Which side of HIS BLOCK is the blow coming from?
	var from := (m.pos - foe.center()).normalized()
	var dot := from.dot(Vector2.RIGHT.rotated(foe.rotation))
	var mult := 1.0
	var chance := HIT_CHANCE
	var flank := false
	if dot < -0.35:
		mult = REAR_MULT
		chance += REAR_HIT_BONUS
		flank = true
	elif dot < 0.5:
		mult = SIDE_MULT
		chance += SIDE_HIT_BONUS
		flank = true
	if foe.routing:
		chance = 0.9
		mult = REAR_MULT
	elif flank:
		foe.flank_t = FLANK_SHOW
		foe.flank_rear = mult == REAR_MULT
		foe.flank_dir = foe.flank_dir.lerp(from, 0.3).normalized() if foe.flank_dir != Vector2.ZERO else from
	if randf() > chance:
		return # blocked
	# Our side: valor, the Commander's guard, an overloaded squad's clumsiness.
	# Their side: overloaded squads are sloppy and bleed more; the guard is tough.
	var dmg := mult * _valor_damage_mult() * (0.5 + 0.5 * efficiency())
	if is_commander:
		dmg *= COMMANDER_GUARD_DAMAGE
	dmg *= Terrain.damage_mult(m.pos, t.pos)
	dmg *= (2.0 - foe.efficiency()) * (COMMANDER_GUARD_TOUGHNESS if foe.is_commander else 1.0)
	t.hp -= dmg
	t.flash = FLASH_TIME
	foe._sparks.append({ "pos": t.pos.lerp(m.pos, 0.4), "left": 0.15, "flank": flank })
	if t.hp <= 0.0:
		foe._kill(t)


## A man falls: dead or wounded, his record goes to the roll call.
func _kill(t: Man) -> void:
	var idx := _m.find(t)
	if idx < 0:
		return
	t.alive = false
	t.target = null
	var who: Soldier = null
	if idx < members.size():
		who = members[idx]
		members.remove_at(idx)
	_m.remove_at(idx)
	# Dead or wounded? A sloppy (overloaded) or fleeing squad leaves more dead
	var chance := WOUNDED_CHANCE_FLEEING if routing else WOUNDED_CHANCE * (0.5 + 0.5 * efficiency())
	if has_trait("Caring"):
		chance = minf(0.85, chance + 0.2) # his men get carried off, not left
	soldier_fell.emit(t.pos, color, who, randf() < chance)
	soldier_count -= 1
	# Each loss hurts relative to squad size (tuned for 10), and more when overloaded
	morale -= MORALE_PER_CASUALTY * 10.0 / maxf(_start_count, 1.0) * (2.0 - efficiency()) * _charisma_loss_mult() * _familiarity_loss_mult()
	if soldier_count <= 0:
		died.emit(self)
		queue_free()
		return
	_check_rout()


# --- Orders ----------------------------------------------------------------

## Move to a position. Pass a facing angle (radians) to turn that way on
## arrival, or leave it out to keep the walking direction.
func move_to(pos: Vector2, facing: float = NAN) -> void:
	if routing:
		return
	attack_target = null
	attack_dir = Vector2.ZERO
	if Terrain.in_water(pos):
		pos = Terrain.bank_point(pos, Terrain.bank_side(global_position)) # stop at the near bank
	target_position = pos
	has_target_facing = not is_nan(facing)
	target_facing = facing


## A move order given to a squad in melee: it turns its back and pulls out
## at full speed. The price: some morale, and the enemy gets free hits on its
## back while still in contact. The enemy needs a moment before it can follow.
func withdraw_to(pos: Vector2, facing: float = NAN) -> void:
	var foe := engaged_with
	move_to(pos, facing)
	if foe == null or not is_instance_valid(foe) or routing:
		return
	withdrawing = WITHDRAW_TIME
	engaged_with = null
	morale -= WITHDRAW_MORALE
	foe.enemy_withdrew()
	_check_rout()


## Our opponent just pulled out: stand and re-form for a moment.
func enemy_withdrew() -> void:
	_reform = REFORM_TIME


## Close with an enemy squad and fight it. A planned attack hits harder on
## first contact ("they were waiting for us!").
func attack(enemy: Squad, planned: bool = false) -> void:
	if routing:
		return
	if enemy != attack_target:
		attack_dir = Vector2.ZERO
	attack_target = enemy
	has_target_facing = false
	_planned_charge = planned


## Planning phase only: put the squad straight at a spot.
func place_at(pos: Vector2, facing: float) -> void:
	global_position = pos
	rotation = facing
	target_position = pos
	has_target_facing = false
	attack_target = null
	_sync_men(true)
	queue_redraw() # the world is frozen while planning, so redraw now


# --- Block geometry -------------------------------------------------------------

## Half width (across the front) and half depth of the block.
func half_size() -> Vector2:
	var rows := maxi(ceili(float(soldier_count) / COLUMNS), 1)
	var width := mini(maxi(soldier_count, 1), COLUMNS)
	return Vector2((width - 1) * SPACING * 0.5 + SOLDIER_RADIUS, (rows - 1) * SPACING * 0.5 + SOLDIER_RADIUS)


## How far from the middle the block's edge is, in direction `dir`.
func reach_toward(dir: Vector2) -> float:
	var h := half_size()
	var f := Vector2.RIGHT.rotated(rotation)
	return absf(dir.dot(f)) * h.y + absf(dir.dot(f.orthogonal())) * h.x


## Where our middle stands to fight `t` from side `dir`: our front rank on its edge.
func contact_spot(t: Squad, dir: Vector2) -> Vector2:
	return t.center() + dir * (t.reach_toward(dir) + half_size().y + REACH * 0.5)


## The side of `t` to attack from: one of its four real sides (front, left,
## right, rear), nearest to us first, skipping any another block already holds.
## Square to the side, so our whole front rank gets to fight.
func _pick_side(t: Squad) -> Vector2:
	var base := (center() - t.center()).normalized()
	if base == Vector2.ZERO:
		base = Vector2.RIGHT.rotated(rotation + PI)
	var f := Vector2.RIGHT.rotated(t.rotation)
	var sides: Array[Vector2] = [f, -f, f.orthogonal(), -f.orthogonal()]
	sides.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.dot(base) > b.dot(base))
	var tries: Array[Vector2] = []
	if attack_dir != Vector2.ZERO:
		# keep the side we chose (it turns with the target) while it's free
		var keep := sides[0]
		for d in sides:
			if d.dot(attack_dir) > keep.dot(attack_dir):
				keep = d
		tries.append(keep)
	tries.append_array(sides)
	var mine := half_size().length()
	for dir in tries:
		var spot := contact_spot(t, dir)
		var free := true
		for node in get_tree().get_nodes_in_group("squads"):
			var o := node as Squad
			if o == null or o == self or o == t or o.routing or o.soldier_count <= 0:
				continue
			var there := o.center()
			if o.attack_target == t and o.attack_dir != Vector2.ZERO:
				there = o.contact_spot(t, o.attack_dir) # where it's going, not where it is
			if there.distance_to(spot) < (mine + o.half_size().length()) * 0.8:
				free = false
				break
		if free:
			return dir
	return sides[0]


# --- Movement --------------------------------------------------------------

func _move(delta: float) -> void:
	var turn := minf(1.0, turn_speed * delta)
	if _reform > 0.0:
		_reform -= delta
		if not in_contact:
			return # re-forming after the enemy pulled away: not chasing yet

	# Where the block's MIDDLE should go, and which way to face there
	var dest := target_position + (center() - global_position)
	var face_to := target_facing if has_target_facing else NAN
	var hold := false
	if attack_target != null:
		# Close on a free side of the target, not its middle: a second squad
		# wraps round to the flank instead of shoving the first from behind
		_side_timer -= delta
		if _side_timer <= 0.0 or attack_dir == Vector2.ZERO:
			attack_dir = _pick_side(attack_target)
			_side_timer = SIDE_REPICK
		dest = contact_spot(attack_target, attack_dir)
		face_to = (attack_target.center() - dest).angle()
		# Stand once in place; caught on a corner short of our side, edge round
		hold = in_contact and (center().distance_to(dest) < SLIDE_DONE or _fighting >= mini(soldier_count, COLUMNS) * 0.6)
	elif in_contact and withdrawing <= 0.0:
		hold = true # attacked while standing: fight where we face
	if hold:
		return # locked in melee: no moving, no wheeling round

	var from := center()
	var to_target := Terrain.waypoint(from, dest) - from # the stream is crossed at the bridge or a ford
	var dist := to_target.length()
	var speed := move_speed * (0.6 + 0.4 * efficiency()) * Terrain.speed_mult(from)
	if rallying:
		speed *= RALLY_SPEED_MULT
	if in_contact and withdrawing <= 0.0:
		speed *= SLIDE_SPEED
	if dist > 1.0:
		if not in_contact or withdrawing > 0.0:
			rotation = lerp_angle(rotation, to_target.angle(), turn)
		_step(to_target / dist * minf(speed * delta, dist))
	elif not is_nan(face_to) and not in_contact:
		rotation = lerp_angle(rotation, face_to, turn)


## Routing squads run for their own map edge and leave the battle,
## unless they reach their Commander's aura first: then the survivors
## rally and join the Commander's own squad.
func _flee(delta: float) -> void:
	var edge := Vector2(-200.0 if team == 0 else View.MAP_SIZE.x + 200.0, global_position.y)
	var dir := (Terrain.waypoint(global_position, edge) - global_position).normalized()
	rotation = lerp_angle(rotation, dir.angle(), minf(1.0, turn_speed * delta))
	_step(dir * move_speed * FLEE_SPEED_MULT * Terrain.speed_mult(center()) * delta)

	var cmd := _own_commander_in_aura()
	if cmd != null and not _rallied_once:
		_start_rally(cmd)
		return

	if not _map_rect().grow(60.0).has_point(global_position):
		died.emit(self)
		queue_free()


## Turning (or shrinking) shifts the formation's middle; if that leaves it
## standing in the stream, step back onto the bridge or the bank.
func _dry_out() -> void:
	var c := center()
	if not Terrain.in_water(c):
		return
	var dry := Terrain.bank_point(c, Terrain.bank_side(global_position), 4.0)
	for cr in Terrain.crossings():
		var x: Vector2 = cr[0]
		if absf(c.y - x.y) < float(cr[1]) + 24.0:
			var half: float = float(cr[1]) - 4.0
			dry = Vector2(c.x, x.y + clampf(c.y - x.y, -half, half))
			break
	global_position += dry - c


## Move by `by`, but never into the stream: slide along the bank instead.
func _step(by: Vector2) -> void:
	var c := center()
	if Terrain.in_water(c):
		global_position += by # already wet (pushed in): let it walk out
		return
	if not Terrain.in_water(c + by):
		global_position += by
	elif not Terrain.in_water(c + Vector2(0, by.y)):
		global_position += Vector2(0, by.y)
	elif not Terrain.in_water(c + Vector2(by.x, 0)):
		global_position += Vector2(by.x, 0)


## The battlefield: the game's base resolution (independent of window size).
func _map_rect() -> Rect2:
	return Rect2(Vector2.ZERO, View.MAP_SIZE)


## Commander only: take in rallied soldiers. They arrive shaken, so the
## Commander's squad loses a little morale (but never breaks from this).
func absorb(count: int, positions := PackedVector2Array(), new_members: Array[Soldier] = []) -> void:
	members.append_array(new_members)
	# The newcomers start where they actually are and walk into formation
	for k in count:
		var m := Man.new()
		m.sq = self
		m.hp = MAN_HP
		m.cool = randf_range(0.0, SWING_TIME)
		m.pos = positions[k] if k < positions.size() else global_position
		_m.append(m)
	soldier_count += count
	morale = maxf(rout_threshold() + 10.0, morale - RALLY_MORALE_COST)
	queue_redraw()


func _men_positions() -> PackedVector2Array:
	var out := PackedVector2Array()
	for m in _m:
		out.append(m.pos)
	return out


# --- Rallying --------------------------------------------------------------

func _start_rally(cmd: Squad) -> void:
	routing = false
	rallying = true
	_rallied_once = true
	_rally_to = cmd
	morale = RALLY_MORALE
	attack_target = null
	target_position = global_position
	rally_started.emit(self)


## Each frame while rallying: fight beside the Commander if it is in melee,
## otherwise walk to it and fall in once close enough.
func _rally_step() -> void:
	var cmd := _rally_to
	if cmd == null or not is_instance_valid(cmd) or cmd.routing:
		rallying = false # nobody to rally to: stand as an ordinary squad
		return
	var foe := cmd.engaged_with
	if foe != null and is_instance_valid(foe) and not foe.routing:
		if attack_target != foe:
			attack(foe)
		return
	if attack_target != null and engaged_with == null:
		attack_target = null
	if engaged_with != null:
		return # finish the fight we're in first
	target_position = cmd.global_position
	var gap := center().distance_to(cmd.center()) - radius() - cmd.radius()
	if gap < RALLY_JOIN_GAP:
		rallied.emit(self, cmd, soldier_count)
		cmd.absorb(soldier_count, _men_positions(), members.duplicate())
		for m in _m:
			m.alive = false
		died.emit(self)
		queue_free()


# --- Morale ----------------------------------------------------------------

func _check_rout() -> void:
	if routing or morale > rout_threshold():
		return
	# The Commander holds as long as the bodyguard still stands
	if is_commander and soldier_count > COMMANDER_LAST_STAND:
		morale = rout_threshold()
		return
	routing = true
	rallying = false
	engaged_with = null
	in_contact = false
	attack_target = null
	selected = false
	for m in _m:
		m.target = null
	routed.emit(self)
	# Panic spreads to nearby allies (not when a squad that already broke once
	# breaks again: nobody expected much of them by then)
	if _rallied_once:
		return
	for node in get_tree().get_nodes_in_group("squads"):
		var ally := node as Squad
		if ally == null or ally == self or ally.team != team or ally.routing:
			continue
		if global_position.distance_to(ally.global_position) < ROUT_SHOCK_RADIUS:
			ally.morale_shock(ROUT_SHOCK)


## 1.0 at or under Command; drops 0.5 for every extra "Command's worth" of
## soldiers, down to 0.3. Recovers as an overloaded squad loses soldiers.
## Command plus up to +5 for men who know their leader well: a veteran
## squad can be a little bigger before it gets clumsy.
func command_effective() -> float:
	return command + FAMILIARITY_COMMAND_BONUS * familiarity() / 100.0


func efficiency() -> float:
	var cmd := command_effective()
	if cmd <= 0.0 or soldier_count <= cmd:
		return 1.0
	var overload := float(soldier_count) / cmd
	var slope := 0.5
	if has_trait("Disciplinarian"):
		slope = 0.3 # the men keep order even when there are too many of them
	elif has_trait("Small-unit specialist"):
		slope = 0.7
	return maxf(MIN_EFFICIENCY, 1.0 - slope * (overload - 1.0))


# --- Leader stats and traits ------------------------------------------------
# Squads without a leader record (the enemy) count as average: 50 in every stat.

func stat(stat_name: String) -> float:
	if leader == null:
		return 50.0
	return float(leader.get(stat_name))


func has_trait(t: String) -> bool:
	return leader != null and t in leader.traits


## Charisma 0 -> x1.2 morale lost per casualty, 50 -> x1.0, 100 -> x0.8
func _charisma_loss_mult() -> float:
	return 1.2 - stat("charisma") * 0.004


## Valor 0 -> x0.8 damage, 50 -> x1.0, 100 -> x1.2 (plus trait bonuses)
func _valor_damage_mult() -> float:
	var m := 0.8 + stat("valor") * 0.004
	if has_trait("Hothead"):
		m *= 1.25
	if has_trait("Small-unit specialist") and soldier_count <= 15:
		m *= 1.2
	return m


func rout_threshold() -> float:
	return STEADY_ROUT_THRESHOLD if has_trait("Steady") else ROUT_THRESHOLD


func _near_inspiring_leader() -> bool:
	for node in get_tree().get_nodes_in_group("squads"):
		var other := node as Squad
		if other != null and other != self and other.team == team and not other.routing \
				and other.has_trait("Inspiring") \
				and global_position.distance_to(other.global_position) < INSPIRING_RADIUS:
			return true
	return false


func is_overloaded() -> bool:
	return soldier_count > command_effective()


## Veterans hold their nerve: x1.15 morale lost per casualty for raw
## recruits, x0.85 for men who've been through it all with their leader.
func _familiarity_loss_mult() -> float:
	return 1.15 - 0.3 * familiarity() / 100.0


func _near_own_commander() -> bool:
	return _own_commander_in_aura() != null


## Our Commander, if we're inside its aura and it isn't fleeing itself.
func _own_commander_in_aura() -> Squad:
	if is_commander:
		return null
	for node in get_tree().get_nodes_in_group("commanders"):
		var c := node as Squad
		if c != null and c.team == team and not c.routing \
				and global_position.distance_to(c.global_position) < COMMANDER_AURA_RADIUS:
			return c
	return null


func morale_shock(amount: float) -> void:
	if routing:
		return
	# The Commander doesn't panic when others do
	morale -= amount * (0.25 if is_commander else 1.0)
	_check_rout()


## Middle of the formation (the node's origin is the middle of the front rank).
func center() -> Vector2:
	var rows := ceili(float(soldier_count) / COLUMNS)
	return global_position - Vector2.RIGHT.rotated(rotation) * (maxi(rows, 1) - 1) * SPACING * 0.5


## Size of the formation as a circle, used for keeping squads apart and for
## labels. Half the diagonal: a block turned at an angle still fits inside, so
## neighbours' corners don't overlap.
func radius() -> float:
	return half_size().length() + 2.0


# --- Drawing ---------------------------------------------------------------

## Where soldier `i` stands in the formation (local space, front = +X).
## Ranks go backward along -X; a partial last rank is centred.
func _slot(i: int) -> Vector2:
	var row := int(i / float(COLUMNS))
	var col := i % COLUMNS
	var in_row := mini(COLUMNS, soldier_count - row * COLUMNS)
	return Vector2(-row * SPACING, (col - (in_row - 1) / 2.0) * SPACING)


func _draw() -> void:
	if concealed:
		_draw_concealed()
		return

	var rows := maxi(ceili(float(soldier_count) / COLUMNS), 1)
	var base_c := color
	if routing:
		base_c = Color(color.darkened(0.35).lerp(Color(0.5, 0.5, 0.5), 0.4), 0.85)

	# Selection: a soft footprint with corner brackets, on the ground
	if selected:
		var b := _local_bounds(rows).grow(3.0)
		draw_rect(b, Color(1.0, 0.9, 0.35, 0.12), true)
		_draw_brackets(b, Color(1.0, 0.9, 0.35, 0.95))

	# Flank marker: a bright arc on the ground on the side being hit
	if flank_t > 0.0 and not routing:
		draw_set_transform(Vector2.ZERO, -rotation)
		var mid_w := center() - global_position
		var r := half_size().length() + 8.0
		var a0 := flank_dir.angle()
		var alpha := minf(1.0, flank_t)
		draw_arc(mid_w, r, a0 - 0.6, a0 + 0.6, 14, Color(1.0, 0.45, 0.2, 0.9 * alpha), 4.0)
		draw_arc(mid_w, r + 5.0, a0 - 0.35, a0 + 0.35, 10, Color(1.0, 0.45, 0.2, 0.5 * alpha), 2.0)
		draw_set_transform(Vector2.ZERO, 0.0)

	# Shadows on the ground (the camera turns these circles into ellipses)
	for m in _m:
		draw_circle(to_local(m.pos) + Vector2(1.5, 1.0).rotated(-rotation), SOLDIER_RADIUS + 0.8, Color(0, 0, 0, 0.32))

	# Upright figures, far ones first so near ones overlap them
	var order := _m.duplicate()
	order.sort_custom(func(a: Man, b: Man) -> bool: return a.pos.y < b.pos.y)
	var squad_face := Vector2.RIGHT.rotated(rotation)
	for m: Man in order:
		var face_world := squad_face
		if m.target != null:
			face_world = (m.target.pos - m.pos).normalized()
		elif routing:
			face_world = squad_face
		var face_screen := View.to_screen(face_world).normalized()
		var c := base_c.lerp(Color.WHITE, 0.7) if m.flash > 0.0 else base_c
		var outline := Color(c.darkened(0.6), c.a)
		var thrust := sin(m.swing / SWING_ANIM * PI) * 5.0 if m.swing > 0.0 else 0.0
		draw_set_transform_matrix(_upright_at(to_local(m.pos)))
		_draw_man(c, outline, face_screen, not routing, thrust)
	draw_set_transform(Vector2.ZERO, 0.0)

	# Sparks where our men were struck (orange for blows in the flank)
	for sp in _sparks:
		var p: Vector2 = sp.pos
		var a: float = sp.left / 0.15
		var col := Color(1.0, 0.6, 0.25, a) if sp.flank else Color(1, 0.95, 0.6, a)
		draw_set_transform_matrix(_upright_at(to_local(p)))
		for k in 4:
			var d := Vector2.from_angle(k * PI / 2.0 + 0.6)
			draw_line(d * 1.5 + Vector2(0, -7), d * (5.5 if sp.flank else 4.5) + Vector2(0, -7), col, 1.3)
	draw_set_transform(Vector2.ZERO, 0.0)

	# Middle of where the men actually stand, world axes
	var mid := center() - global_position
	if not _m.is_empty():
		var sum := Vector2.ZERO
		for m in _m:
			sum += m.pos
		mid = sum / _m.size() - global_position
	# Banner just behind the block
	var back := mid - Vector2.RIGHT.rotated(rotation) * ((rows - 1) * SPACING * 0.5 + 9.0)

	# Commander's aura lies on the ground
	if is_commander and not routing:
		draw_set_transform(Vector2.ZERO, -rotation)
		_draw_aura()

	# Upright things above the squad: banner, morale bar, flank tag (screen units)
	draw_set_transform_matrix(_upright_at(Vector2.ZERO))
	var sback := View.to_screen(back)
	var smid := View.to_screen(mid)
	if not routing:
		var pole_top := sback + Vector2(0, -34 if is_commander else -27)
		draw_line(sback + Vector2(1, 0), pole_top + Vector2(1, 0), Color(0, 0, 0, 0.3), 2.0)
		draw_line(sback, pole_top, Color(0.45, 0.33, 0.2), 2.0)
		var w := 16.0 if is_commander else 11.0
		var h := 9.0 if is_commander else 7.0
		var flag := PackedVector2Array([pole_top, pole_top + Vector2(w, 3), pole_top + Vector2(0, h)])
		draw_colored_polygon(flag, color.lightened(0.1))
		draw_polyline(PackedVector2Array([pole_top, pole_top + Vector2(w, 3), pole_top + Vector2(0, h), pole_top]), color.darkened(0.5), 1.0)
		if is_commander:
			draw_circle(pole_top + Vector2(5, 4), 1.8, Color(0.95, 0.95, 0.9))

	var bar_pos := smid + Vector2(-19, -radius() * View.TILT - 26.0)
	draw_rect(Rect2(bar_pos - Vector2(1, 1), Vector2(40, 7)), Color(0, 0, 0, 0.6), true)
	var frac := clampf(morale / MAX_MORALE, 0.0, 1.0)
	var bar_color := Color(0.45, 0.85, 0.4)
	if frac < 0.5:
		bar_color = Color(0.95, 0.75, 0.25)
	if frac < 0.25:
		bar_color = Color(0.95, 0.32, 0.28)
	draw_rect(Rect2(bar_pos, Vector2(38 * frac, 5)), bar_color, true)
	draw_rect(Rect2(bar_pos, Vector2(38 * frac, 2)), bar_color.lightened(0.3), true)
	if flank_t > 0.0 and not routing:
		# Ours flanked: a warning. Theirs: your plan working.
		var tag := "REAR!" if flank_rear else "FLANKED"
		var tc := Color(1.0, 0.5, 0.3) if team == 0 else Color(0.6, 1.0, 0.5)
		var font := ThemeDB.fallback_font
		# Same size on screen at any camera zoom
		var z := maxf(get_canvas_transform().x.length(), 0.01)
		var at := bar_pos + Vector2(19, -4)
		draw_set_transform_matrix(_upright_at(Vector2.ZERO) * Transform2D(0.0, Vector2.ONE / z, 0.0, at))
		draw_string_outline(font, Vector2(-60, 0), tag, HORIZONTAL_ALIGNMENT_CENTER, 120, 12, 3, Color(0, 0, 0, 0.6 * minf(1.0, flank_t)))
		draw_string(font, Vector2(-60, 0), tag, HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(tc, minf(1.0, flank_t)))
	draw_set_transform(Vector2.ZERO, 0.0)


## Drawing transform for upright things standing at local point `p`:
## first turn back to the world's axes (undo the squad's rotation), then undo
## the camera's vertical squash. Built as a matrix because
## draw_set_transform() applies scale and rotation in the other order, which
## shears everything on squads that aren't facing straight left or right.
func _upright_at(p: Vector2) -> Transform2D:
	return Transform2D(-rotation, p) * Transform2D(0.0, View.upright_scale(), 0.0, Vector2.ZERO)


## One soldier standing at (0, 0), drawn upright in screen units.
## face = the direction he faces on screen; thrust = how far his spear is
## pushed out (a swing). Shield and spear go in front of the body, or behind
## it when he faces away from the camera.
func _draw_man(c: Color, outline: Color, face: Vector2, armed: bool, thrust := 0.0) -> void:
	var away := face.y < -0.25
	var wood := Color(0.55, 0.42, 0.26, c.a)
	var metal := Color(0.85, 0.85, 0.8, c.a)
	var shield_at := Vector2(0, -6.0) + face * 3.4
	var spear_a := Vector2(0, -5.0) - face * 3.0 + face * thrust
	var spear_b := Vector2(0, -12.0) + face * (9.0 + thrust)

	if armed and away:
		draw_line(spear_a, spear_b, wood, 1.1)
		draw_circle(spear_b, 1.0, metal)
		draw_circle(shield_at, 3.0, outline)
		draw_circle(shield_at, 2.3, c.darkened(0.25))

	# Body (a little capsule) and helmeted head
	draw_circle(Vector2(0, -3.2), 3.6, outline)
	draw_circle(Vector2(0, -6.2), 3.6, outline)
	draw_circle(Vector2(0, -3.2), 2.8, c)
	draw_circle(Vector2(0, -6.2), 2.8, c)
	draw_circle(Vector2(-1.0, -7.0), 1.1, Color(c.lightened(0.35), c.a))
	draw_circle(Vector2(0, -11.0), 2.7, outline)
	draw_circle(Vector2(0, -11.0), 2.0, Color(c.darkened(0.25).lerp(Color(0.6, 0.6, 0.62), 0.45), c.a))
	draw_circle(Vector2(-0.7, -11.7), 0.7, Color(1, 1, 1, 0.5 * c.a))

	if armed and not away:
		draw_line(spear_a, spear_b, wood, 1.1)
		draw_circle(spear_b, 1.0, metal)
		draw_circle(shield_at, 3.0, outline)
		draw_circle(shield_at, 2.3, c.darkened(0.25))
		draw_circle(shield_at, 0.8, metal)


## Corner brackets around a rectangle (local space).
func _draw_brackets(b: Rect2, c: Color) -> void:
	var l := 7.0
	for corner in [b.position, Vector2(b.end.x, b.position.y), b.end, Vector2(b.position.x, b.end.y)]:
		var sx := 1.0 if corner.x == b.position.x else -1.0
		var sy := 1.0 if corner.y == b.position.y else -1.0
		draw_line(corner, corner + Vector2(l * sx, 0), c, 2.0)
		draw_line(corner, corner + Vector2(0, l * sy), c, 2.0)


## Commander only: a soft disc with a dashed rim (drawn upright).
func _draw_aura() -> void:
	var r := COMMANDER_AURA_RADIUS
	draw_circle(Vector2.ZERO, r, Color(color, 0.045))
	var segments := 40
	var step := TAU / segments
	var spin := Time.get_ticks_msec() / 6000.0
	for k in segments:
		var a := k * step + spin
		draw_arc(Vector2.ZERO, r, a, a + step * 0.55, 4, Color(color, 0.40), 1.5)


## Unscouted enemy: a patch of fog with a question mark; its size is hidden.
func _draw_concealed() -> void:
	draw_set_transform_matrix(_upright_at(Vector2.ZERO))
	var fog := Color(0.82, 0.82, 0.86, 0.22)
	for off in [Vector2(-16, -10), Vector2(12, -14), Vector2(14, -2), Vector2(-12, 0), Vector2(0, -20), Vector2(0, -6)]:
		draw_circle(off, 16.0, fog)
	var font := ThemeDB.fallback_font
	draw_string_outline(font, Vector2(-14, 0), "?", HORIZONTAL_ALIGNMENT_CENTER, 28, 28, 4, Color(0, 0, 0, 0.6))
	draw_string(font, Vector2(-14, 0), "?", HORIZONTAL_ALIGNMENT_CENTER, 28, 28, color.lightened(0.2))
	draw_set_transform(Vector2.ZERO, 0.0)


func _local_bounds(rows: int) -> Rect2:
	var half_w := (COLUMNS - 1) / 2.0 * SPACING + SOLDIER_RADIUS + 4.0
	var back := (maxi(rows, 1) - 1) * SPACING + SOLDIER_RADIUS + 4.0
	return Rect2(Vector2(-back, -half_w), Vector2(back + SOLDIER_RADIUS + 4.0, half_w * 2.0))


## Index of the man under `point` (his feet or his body), or -1.
func man_at(point: Vector2) -> int:
	var best := -1
	var best_d := SOLDIER_RADIUS + 3.0
	var body_up := Vector2(0, -7.0 / View.TILT)
	for i in _m.size():
		var d := minf(_m[i].pos.distance_to(point), (_m[i].pos + body_up).distance_to(point))
		if d < best_d:
			best_d = d
			best = i
	return best


func man_position(i: int) -> Vector2:
	return _m[i].pos


## In a forest with no enemy close enough to see in: the enemy doesn't know
## we're here.
func is_hidden() -> bool:
	if routing or not Terrain.in_forest(center()):
		return false
	for node in get_tree().get_nodes_in_group("squads"):
		var other := node as Squad
		if other != null and other.team != team and not other.routing \
				and other.center().distance_to(center()) < Terrain.FOREST_HIDE_RADIUS:
			return false
	return true


## Average familiarity of the men with their leaders (0..100).
func familiarity() -> float:
	if members.is_empty():
		return 50.0 # the enemy (no soldier records): an average, drilled army
	var sum := 0.0
	for m in members:
		sum += m.familiarity
	return sum / members.size()


## For box selection: true if any part of the squad you can see is inside
## `rect`: a soldier's feet, his body (drawn above his feet), or the
## formation's middle.
func touches_rect(rect: Rect2) -> bool:
	if rect.has_point(center()) or rect.has_point(global_position):
		return true
	var body_up := Vector2(0, -9.0 / View.TILT)
	for m in _m:
		if rect.has_point(m.pos) or rect.has_point(m.pos + body_up):
			return true
	return false


func contains_point(global_point: Vector2) -> bool:
	var rows := ceili(float(soldier_count) / COLUMNS)
	# Figures stand upright, so a click on a body is "above" its feet: test
	# the click point and the ground point under it.
	for q in [global_point, global_point + Vector2(0, 12.0 / View.TILT)]:
		if _local_bounds(rows).has_point(to_local(q)):
			return true
		for m in _m: # soldiers stepping out to fight can be clicked too
			if m.pos.distance_to(q) < SOLDIER_RADIUS + 5.0:
				return true
	return false
