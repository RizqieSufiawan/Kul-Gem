extends Control
## The camp between battles: what the last battle cost, the money, and every
## leader's groups. Spend gold and volunteers to fill the gaps, then march on.

const BATTLE_SCENE := "res://scenes/battle.tscn"
const INK := Color(0.93, 0.90, 0.80)
const QUIET := Color(0.66, 0.64, 0.56)
const GOLD := Color(0.95, 0.80, 0.35)
const GOOD := Color(0.65, 0.92, 0.55)
const BAD := Color(1.0, 0.55, 0.45)
const WARN := Color(1.0, 0.75, 0.4)
const BLUE := Color(0.6, 0.78, 1.0)
const BG := Color(0.10, 0.11, 0.09)
const COLUMN_W := 236.0
const COLUMN_H := 500.0

var _title: Label
var _result: Label
var _pills: HBoxContainer
var _ledger_money: HBoxContainer
var _ledger_people: HBoxContainer
var _columns: HBoxContainer
var _fill_all: Button


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = BG
	bg.size = Vector2(1280, 720)
	add_child(bg)

	# Header: which battle and the result on the left, the purse on the right
	var head := HBoxContainer.new()
	head.position = Vector2(24, 14)
	head.size = Vector2(1232, 40)
	head.add_theme_constant_override("separation", 12)
	add_child(head)
	_title = _label("", 22, INK)
	_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_title)
	_result = _label("", 13, Color(0.08, 0.08, 0.06))
	_result.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_result)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(gap)
	_pills = HBoxContainer.new()
	_pills.add_theme_constant_override("separation", 8)
	head.add_child(_pills)

	# What the battle cost and earned: money on one row, people on the next
	var ledger_panel := PanelContainer.new()
	ledger_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.07, 0.08, 0.07, 0.6)))
	ledger_panel.position = Vector2(20, 60)
	ledger_panel.size = Vector2(1240, 0)
	ledger_panel.custom_minimum_size = Vector2(1240, 0)
	add_child(ledger_panel)
	var ledger := VBoxContainer.new()
	ledger.add_theme_constant_override("separation", 6)
	ledger_panel.add_child(ledger)
	_ledger_money = HBoxContainer.new()
	_ledger_money.add_theme_constant_override("separation", 6)
	ledger.add_child(_ledger_money)
	_ledger_people = HBoxContainer.new()
	_ledger_people.add_theme_constant_override("separation", 6)
	ledger.add_child(_ledger_people)

	# One column per leader
	_columns = HBoxContainer.new()
	_columns.add_theme_constant_override("separation", 12)
	_columns.position = Vector2(20, 142)
	add_child(_columns)

	# Footer: quiet actions left, the way forward right
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	footer.position = Vector2(20, 660)
	footer.size = Vector2(1240, 40)
	add_child(footer)
	var newc := _button("New campaign", _on_new_campaign, "quiet", 15)
	newc.tooltip_text = "Start over from battle 1: new soldiers, 150 gold."
	footer.add_child(newc)
	var hint := _label("Hover anything to see what it does.   F1: guide", 12, QUIET)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_child(hint)
	_fill_all = _button("", _on_fill_all, "normal", 15)
	_fill_all.tooltip_text = "Reserves first (free), then recruits"
	footer.add_child(_fill_all)
	var next := _button("Next battle   >", _on_next_battle, "main", 15)
	next.tooltip_text = "March out. Each leader takes his fit soldiers; the wounded stay in camp."
	Guide.tip_at(Vector2(28, 420)) # over the empty bottom of the Commander's column
	Guide.tip("camp")
	next.custom_minimum_size = Vector2(170, 40)
	footer.add_child(next)

	Sound.music("music_camp")
	Sound.stop_loops()
	_refresh()


# --- Building blocks ---------------------------------------------------------

func _panel_style(bg_color: Color, border := Color(0.85, 0.75, 0.45, 0.35), radius := 8) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg_color
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


func _flat(c: Color, radius := 5, mx := 10, my := 3) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = mx
	sb.content_margin_right = mx
	sb.content_margin_top = my
	sb.content_margin_bottom = my
	return sb


func _label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


## kind: "main" (gold, the way forward), "normal", "quiet"
func _button(text: String, on_press: Callable, kind := "normal", font_size := 12) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	var c := { "main": Color(0.85, 0.72, 0.4), "normal": Color(1, 1, 1, 0.09), "quiet": Color(1, 1, 1, 0.04) }[kind] as Color
	var fc := Color(0.1, 0.08, 0.05) if kind == "main" else (INK if kind == "normal" else QUIET)
	var normal := _flat(c, 5, 12, 4)
	var hover := _flat(c.lightened(0.15) if kind == "main" else Color(1, 1, 1, c.a + 0.07), 5, 12, 4)
	var off := _flat(Color(1, 1, 1, 0.03), 5, 12, 4)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", normal)
	b.add_theme_stylebox_override("disabled", off)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(state, fc)
	b.add_theme_color_override("font_disabled_color", Color(QUIET, 0.5))
	b.custom_minimum_size = Vector2(0, 40 if font_size >= 15 else 26)
	b.pressed.connect(func() -> void:
		# Spending money clinks; everything else clicks
		Sound.play("coin" if "gold" in b.text or "Raise" in b.text else "ui_click")
		on_press.call())
	return b


## A small rounded tag: a trait, a resource, a ledger line.
func _chip(text: String, fg: Color, bg := Color(1, 1, 1, 0.06), font_size := 12) -> Label:
	var l := _label(text, font_size, fg)
	l.add_theme_stylebox_override("normal", _flat(bg, 4, 8, 2))
	return l


## Gold / Volunteers / Reserves in the header.
func _pill(value: int, what: String, c: Color, tip := "") -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _flat(Color(1, 1, 1, 0.06), 6, 12, 4))
	p.add_child(box)
	p.tooltip_text = tip
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	var v := _label(str(value), 18, c)
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_child(v)
	var w := _label(what, 12, QUIET)
	w.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_child(w)
	return p


func _style_text(st: Vector3i) -> String:
	var temper: String = ["Very cautious", "Cautious", "Even-tempered", "Aggressive", "Very aggressive"][st.x + 2]
	var disc: String = ["very loose", "loose", "fair", "strict", "very strict"][st.y + 2]
	var pace: String = ["very steady", "steady", "measured", "mobile", "very mobile"][st.z + 2]
	return "%s, %s, %s" % [temper, disc, pace]


func _stars(fam: float) -> String:
	var n := int(fam / 25.0)
	return "★".repeat(mini(n, 3)) + "☆".repeat(3 - mini(n, 3))


# --- Contents ----------------------------------------------------------------

func _refresh() -> void:
	var r: Dictionary = Campaign.last_report
	if r.is_empty():
		_title.text = "Camp  ·  before battle %d" % Campaign.battle_number
		_result.visible = false
	else:
		_title.text = "Camp  ·  after battle %d" % Campaign.battle_number
		_result.visible = true
		_result.text = "VICTORY" if r.won else "DEFEAT"
		_result.add_theme_stylebox_override("normal", _flat(GOOD if r.won else BAD, 4, 8, 1))

	for c in _pills.get_children():
		c.queue_free()
	_pills.add_child(_pill(Campaign.gold, "gold", GOLD,
		"Gold. Recruits cost %d, healing a wounded man %d.\nAfter each battle: +%d victory / +%d defeat, +%d from the village,\n-1 per soldier (pay and food), -%d per burned place. Can't pay: men desert." % [
		Campaign.RECRUIT_COST, Campaign.TREAT_COST, Campaign.REWARD_VICTORY, Campaign.REWARD_DEFEAT, Campaign.VILLAGE_LEVY, Campaign.BURN_GOLD]))
	_pills.add_child(_pill(Campaign.recruit_pool, "volunteers", BLUE,
		"Villagers willing to join. Each recruit uses one.\n+%d after a victory, +%d after a defeat, -%d for each burned place." % [
		Campaign.POOL_REGROWTH, Campaign.POOL_REGROWTH_AFTER_DEFEAT, Campaign.BURN_VOLUNTEERS]))
	_pills.add_child(_pill(Campaign.reserves.size(), "reserves", INK,
		"Spare soldiers in no group (e.g. stand-ins whose wounded men came back).\nThey fill empty places for free, but still cost upkeep."))

	_fill_ledger(r)

	for c in _columns.get_children():
		c.queue_free()
	var ordered: Array[Leader] = []
	var cmd := Campaign.commander()
	if cmd != null:
		ordered.append(cmd)
	for l in Campaign.leaders:
		if l != cmd:
			ordered.append(l)
	for l in ordered:
		_columns.add_child(_leader_column(l))

	var gaps := Campaign.total_gaps()
	var free := mini(gaps, Campaign.reserves.size())
	var paid := Campaign.affordable(gaps - free)
	if gaps == 0:
		_fill_all.text = "No gaps to fill"
	else:
		_fill_all.text = "Fill all gaps: %d of %d   (%d gold)" % [free + paid, gaps, paid * Campaign.RECRUIT_COST]
	_fill_all.disabled = free + paid == 0


func _fill_ledger(r: Dictionary) -> void:
	for c in _ledger_money.get_children() + _ledger_people.get_children():
		c.queue_free()
	if r.is_empty():
		_ledger_money.add_child(_label("A new campaign. Fill your ranks and march.", 13, INK))
		return
	var net := 0
	for entry in r.get("ledger", []):
		var amount: int = entry[1]
		net += amount
		if amount == 0:
			_ledger_money.add_child(_chip(entry[0], BAD, Color(BAD, 0.12)))
		else:
			var c := GOOD if amount > 0 else BAD
			_ledger_money.add_child(_chip("%s  %+d" % [entry[0], amount], c, Color(c, 0.1)))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ledger_money.add_child(gap)
	_ledger_money.add_child(_chip("Net  %+d gold" % net, GOOD if net >= 0 else BAD, Color(1, 1, 1, 0.08), 13))

	_ledger_people.add_child(_chip("Came back  %d" % r.survivors, BLUE))
	_ledger_people.add_child(_chip("Fallen  %d" % r.fallen.size(), BAD if r.fallen.size() > 0 else QUIET))
	_ledger_people.add_child(_chip("Wounded  %d" % r.wounded.size(), WARN if r.wounded.size() > 0 else QUIET))
	if not r.left_behind.is_empty():
		var lb := _chip("Left on the field  %d" % r.left_behind.size(), BAD)
		lb.tooltip_text = "We lost the field: half the wounded couldn't be carried back."
		lb.mouse_filter = Control.MOUSE_FILTER_STOP
		_ledger_people.add_child(lb)
	var deserters: Array = r.get("deserters", [])
	if not deserters.is_empty():
		_ledger_people.add_child(_chip("Deserted  %d" % deserters.size(), BAD))
	_ledger_people.add_child(_chip("New volunteers  +%d" % r.get("volunteers", 0), BLUE))
	var burned: Array = r.get("burned", [])
	if not burned.is_empty():
		_ledger_people.add_child(_chip("Families left burned places  -%d volunteers" % (burned.size() * Campaign.BURN_VOLUNTEERS), BAD))
	for w in r.get("wounded", []):
		Guide.tip("wounded")
		break
	if r.get("to_reserve", 0) > 0:
		_ledger_people.add_child(_chip("Stand-ins to the reserves  %d" % r.to_reserve, INK))


func _leader_column(l: Leader) -> Control:
	var panel := PanelContainer.new()
	var border := Color(GOLD, 0.55) if l.is_commander else Color(0.85, 0.75, 0.45, 0.25)
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.07, 0.08, 0.07, 0.85), border))
	panel.custom_minimum_size = Vector2(COLUMN_W, COLUMN_H)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	# Name, and the Commander tag
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	col.add_child(name_row)
	name_row.add_child(_label(l.name, 16, GOLD if l.is_commander else INK))
	if l.is_commander:
		var tag := _chip("COMMANDER", Color(0.1, 0.08, 0.05), GOLD, 10)
		tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		name_row.add_child(tag)

	# Stats in a row of four
	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 4)
	col.add_child(stats)
	var stat_tips := {
		"CMD": "Command: how many soldiers this leader leads well.\nMore than this = overloaded (fights and obeys worse).",
		"CHA": "Charisma: the squad loses less morale when men fall.",
		"TAC": "Tactics: orders are obeyed faster, and the squad\nnotices friends fighting from further away.",
		"VAL": "Valor: the men hit harder.",
	}
	for pair in [["CMD", l.command], ["CHA", l.charisma], ["TAC", l.tactics], ["VAL", l.valor]]:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", -3)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var v := _label(str(pair[1]), 15, INK)
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cell.add_child(v)
		var k := _label(pair[0], 10, QUIET)
		k.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cell.add_child(k)
		var p := PanelContainer.new()
		p.add_theme_stylebox_override("panel", _flat(Color(1, 1, 1, 0.04), 4, 4, 2))
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		p.add_child(cell)
		p.tooltip_text = stat_tips[pair[0]]
		p.mouse_filter = Control.MOUSE_FILTER_STOP
		stats.add_child(p)

	# Style and traits
	var style := _label(_style_text(l.style), 11, QUIET)
	style.tooltip_text = "Leadership style. Men moved between leaders with\na similar style keep more of their familiarity."
	style.mouse_filter = Control.MOUSE_FILTER_STOP
	col.add_child(style)
	var traits := HFlowContainer.new()
	traits.add_theme_constant_override("h_separation", 4)
	traits.add_theme_constant_override("v_separation", 4)
	col.add_child(traits)
	for t in l.traits:
		var chip := _chip(t, INK, Color(1, 1, 1, 0.07), 11)
		chip.tooltip_text = Leader.TRAIT_INFO.get(t, "")
		chip.mouse_filter = Control.MOUSE_FILTER_STOP
		traits.add_child(chip)

	# How many he'll lead next battle against his Command
	var fit := 0
	for g in Campaign.groups:
		if g.leader_id == l.id:
			fit += Campaign.fit_in(g)
	col.add_child(_command_bar(fit, l.command))

	# His groups
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	list.custom_minimum_size = Vector2(COLUMN_W - 30, 0)
	scroll.add_child(list)
	for g in Campaign.groups:
		if g.leader_id == l.id:
			list.add_child(_group_box(g))

	var can := Campaign.reserves.size() + Campaign.affordable(Campaign.NEW_GROUP_SIZE)
	var raise := _button("+  Raise a new group", func() -> void:
		Campaign.raise_group(l)
		_refresh(), "quiet")
	raise.disabled = can == 0
	raise.tooltip_text = "Up to %d men: reserves first (free), then recruits at %d gold each" % [Campaign.NEW_GROUP_SIZE, Campaign.RECRUIT_COST]
	col.add_child(raise)
	return panel


## "Leads 25 / 15" with a bar; past Command it turns orange (overloaded).
func _command_bar(fit: int, command: int) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.tooltip_text = "Fit soldiers this leader takes into the next battle / his Command.%s" % (
		"\nOVERLOADED: too many men. Move a group to a leader with room." if fit > command else "")
	v.mouse_filter = Control.MOUSE_FILTER_STOP
	var row := HBoxContainer.new()
	v.add_child(row)
	row.add_child(_label("Leads next battle", 11, QUIET))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)
	var over := fit > command
	row.add_child(_label("%d / %d%s" % [fit, command, "  overloaded" if over else ""], 11, WARN if over else INK))
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 5)
	bar.max_value = maxi(command, fit)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.value = fit
	bar.add_theme_stylebox_override("background", _flat(Color(1, 1, 1, 0.07), 2, 0, 0))
	bar.add_theme_stylebox_override("fill", _flat(WARN if over else GOOD.darkened(0.15), 2, 0, 0))
	v.add_child(bar)
	return v


func _group_box(g: Dictionary) -> Control:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _panel_style(Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.08), 6))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	box.add_child(v)

	var fit := 0
	var hurt := 0
	var fam_sum := 0.0
	var names: Array[String] = []
	for m in g.members:
		fam_sum += m.familiarity
		if m.is_fit():
			fit += 1
			names.append("%s  -  %d battles, familiarity %d" % [m.name, m.battles, roundi(m.familiarity)])
		else:
			hurt += 1
			names.append("%s  -  wounded, back in %d battle%s" % [m.name, m.wounded_for, "" if m.wounded_for == 1 else "s"])
	var fam := fam_sum / maxf(g.members.size(), 1.0)
	var gaps := Campaign.gaps(g)

	# Title row: name and stars, fit count on the right
	var top := HBoxContainer.new()
	v.add_child(top)
	top.add_child(_label("Group %d" % g.id, 13, INK))
	var stars := _label("  " + _stars(fam), 12, GOLD)
	stars.tooltip_text = "Familiarity %d" % roundi(fam)
	stars.mouse_filter = Control.MOUSE_FILTER_STOP
	top.add_child(stars)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(gap)
	top.add_child(_label("%d / %d" % [fit, g.size], 13, INK if fit >= g.size else WARN))

	# Status chips: only what needs attention
	if hurt > 0 or gaps > 0:
		var tags := HBoxContainer.new()
		tags.add_theme_constant_override("separation", 4)
		v.add_child(tags)
		if hurt > 0:
			var wc := _chip("%d wounded" % hurt, WARN, Color(WARN, 0.12), 11)
			wc.tooltip_text = "Wounded men sit out 1-2 battles but keep their place.\nTreat them to have them back now."
			wc.mouse_filter = Control.MOUSE_FILTER_STOP
			tags.add_child(wc)
		if gaps > 0:
			var ec := _chip("%d empty" % gaps, BAD, Color(BAD, 0.12), 11)
			ec.tooltip_text = "Empty places (the men died or deserted).\nFill them with reserves (free) or recruits."
			ec.mouse_filter = Control.MOUSE_FILTER_STOP
			tags.add_child(ec)

	if gaps > 0 and not Campaign.reserves.is_empty():
		var nr := mini(gaps, Campaign.reserves.size())
		var tr := _button("Take %d from reserves   (free)" % nr, func() -> void:
			Campaign.reserves_into(g, gaps)
			_refresh())
		tr.tooltip_text = "Spare soldiers join this group for free.\nThey start with half their familiarity (a new leader)."
		v.add_child(tr)
	elif gaps > 0:
		var n := Campaign.affordable(gaps)
		var b := _button("Recruit %d   (%d gold)" % [n, n * Campaign.RECRUIT_COST] if n > 0 else "Can't afford recruits", func() -> void:
			Campaign.recruit_into(g, gaps)
			_refresh())
		b.disabled = n == 0
		b.tooltip_text = "New villagers fill the empty places: %d gold each.\nThey start with no familiarity (no stars)." % Campaign.RECRUIT_COST
		v.add_child(b)
	if hurt > 0:
		var nt := mini(hurt, Campaign.gold / Campaign.TREAT_COST)
		var t := _button("Treat %d wounded   (%d gold)" % [nt, nt * Campaign.TREAT_COST] if nt > 0 else "Can't afford a healer", func() -> void:
			Campaign.treat(g)
			_refresh())
		t.tooltip_text = "Fit for the next battle instead of sitting out"
		t.disabled = nt == 0
		v.add_child(t)
		var need := Campaign.stand_in_need(g)
		if need > 0:
			var ns := Campaign.affordable(need)
			var si := _button("Hire %d stand-ins   (%d gold)" % [ns, ns * Campaign.RECRUIT_COST] if ns > 0 else "Can't afford stand-ins", func() -> void:
				Campaign.hire_stand_ins(g)
				_refresh())
			si.tooltip_text = "Recruits fight in the wounded men's places. When the wounded are back,\nthe least experienced extras go to the reserves."
			si.disabled = ns == 0
			v.add_child(si)

	# Hand the whole group to another leader
	var from := Campaign.leader_by_id(g.leader_id)
	var move := MenuButton.new()
	move.text = "Move to another leader  ▾"
	move.flat = true
	move.tooltip_text = "Give this whole group to another leader (e.g. to fix an overloaded squad).\nThe men lose some familiarity; less if the leaders' styles are alike."

	move.alignment = HORIZONTAL_ALIGNMENT_LEFT
	move.add_theme_font_size_override("font_size", 11)
	move.add_theme_color_override("font_color", QUIET)
	move.add_theme_color_override("font_hover_color", INK)
	var popup := move.get_popup()
	for l in Campaign.leaders:
		if l == from:
			continue
		popup.add_item("%s   (keeps %d%% familiarity)" % [l.name, roundi(from.familiarity_kept(l) * 100)], l.id)
	popup.id_pressed.connect(func(id: int) -> void:
		Sound.play("ui_click")
		Campaign.move_group(g, Campaign.leader_by_id(id))
		_refresh())
	v.add_child(move)
	box.tooltip_text = ("Group %d: %d fit of %d places\n\n" % [g.id, fit, g.size]) + ("\n".join(names) if not names.is_empty() else "Empty")
	return box


# --- Actions -----------------------------------------------------------------

func _on_fill_all() -> void:
	Campaign.recruit_all()
	_refresh()


func _on_next_battle() -> void:
	Campaign.next_battle()
	get_tree().change_scene_to_file(BATTLE_SCENE)


func _on_new_campaign() -> void:
	Campaign.new_campaign()
	_refresh()
