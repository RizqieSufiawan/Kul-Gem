extends Node
## Autoload "Campaign": the army that lives between battles. Every soldier is a
## Soldier with a name and a history; soldiers belong to groups (up to 10),
## and groups belong to a leader. A battle takes the fit soldiers of each
## leader's groups, and hands back who died, who was wounded and who made it.

const FAMILIARITY_PER_BATTLE := 12.0
const WOUND_BATTLES_MIN := 1
const WOUND_BATTLES_MAX := 2
const LOST_WOUNDED_ON_DEFEAT := 0.5 # share of wounded left behind when we lose the field

# --- Economy ---
const START_GOLD := 150
const RECRUIT_COST := 10
const BURN_GOLD := 30 # per place the enemy burned: rebuilding, lost harvest
const BURN_VOLUNTEERS := 4 # ...and families who leave
const TREAT_COST := 15 # a healer: one wounded soldier fit for the next battle
const NEW_GROUP_SIZE := 10
const RESERVE_FAMILIARITY_KEPT := 0.5 # reserves joining a new group start half-strange
const UPKEEP_PER_SOLDIER := 1 # gold per soldier (fit or wounded) per battle
const REWARD_VICTORY := 120
const REWARD_DEFEAT := 40
const VILLAGE_LEVY := 40 # what the village scrapes together each battle
const START_RECRUIT_POOL := 30 # villagers willing to take up a spear
const POOL_REGROWTH := 6 # new volunteers per battle...
const POOL_REGROWTH_AFTER_DEFEAT := 3 # ...fewer when the village has lost heart

var leaders: Array[Leader] = []
## Groups: { id, leader_id, size (target strength), members: Array[Soldier] }
var groups: Array[Dictionary] = []
var battle_number := 1
var gold := START_GOLD
var recruit_pool := START_RECRUIT_POOL
## Draw battles in 3D (F3 in battle switches). Kept for the whole session.
var render_3d := true
## Spare soldiers in camp, in no group: they cost upkeep and fill gaps for free
var reserves: Array[Soldier] = []
## Result of the last battle, for the roll call: see apply_result()
var last_report := {}

var _used_names := {}
var _next_group_id := 1


func _ready() -> void:
	new_campaign()


func new_campaign() -> void:
	leaders.clear()
	groups.clear()
	_used_names.clear()
	_next_group_id = 1
	battle_number = 1
	gold = START_GOLD
	recruit_pool = START_RECRUIT_POOL
	reserves.clear()
	last_report = {}
	# [name, Command, soldiers, is Commander, Charisma, Tactics, Valor, traits].
	# Mira starts with more men than she can lead well. The Commander leads a
	# bodyguard of 10.
	# ...and style (temper, discipline, pace), each -2..+2
	var start := [
		["Lysa Varn", 20, 10, true, 80, 75, 45, ["Inspiring", "Steady"], Vector3i(0, 1, 0)],
		["Aldric Thorne", 15, 15, false, 55, 50, 60, ["Disciplinarian", "Steady"], Vector3i(-1, 2, -1)],
		["Mira Holt", 15, 25, false, 45, 35, 80, ["Hothead", "Disciplinarian"], Vector3i(2, 1, 1)],
		["Tobin Reed", 10, 10, false, 50, 70, 50, ["Ambusher", "Small-unit specialist"], Vector3i(1, -1, 2)],
		["Wren Ashby", 10, 10, false, 75, 55, 40, ["Caring", "Inspiring"], Vector3i(-1, -1, 0)],
	]
	for i in start.size():
		var l := Leader.new(i, start[i][0], start[i][1])
		l.is_commander = start[i][3]
		l.charisma = start[i][4]
		l.tactics = start[i][5]
		l.valor = start[i][6]
		l.traits.assign(start[i][7])
		l.style = start[i][8]
		leaders.append(l)
		var left: int = start[i][2]
		while left > 0:
			var size := mini(10, left)
			_add_group(l.id, size, true)
			left -= size


func _add_group(leader_id: int, size: int, veterans: bool) -> Dictionary:
	var g := { "id": _next_group_id, "leader_id": leader_id, "size": size, "members": [] }
	_next_group_id += 1
	for k in size:
		var s := Soldier.new(Names.unique(_used_names), g.id)
		if veterans:
			# The village militia has drilled together a little already
			s.familiarity = randf_range(20.0, 55.0)
			s.battles = randi_range(0, 3)
		g.members.append(s)
	groups.append(g)
	return g


func commander() -> Leader:
	for l in leaders:
		if l.is_commander:
			return l
	return null


func leader_by_id(id: int) -> Leader:
	for l in leaders:
		if l.id == id:
			return l
	return null


func group_by_id(id: int) -> Dictionary:
	for g in groups:
		if g.id == id:
			return g
	return {}


func leader_of(s: Soldier) -> Leader:
	var g := group_by_id(s.group_id)
	return leader_by_id(g.leader_id) if not g.is_empty() else null


func _group_familiarity(group_id: int) -> float:
	var g := group_by_id(group_id)
	if g.is_empty() or g.members.is_empty():
		return 0.0
	var sum := 0.0
	for m in g.members:
		sum += m.familiarity
	return sum / g.members.size()


## Fit soldiers of all of a leader's groups (the wounded sit this one out).
func fit_roster(l: Leader) -> Array[Soldier]:
	var out: Array[Soldier] = []
	for g in groups:
		if g.leader_id == l.id:
			for s in g.members:
				if s.is_fit():
					out.append(s)
	return out


func wounded_count(l: Leader) -> int:
	var n := 0
	for g in groups:
		if g.leader_id == l.id:
			for s in g.members:
				if not s.is_fit():
					n += 1
	return n


## After a battle. `dead` and `wounded` fell during the fight; `survivors`
## walked off the field (including those who fled). Returns the roll call.
func apply_result(won: bool, dead: Array[Soldier], wounded: Array[Soldier], survivors: Array[Soldier],
		burned: Array[String] = []) -> Dictionary:
	# Those who sat this battle out with old wounds are one battle closer to fit
	for g in groups:
		for s in g.members:
			if s.wounded_for > 0:
				s.wounded_for -= 1
	var fallen: Array[Soldier] = dead.duplicate()
	var hurt: Array[Soldier] = []
	var left_behind: Array[Soldier] = []
	for s in wounded:
		if not won and randf() < LOST_WOUNDED_ON_DEFEAT:
			left_behind.append(s) # we lost the field: no one could carry them back
		else:
			hurt.append(s)
	for s in fallen + left_behind:
		var g := group_by_id(s.group_id)
		if not g.is_empty():
			g.members.erase(s)
	for s in hurt:
		s.wounded_for = randi_range(WOUND_BATTLES_MIN, WOUND_BATTLES_MAX)
		s.battles += 1
	var to_reserve := _resolve_overflow()
	for s in survivors:
		s.battles += 1
		# A recruit next to veterans learns their leader's ways faster
		var gain := FAMILIARITY_PER_BATTLE
		if s.familiarity < _group_familiarity(s.group_id) - 20.0:
			gain *= 1.5
		s.familiarity = minf(100.0, s.familiarity + gain)
	# The money: reward, the village's levy, and everyone's pay
	var ledger: Array = []
	var reward := REWARD_VICTORY if won else REWARD_DEFEAT
	ledger.append(["Battle reward (%s)" % ("victory" if won else "defeat"), reward])
	ledger.append(["Village levy", VILLAGE_LEVY])
	var mouths := total_soldiers()
	var upkeep := mouths * UPKEEP_PER_SOLDIER
	ledger.append(["Upkeep (%d soldiers)" % mouths, -upkeep])
	gold += reward + VILLAGE_LEVY - upkeep
	for place in burned:
		ledger.append(["%s burned" % place, -BURN_GOLD])
		gold -= BURN_GOLD
	# Unpaid men walk off: the least attached first
	var deserters: Array[Soldier] = []
	if gold < 0:
		var unpaid := -gold
		gold = 0
		deserters = _desert(ceili(unpaid / 2.0))
		ledger.append(["Couldn't pay %d gold: %d deserted" % [unpaid, deserters.size()], 0])
	# New volunteers from the village
	var regrowth := POOL_REGROWTH if won else POOL_REGROWTH_AFTER_DEFEAT
	recruit_pool += regrowth
	recruit_pool = maxi(0, recruit_pool - burned.size() * BURN_VOLUNTEERS)

	last_report = {
		"won": won,
		"fallen": fallen,
		"left_behind": left_behind,
		"wounded": hurt,
		"survivors": survivors.size(),
		"ledger": ledger,
		"deserters": deserters,
		"volunteers": regrowth,
		"to_reserve": to_reserve,
		"burned": burned,
	}
	return last_report


## The least attached fit soldiers leave (most recent recruits first).
func _desert(count: int) -> Array[Soldier]:
	var all: Array[Soldier] = []
	for g in groups:
		for m in g.members:
			if m.is_fit():
				all.append(m)
	all.sort_custom(func(a: Soldier, b: Soldier) -> bool: return a.familiarity < b.familiarity)
	var gone: Array[Soldier] = all.slice(0, mini(count, all.size()))
	for m in gone:
		var g := group_by_id(m.group_id)
		if not g.is_empty():
			g.members.erase(m)
	return gone


func total_soldiers() -> int:
	var n := reserves.size()
	for g in groups:
		n += g.members.size()
	return n


## Once wounded men are fit again, a group can have more fit men than places
## (the stand-ins who filled in for them). The least experienced extras go
## to the reserves. Returns how many moved.
func _resolve_overflow() -> int:
	var moved := 0
	for g in groups:
		var fit: Array[Soldier] = []
		for m in g.members:
			if m.is_fit():
				fit.append(m)
		var extra := fit.size() - int(g.size)
		if extra <= 0:
			continue
		fit.sort_custom(func(a: Soldier, b: Soldier) -> bool: return a.familiarity < b.familiarity)
		for k in extra:
			g.members.erase(fit[k])
			fit[k].group_id = -1
			reserves.append(fit[k])
			moved += 1
	return moved


# --- Reassigning -------------------------------------------------------------

## Hand a whole group to another leader. The men keep part of their
## familiarity, more if the new leader's style is like the old one's.
## Returns the share kept.
func move_group(g: Dictionary, to: Leader) -> float:
	var from := leader_by_id(g.leader_id)
	if from == null or to == null or from == to:
		return 1.0
	var kept := from.familiarity_kept(to)
	for m in g.members:
		m.familiarity *= kept
	g.leader_id = to.id
	return kept


# --- Recruiting --------------------------------------------------------------

## Empty places in a group (its target strength minus everyone in it,
## wounded included: the wounded keep their place).
func gaps(g: Dictionary) -> int:
	return maxi(0, g.size - g.members.size())


func wounded_in(g: Dictionary) -> int:
	var n := 0
	for m in g.members:
		if not m.is_fit():
			n += 1
	return n


func fit_in(g: Dictionary) -> int:
	return g.members.size() - wounded_in(g)


## Places of wounded men nobody is standing in for yet.
func stand_in_need(g: Dictionary) -> int:
	return maxi(0, int(g.size) - fit_in(g) - gaps(g))


## Hire recruits to stand in for the wounded until they're back.
func hire_stand_ins(g: Dictionary) -> int:
	var n := affordable(stand_in_need(g))
	for k in n:
		g.members.append(Soldier.new(Names.unique(_used_names), g.id))
	gold -= n * RECRUIT_COST
	recruit_pool -= n
	return n


## Pay a healer: wounded men fit for the next battle. Returns how many.
func treat(g: Dictionary) -> int:
	var n := 0
	for m in g.members:
		if not m.is_fit() and gold >= TREAT_COST:
			m.wounded_for = 0
			gold -= TREAT_COST
			n += 1
	_resolve_overflow()
	return n


## Reserves fill a group's empty places, for free.
func reserves_into(g: Dictionary, wanted: int) -> int:
	var n := mini(wanted, reserves.size())
	reserves.sort_custom(func(a: Soldier, b: Soldier) -> bool: return a.familiarity > b.familiarity)
	for k in n:
		var m: Soldier = reserves.pop_front()
		m.group_id = g.id
		m.familiarity *= RESERVE_FAMILIARITY_KEPT
		g.members.append(m)
	return n


## A new, empty group for a leader, filled with as many recruits as we can pay.
func raise_group(l: Leader) -> int:
	var g := { "id": _next_group_id, "leader_id": l.id, "size": NEW_GROUP_SIZE, "members": [] }
	_next_group_id += 1
	groups.append(g)
	var n := reserves_into(g, NEW_GROUP_SIZE)
	n += recruit_into(g, gaps(g))
	if g.members.is_empty():
		groups.erase(g) # couldn't put anyone in it
	return n


## How many of `wanted` recruits we can actually get right now.
func affordable(wanted: int) -> int:
	return mini(wanted, mini(recruit_pool, gold / RECRUIT_COST))


## Fill up to `wanted` gaps in a group with fresh recruits. Returns how many joined.
func recruit_into(g: Dictionary, wanted: int) -> int:
	var n := affordable(mini(wanted, gaps(g)))
	for k in n:
		g.members.append(Soldier.new(Names.unique(_used_names), g.id))
	gold -= n * RECRUIT_COST
	recruit_pool -= n
	return n


## Fill every gap we can, Commander's guard first, then group by group.
func recruit_all() -> int:
	var total := 0
	var ordered := groups.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return leader_by_id(a.leader_id).is_commander and not leader_by_id(b.leader_id).is_commander)
	for g in ordered:
		total += reserves_into(g, gaps(g)) # free soldiers first
		total += recruit_into(g, gaps(g))
	return total


func total_gaps() -> int:
	var n := 0
	for g in groups:
		n += gaps(g)
	return n


## Leaving camp for the next battle.
func next_battle() -> void:
	battle_number += 1
