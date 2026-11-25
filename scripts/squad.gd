class_name Squad
extends Node2D

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

# --- Combat tuning ---
const ENGAGE_GAP := 8.0 # formations closer than this (edge to edge) are in melee
const DAMAGE_PER_SOLDIER := 0.03 # enemy casualties per soldier per second (lower = longer fights)
const ENGAGED_SPEED_MULT := 0.3 # squads in melee can only shuffle slowly
const ENGAGED_TURN_SPEED := 1.5 # and turn slowly, so flanks pay off
const SIDE_MULT := 1.5 # damage multiplier when hit from the side
const REAR_MULT := 2.5 # damage multiplier when hit from behind
const FLASH_TIME := 0.15

# --- Morale tuning ---
const MAX_MORALE := 100.0
const ROUT_THRESHOLD := 15.0 # break and flee below this
const STEADY_ROUT_THRESHOLD := 5.0 # ...or this, under a Steady leader
const INSPIRING_RADIUS := 150.0
const INSPIRING_REGEN := 0.9 # morale/s for allies near an Inspiring leader
const MORALE_PER_CASUALTY := 8.0 # lost for each soldier who falls
const MORALE_ENGAGED_DRAIN := 0.95 # per second just from being in melee (scaled with damage)
const MORALE_FLANK_DRAIN := 5.25 # per second, scaled by (flank mult - 1) (scaled with damage)
const MORALE_RECOVERY := 4.0 # per second while out of combat
const ROUT_SHOCK := 20.0 # lost by nearby allies when a squad routs
const ROUT_SHOCK_RADIUS := 150.0
const FLEE_SPEED_MULT := 1.3 # routers run faster than pursuers walk
const PLANNED_CHARGE_SHOCK := 20.0 # morale hit on first contact of a planned attack
const MIN_EFFICIENCY := 0.3
const FAMILIARITY_COMMAND_BONUS := 5.0 # extra effective Command at familiarity 100
const WOUNDED_CHANCE := 0.5 # share of casualties who are wounded rather than killed
const WOUNDED_CHANCE_FLEEING := 0.25 # men cut down while running mostly die

# --- Individual soldiers (how the melee looks) ---
const MAN_SPEED := 75.0 # how fast a soldier walks to his spot (px/s)
const WITHDRAW_TIME := 1.6 # seconds a withdrawing squad ignores the fight and moves at full speed
const WITHDRAW_MORALE := 8.0 # turning your back on the enemy costs nerve
const REFORM_TIME := 1.2 # the enemy we left needs this long before it can follow
const ENGAGE_RELEASE := 14.0 # stay in melee until the gap grows this much past ENGAGE_GAP
const MELEE_LINGER := 0.6 # seconds the men keep their melee spots after contact breaks
const RALLY_MORALE := 60.0 # morale of a fleeing squad that reaches the Commander's circle
const RALLY_SPEED_MULT := 1.15 # rallying men hurry to the Commander
const RALLY_JOIN_GAP := 16.0 # close enough to the Commander's squad to fall in
const ENVELOP_DAMAGE := 0.4 # up to +40% damage when we clearly outnumber our target
const ENVELOP_MORALE := 6.0 # up to this much extra morale drain per second on them
const COMMANDER_AURA_RADIUS := 160.0
const COMMANDER_AURA_REGEN := 0.75 # morale per second for allies near the commander, even in melee
const COMMANDER_LAST_STAND := 3 # the Commander only breaks once the guard is down to this
const COMMANDER_GUARD_DAMAGE := 2.0 # elite bodyguard hits twice as hard
const COMMANDER_GUARD_TOUGHNESS := 0.5 # ...and takes half the losses
const RALLY_MORALE_COST := 10.0 # Commander's squad morale lost when shaken routers join

var target_position: Vector2
var target_facing: float = 0.0
var has_target_facing := false
var attack_target: Squad = null
var engaged_with: Squad = null
var morale := MAX_MORALE
var routing := false

## Our side only: the leader and the soldiers (Soldier records). members[i]
## is the man standing at _men[i].
var leader: Leader = null
var members: Array[Soldier] = []
var _men := PackedVector2Array() # where each soldier actually stands (global)
var _ring := PackedInt32Array() # each man's place in the melee ring (-1 = none yet)
var _melee_foe: Squad = null # the squad our men are currently wrapped around
var _melee_base := 0.0 # direction of first contact (fixed for the whole fight)
var _melee_off := Vector2.ZERO # ring centre relative to the foe's origin, fixed at contact
var _melee_linger := 0.0
## Rallying: a squad that fled into the Commander's circle walks back to the
## Commander and joins its squad. Only once per squad.
var withdrawing := 0.0 # time left pulling out of a fight
var _reform := 0.0 # time left re-forming after the enemy pulled away
var rallying := false
var _rallied_once := false
var _rally_to: Squad = null
var _start_count := 0 # soldiers at the start of battle, for morale scaling
var _planned_charge := false # next contact with attack_target is a planned surprise
var _incoming := 0.0 # fractional casualties waiting to become whole soldiers
var _flash := 0.0

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


func _process(delta: float) -> void:
	if routing:
		_flee(delta)
	else:
		if attack_target != null and (not is_instance_valid(attack_target) or attack_target.soldier_count <= 0):
			attack_target = null
			target_position = global_position
		if rallying:
			_rally_step()
		if attack_target != null:
			target_position = attack_target.global_position

		if withdrawing > 0.0:
			withdrawing -= delta
			engaged_with = null # backs turned: no fighting back while pulling out
		else:
			engaged_with = _find_engaged_enemy()
		if engaged_with != null:
			if _planned_charge and engaged_with == attack_target:
				_planned_charge = false
				engaged_with.morale_shock(PLANNED_CHARGE_SHOCK * (2.0 if has_trait("Ambusher") else 1.0))
			_fight(delta)
			morale -= MORALE_ENGAGED_DRAIN * delta
		else:
			morale = minf(MAX_MORALE, morale + MORALE_RECOVERY * (0.5 + stat("charisma") / 100.0) * delta)
		if _near_inspiring_leader():
			morale = minf(MAX_MORALE, morale + INSPIRING_REGEN * delta)
		if _near_own_commander():
			morale = minf(MAX_MORALE, morale + COMMANDER_AURA_REGEN * delta)
		_move(delta)
		_check_rout()
	_dry_out()

	_update_men(delta)
	if _flash > 0.0:
		_flash -= delta
	queue_redraw() # soldiers and morale bar change every frame


# --- Individual soldiers ---------------------------------------------------
# Out of combat every soldier walks to his place in the formation. In melee
# they spread out around the enemy squad: the first ones at the point of
# contact, the rest fanning out to both sides, and with enough men a second
# ring, so a big squad visibly surrounds a small one.

## Keep one position per soldier. snap = put everyone straight in formation.
func _sync_men(snap: bool) -> void:
	while _men.size() < soldier_count:
		_men.append(to_global(_slot(_men.size())))
		_ring.append(-1)
	if _men.size() > soldier_count:
		_men.resize(soldier_count)
		_ring.resize(soldier_count)
	if snap:
		for i in soldier_count:
			_men[i] = to_global(_slot(i))


## How many of a squad of `mine` men fight in its front row against `theirs`.
static func _frontage(mine: int, theirs: int) -> int:
	return mini(mine, maxi(3, ceili(theirs * 0.6)))


## Melee place number `rank` (0 = first in line) for a fight against `foe`.
## Both sides meet at a contact line between them and stand on their own side
## of it: our front row against the line, the rest in rows behind. Only when we
## outnumber them do the extra men go round their flanks and close in behind.
func _melee_point(foe: Squad, rank: int) -> Vector2:
	var n := soldier_count
	var f := foe.soldier_count
	var u := Vector2.RIGHT.rotated(_melee_base) # from them toward us
	var v := u.orthogonal()
	# Contact line: halfway across the gap between the two formations, so both
	# sides compute the same line and each stands on its own side of it.
	# (Anchored to their origin so it doesn't swing about when they turn.)
	var gap := center().distance_to(foe.center()) - radius() - foe.radius()
	var reach := foe.radius() + maxf(gap, 0.0) * 0.5
	if foe._attacker_count() >= 2:
		# They've closed up into a block: keep clear of its corners
		reach = maxf(reach, foe.radius() * 1.25 + 2.0)
	var contact := foe.global_position + _melee_off + u * reach
	var sp := SPACING * 0.95
	var front := _frontage(n, f)
	var wrap := clampi(n - f, 0, n - front) # only the men we have to spare
	var their_front := _frontage(f, n)
	var their_half := (their_front - 1) * 0.5 * sp

	if rank < front:
		# Front row, filled from the middle outward
		var side := 1.0 if rank % 2 == 1 else -1.0
		var off := side * int((rank + 1) / 2.0) * sp
		if front % 2 == 0:
			off += sp * 0.5
		return contact + u * 5.0 + v * off
	rank -= front
	if rank < wrap:
		# Round their flanks: down each side, then in behind them
		var side := 1.0 if rank % 2 == 0 else -1.0
		var j := int(rank / 2.0)
		var depth := foe.radius() * 2.0 + sp
		var along := (j + 1) * sp
		if along <= depth:
			return contact - u * along + v * side * (their_half + sp)
		var inward := along - depth
		return contact - u * depth + v * side * maxf(0.0, their_half + sp - inward)
	rank -= wrap
	# Everyone else: rows behind our front row
	var row := 1 + int(rank / float(front))
	var col := rank % front
	var off2 := (col - (front - 1) * 0.5) * sp
	return contact + u * (5.0 + row * sp) + v * off2


func _update_men(delta: float) -> void:
	_sync_men(false)
	var foe: Squad = null
	if not routing and engaged_with != null and is_instance_valid(engaged_with):
		foe = engaged_with
	# Keep the melee picture for a moment after contact breaks (no snapping)
	if foe == null and _melee_foe != null and is_instance_valid(_melee_foe) and not routing:
		_melee_linger -= delta
		if _melee_linger > 0.0:
			foe = _melee_foe
	if foe != null and foe == engaged_with:
		_melee_linger = MELEE_LINGER
	if foe != _melee_foe:
		_start_melee(foe)

	var step := MAN_SPEED * delta
	# Attacked from two or more sides: close up in our own formation and
	# hold together instead of forming a line against just one of them
	if foe != null and _attacker_count() >= 2:
		foe = null
	if foe == null:
		for i in soldier_count:
			_men[i] = _men[i].move_toward(to_global(_slot(i)), step + move_speed * delta)
		return
	for i in soldier_count:
		if _ring[i] < 0:
			_ring[i] = _next_ring_place()
	# Places are handed out in order of each man's fixed number, so when a man
	# falls the ones behind him step up one place (closing ranks) instead of
	# everyone reshuffling
	var order := range(soldier_count)
	order.sort_custom(func(a: int, b: int) -> bool: return _ring[a] < _ring[b])
	for rank in order.size():
		var i: int = order[rank]
		_men[i] = _men[i].move_toward(_melee_point(foe, rank), step)


## A new fight: fix the contact direction and hand out ring places once,
## nearest man to the contact point first. Places are then kept for the
## whole fight, so nobody shuffles when a neighbour falls.
func _start_melee(foe: Squad) -> void:
	_melee_foe = foe
	for i in soldier_count:
		_ring[i] = -1
	if foe == null:
		return
	_melee_base = (center() - foe.center()).angle()
	_melee_off = foe.center() - foe.global_position
	# Another of our squads already fighting this foe from about the same side?
	# Then take the flank instead of crowding into the same spot.
	var taken: Array[float] = []
	for node in get_tree().get_nodes_in_group("squads"):
		var ally := node as Squad
		if ally != null and ally != self and ally.team == team and ally._melee_foe == foe and is_instance_valid(foe):
			taken.append(ally._melee_base)
	for attempt in 6:
		var clash := false
		for b in taken:
			if absf(angle_difference(b, _melee_base)) < deg_to_rad(50.0):
				clash = true
				# step round to whichever side we're already leaning toward
				var lean := signf(angle_difference(b, _melee_base))
				_melee_base += (lean if lean != 0.0 else 1.0) * deg_to_rad(55.0)
				break
		if not clash:
			break
	var contact := foe.center() + Vector2.RIGHT.rotated(_melee_base) * foe.radius()
	var order := range(soldier_count)
	order.sort_custom(func(a: int, b: int) -> bool:
		return _men[a].distance_squared_to(contact) < _men[b].distance_squared_to(contact))
	for k in order.size():
		_ring[order[k]] = k


## How many enemy squads are fighting us right now.
func _attacker_count() -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group("squads"):
		var other := node as Squad
		if other != null and other.team != team and not other.routing and other.engaged_with == self:
			n += 1
	return n


func _next_ring_place() -> int:
	var hi := -1
	for k in _ring:
		hi = maxi(hi, k)
	return hi + 1


## The man most exposed: lowest ring place in melee, else the front rank.
func _front_man() -> int:
	if _men.is_empty():
		return -1
	var best := 0
	for i in _ring.size():
		if _ring[i] >= 0 and (_ring[best] < 0 or _ring[i] < _ring[best]):
			best = i
	return best


## How much we wrap around our target: 0 = even fight, 1 = clearly surrounding.
func _envelopment(defender: Squad) -> float:
	if defender.soldier_count <= 0:
		return 0.0
	return clampf((float(soldier_count) / defender.soldier_count - 1.0) / 1.0, 0.0, 1.0)


# --- Orders ----------------------------------------------------------------

## Move to a position. Pass a facing angle (radians) to turn that way on
## arrival, or leave it out to keep the walking direction.
func move_to(pos: Vector2, facing: float = NAN) -> void:
	if routing:
		return
	attack_target = null
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


## Chase an enemy squad and fight it. A planned attack hits harder on
## first contact ("they were waiting for us!").
func attack(enemy: Squad, planned: bool = false) -> void:
	if routing:
		return
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


# --- Movement --------------------------------------------------------------

func _move(delta: float) -> void:
	var turn := minf(1.0, turn_speed * delta)
	if _reform > 0.0:
		_reform -= delta
		if engaged_with == null:
			return # re-forming after the enemy pulled away: not chasing yet

	if engaged_with != null:
		# In melee: slowly turn to face the enemy
		var to_enemy := engaged_with.center() - center()
		rotation = lerp_angle(rotation, to_enemy.angle(), minf(1.0, ENGAGED_TURN_SPEED * delta))
		# Attacking squads hold their ground; others can only shuffle away slowly
		if attack_target != null:
			return

	# The stream is only crossed at the bridge
	var to_target := Terrain.waypoint(global_position, target_position) - global_position
	var dist := to_target.length()
	var speed := move_speed * (0.6 + 0.4 * efficiency()) * Terrain.speed_mult(center())
	if rallying:
		speed *= RALLY_SPEED_MULT
	if engaged_with != null:
		speed *= ENGAGED_SPEED_MULT
	if dist > 1.0:
		if engaged_with == null:
			rotation = lerp_angle(rotation, to_target.angle(), turn)
		_step(to_target / dist * minf(speed * delta, dist))
	elif has_target_facing and engaged_with == null:
		rotation = lerp_angle(rotation, target_facing, turn)


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
	_sync_men(false)
	soldier_count += count
	members.append_array(new_members)
	# The newcomers start where they actually are and walk into formation
	for p in positions:
		_men.append(p)
		_ring.append(-1)
	_sync_men(false)
	morale = maxf(rout_threshold() + 10.0, morale - RALLY_MORALE_COST)
	queue_redraw()


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
		_sync_men(false)
		rallied.emit(self, cmd, soldier_count)
		cmd.absorb(soldier_count, _men.duplicate(), members.duplicate())
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
	attack_target = null
	selected = false
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


## Called by an attacker each frame: flanked squads lose morale fast.
func apply_pressure(flank_mult: float, delta: float) -> void:
	if routing:
		return
	morale -= (flank_mult - 1.0) * MORALE_FLANK_DRAIN * delta * (0.5 if is_commander else 1.0)


# --- Combat ----------------------------------------------------------------

func _find_engaged_enemy() -> Squad:
	var my_center := center()
	# Stay with the current opponent until we've clearly separated: avoids
	# flickering in and out of melee right at the edge of contact.
	if engaged_with != null and is_instance_valid(engaged_with) and engaged_with.soldier_count > 0:
		var cur_gap := my_center.distance_to(engaged_with.center()) - radius() - engaged_with.radius()
		if cur_gap < ENGAGE_GAP + ENGAGE_RELEASE:
			return engaged_with
	var best: Squad = null
	var best_gap := ENGAGE_GAP
	for node in get_tree().get_nodes_in_group("squads"):
		var other := node as Squad
		if other == null or other.team == team or other.soldier_count <= 0:
			continue
		if not _can_reach(other):
			continue # across the water: they can glare, not fight
		# Edge-to-edge distance between the two formations
		var gap := my_center.distance_to(other.center()) - radius() - other.radius()
		if gap < best_gap:
			best_gap = gap
			best = other
	return best


## Same bank, or one of us is on a crossing.
func _can_reach(other: Squad) -> bool:
	var a := center()
	var b := other.center()
	return Terrain.bank_side(a) == Terrain.bank_side(b) or Terrain.on_crossing(a) or Terrain.on_crossing(b)


## Middle of the formation (the node's origin is the middle of the front rank).
func center() -> Vector2:
	var rows := ceili(float(soldier_count) / COLUMNS)
	return global_position - Vector2.RIGHT.rotated(rotation) * (maxi(rows, 1) - 1) * SPACING * 0.5


## Rough size of the formation, used for melee contact and for keeping
## squads from overlapping.
func radius() -> float:
	var rows := ceili(float(soldier_count) / COLUMNS)
	var width := mini(soldier_count, COLUMNS)
	var half_w := (width - 1) * SPACING * 0.5 + SOLDIER_RADIUS + 2.0
	var half_d := (maxi(rows, 1) - 1) * SPACING * 0.5 + SOLDIER_RADIUS + 2.0
	return maxf(half_w, half_d)


func _fight(delta: float) -> void:
	var mult := _flank_mult(engaged_with)
	# Overloaded squads get fewer soldiers into the fight effectively
	var dmg := soldier_count * DAMAGE_PER_SOLDIER * delta * mult * (0.5 + 0.5 * efficiency()) * _valor_damage_mult()
	if is_commander:
		dmg *= COMMANDER_GUARD_DAMAGE
	# Ground: high ground, cover in the forest, footing in the stream
	dmg *= Terrain.damage_mult(center(), engaged_with.center())
	# Outnumbering the target lets our men wrap around it
	var wrap := _envelopment(engaged_with)
	dmg *= 1.0 + ENVELOP_DAMAGE * wrap
	engaged_with.take_casualties(dmg)
	engaged_with.apply_pressure(mult, delta)
	if not engaged_with.routing:
		engaged_with.morale -= ENVELOP_MORALE * wrap * delta


## How exposed the defender is to us: front 1.0, side 1.5, rear 2.5.
## A fleeing squad is always hit as if from behind.
func _flank_mult(defender: Squad) -> float:
	if defender.routing:
		return REAR_MULT
	var from_defender := center() - defender.center()
	var off := absf(angle_difference(defender.rotation, from_defender.angle()))
	if off < deg_to_rad(60):
		return 1.0
	elif off < deg_to_rad(120):
		return SIDE_MULT
	return REAR_MULT


func take_casualties(amount: float) -> void:
	if soldier_count <= 0:
		return
	# Overloaded squads are sloppy and take more losses: x1.0 up to x1.7
	_incoming += amount * (2.0 - efficiency()) * (COMMANDER_GUARD_TOUGHNESS if is_commander else 1.0)
	while _incoming >= 1.0 and soldier_count > 0:
		_incoming -= 1.0
		# The man at the point of contact falls; everyone else keeps his place
		var idx := _front_man()
		var who: Soldier = null
		if idx >= 0 and idx < members.size():
			who = members[idx]
			members.remove_at(idx)
		# Dead or wounded? A sloppy (overloaded) or fleeing squad leaves more dead
		var chance := WOUNDED_CHANCE_FLEEING if routing else WOUNDED_CHANCE * (0.5 + 0.5 * efficiency())
		if has_trait("Caring"):
			chance = minf(0.85, chance + 0.2) # his men get carried off, not left
		soldier_fell.emit(_men[idx] if idx >= 0 else to_global(_slot(soldier_count - 1)), color, who, randf() < chance)
		if idx >= 0:
			_men.remove_at(idx)
			_ring.remove_at(idx)
		soldier_count -= 1
		# Each loss hurts relative to squad size (tuned for 10), and more when overloaded
		morale -= MORALE_PER_CASUALTY * 10.0 / maxf(_start_count, 1.0) * (2.0 - efficiency()) * _charisma_loss_mult() * _familiarity_loss_mult()
		_flash = FLASH_TIME
	if soldier_count <= 0:
		died.emit(self)
		queue_free()
		return
	_check_rout()


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
	var c := color
	if routing:
		c = Color(color.darkened(0.35).lerp(Color(0.5, 0.5, 0.5), 0.4), 0.85)
	elif _flash > 0.0:
		c = color.lerp(Color.WHITE, 0.55)
	var outline := Color(c.darkened(0.6), c.a)

	# Selection: a soft footprint with corner brackets, on the ground
	if selected:
		var b := _local_bounds(rows).grow(3.0)
		draw_rect(b, Color(1.0, 0.9, 0.35, 0.12), true)
		_draw_brackets(b, Color(1.0, 0.9, 0.35, 0.95))

	_sync_men(false)
	var foe: Squad = null
	if not routing and engaged_with != null and is_instance_valid(engaged_with):
		foe = engaged_with

	# Shadows on the ground (the camera turns these circles into ellipses)
	for i in soldier_count:
		draw_circle(to_local(_men[i]) + Vector2(1.5, 1.0).rotated(-rotation), SOLDIER_RADIUS + 0.8, Color(0, 0, 0, 0.32))

	# Upright figures, far ones first so near ones overlap them
	var order := range(soldier_count)
	order.sort_custom(func(a: int, b: int) -> bool: return _men[a].y < _men[b].y)
	var squad_face := Vector2.RIGHT.rotated(rotation)
	for i in order:
		var face_world := squad_face
		if foe != null:
			face_world = (foe.center() - _men[i]).normalized()
		var face_screen := View.to_screen(face_world).normalized()
		draw_set_transform_matrix(_upright_at(to_local(_men[i])))
		_draw_man(c, outline, face_screen, not routing)
	draw_set_transform(Vector2.ZERO, 0.0)

	# Clash: sparks between our men and theirs while in melee
	if foe != null:
		var t := Time.get_ticks_msec() / 90
		for k in mini(4, soldier_count):
			var i := (t + k * 5) % soldier_count
			var toward := (foe.center() - _men[i]).normalized()
			var spark := View.to_screen(_men[i] - global_position) + View.to_screen(toward) * 6.0 + Vector2(0, -7)
			draw_set_transform_matrix(_upright_at(Vector2.ZERO))
			draw_line(spark, spark + Vector2(3, -3).rotated(float((t + k) % 6)), Color(1.0, 0.92, 0.6, 0.95), 1.4)
		draw_set_transform(Vector2.ZERO, 0.0)

	# Middle of where the men actually stand (they spread out in melee), world axes
	var mid := center() - global_position
	if soldier_count > 0:
		var sum := Vector2.ZERO
		for m in _men:
			sum += m
		mid = sum / _men.size() - global_position
	# Banner just behind where the men actually are (follows them into melee)
	var back := mid - Vector2.RIGHT.rotated(rotation) * ((rows - 1) * SPACING * 0.5 + 9.0)
	if foe != null:
		back = mid

	# Commander's aura lies on the ground
	if is_commander and not routing:
		draw_set_transform(Vector2.ZERO, -rotation)
		_draw_aura()

	# Upright things above the squad: banner and morale bar (screen units)
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
	draw_set_transform(Vector2.ZERO, 0.0)


## Drawing transform for upright things standing at local point `p`:
## first turn back to the world's axes (undo the squad's rotation), then undo
## the camera's vertical squash. Built as a matrix because
## draw_set_transform() applies scale and rotation in the other order, which
## shears everything on squads that aren't facing straight left or right.
func _upright_at(p: Vector2) -> Transform2D:
	return Transform2D(-rotation, p) * Transform2D(0.0, View.upright_scale(), 0.0, Vector2.ZERO)


## One soldier standing at (0, 0), drawn upright in screen units.
## face = the direction he faces on screen. Shield and spear go in front of
## the body, or behind it when he faces away from the camera.
func _draw_man(c: Color, outline: Color, face: Vector2, armed: bool) -> void:
	var away := face.y < -0.25
	var wood := Color(0.55, 0.42, 0.26, c.a)
	var metal := Color(0.85, 0.85, 0.8, c.a)
	var shield_at := Vector2(0, -6.0) + face * 3.4
	var spear_a := Vector2(0, -5.0) - face * 3.0
	var spear_b := Vector2(0, -12.0) + face * 9.0

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
	for i in _men.size():
		var d := minf(_men[i].distance_to(point), (_men[i] + body_up).distance_to(point))
		if d < best_d:
			best_d = d
			best = i
	return best


func man_position(i: int) -> Vector2:
	return _men[i]


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
	for m in _men:
		if rect.has_point(m) or rect.has_point(m + body_up):
			return true
	return false


func contains_point(global_point: Vector2) -> bool:
	var rows := ceili(float(soldier_count) / COLUMNS)
	# Figures stand upright, so a click on a body is "above" its feet: test
	# the click point and the ground point under it.
	for q in [global_point, global_point + Vector2(0, 12.0 / View.TILT)]:
		if _local_bounds(rows).has_point(to_local(q)):
			return true
		for m in _men: # soldiers spread out in melee can be clicked too
			if m.distance_to(q) < SOLDIER_RADIUS + 5.0:
				return true
	return false
