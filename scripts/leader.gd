class_name Leader
extends RefCounted
## A squad leader (or the Main Commander). Lives across battles.

var id := 0
var name: String
var is_commander := false
## How many soldiers he leads at full effectiveness (the soft cap).
var command := 10
## 0..100 stats (used from Phase 2.2 on)
var charisma := 50
var tactics := 50
var valor := 50
var traits: Array[String] = []
## Leadership style, each from -2 to +2: temper (cautious..aggressive),
## discipline (loose..strict), pace (steady..mobile). Men used to one leader
## settle in faster under a leader of similar style.
var style := Vector3i.ZERO


## What each trait does, for tooltips.
const TRAIT_INFO := {
	"Disciplinarian": "overload hurts less",
	"Small-unit specialist": "+20% damage at 15 or fewer; overload hurts more",
	"Hothead": "+25% damage; orders arrive 0.6 s later",
	"Inspiring": "nearby squads recover morale",
	"Caring": "more of his fallen are wounded, not killed",
	"Steady": "breaks only at morale 5 (not 15)",
	"Ambusher": "planned ambushes shock twice as hard",
}


## 0..1: how alike two leaders' styles are.
func similarity(other: Leader) -> float:
	var d := absi(style.x - other.style.x) + absi(style.y - other.style.y) + absi(style.z - other.style.z)
	return 1.0 - d / 12.0


## Share of their familiarity that men moving from this leader to `other` keep.
func familiarity_kept(other: Leader) -> float:
	return maxf(0.25, similarity(other))


func _init(p_id: int, p_name: String, p_command: int) -> void:
	id = p_id
	name = p_name
	command = p_command
