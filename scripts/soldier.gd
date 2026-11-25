class_name Soldier
extends RefCounted
## One named soldier of our army. Lives across battles.

var name: String
var group_id := 0
## 0..100: how used he is to his leader. Grows each battle he survives.
var familiarity := 0.0
## Battles he has come back from.
var battles := 0
## Battles left to sit out while his wounds heal (0 = fit to fight).
var wounded_for := 0


func _init(p_name: String, p_group: int) -> void:
	name = p_name
	group_id = p_group


func is_fit() -> bool:
	return wounded_for <= 0
