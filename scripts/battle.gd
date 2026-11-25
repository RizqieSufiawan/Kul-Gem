extends Node2D

enum Phase { PLANNING, BATTLE, ENDED }
enum Action { ATTACK, RETREAT }

const DRAG_THRESHOLD := 6.0 # pixels before a click becomes a box drag
const LINE_SPACING := 70.0 # gap between squads when moving as a group
const RETREAT_DISTANCE := 250.0 # how far back a planned retreat goes
const BOX_COLOR := Color(1, 0.9, 0.2)
const PLAYER_COLOR := Color(0.3, 0.6, 1.0)
const ENEMY_COLOR := Color(0.9, 0.3, 0.3)
const ZONE_COLOR := Color(0.75, 0.55, 1.0)
const ATTACK_COLOR := Color(1.0, 0.4, 0.35)
const RETREAT_COLOR := Color(1.0, 0.85, 0.3)
const FIRED_COLOR := Color(0.6, 0.6, 0.6)
const COMMANDER_COLOR := Color(0.95, 0.8, 0.3)
const QUIET_GOLD := Color(0.72, 0.66, 0.52)

# --- Messenger delay for direct orders ---
const MESSENGER_SPEED := 200.0 # px per second from commander to squad
const MIN_ORDER_DELAY := 0.5
const MAX_ORDER_DELAY := 4.0 # also used for every order if the commander is gone

# --- Enemy AI ---
const AI_THINK_INTERVAL := 0.5 # seconds between enemy decisions
const AI_RETARGET_MARGIN := 80.0 # only switch to a target this much closer
const AI_STANDOFF := 260.0 # the enemy line forms up this far from our main body
const AI_LINE_SPACING := 100.0 # gap between enemy squads in their line
const AI_RESERVE_BACK := 150.0 # reserve waits this far behind the line
const AI_MAX_ADVANCE_TIME := 14.0 # charge after this long even if the line isn't set
const AI_CONTACT := 160.0 # charge early if we come this close
const AI_FLANK_WIDTH := 90.0 # flankers swing this far past the edge of our formation
const AI_FLANK_DEPTH := 70.0 # ...and this far behind our front
const AI_RESERVE_COMMIT_MORALE := 55.0 # reserve joins when an engaged ally drops below this
const AI_RESERVE_TIMEOUT := 20.0 # reserve joins anyway after this long
const AI_HELP_RADIUS := 320.0 # free enemy squads hit the side of our squads already fighting this close
const AI_MAX_GANG := 2 # at most this many extra squads pile onto one of ours
const AI_WEAK_WEIGHT := 1.5 # px of distance a point of missing morale is worth when picking a target
const AI_COMMANDER_BONUS := 150.0 # the Commander is a juicy target (killing it wins)
const AI_GUARD_RADIUS := 200.0 # an objective with none of us (that they can see) this close is fair game
const AI_MAX_RAIDERS := 1

# Objectives: the village's outlying places. Enemies standing in one with
# nobody of ours there burn it down. Lost places cost gold and volunteers;
# lose them all and the battle is lost.
const OBJ_RADIUS := 60.0
const OBJ_BURN_TIME := 30.0 # seconds of an uncontested enemy squad inside
const OBJ_DEFEND_RADIUS := 80.0 # one of ours this close stops the burning
const OBJ_COLOR := Color(0.95, 0.8, 0.45)
## One place is picked from each list, so they're always far apart.
const OBJ_SITES := [
	[["North farms", Vector2(380, 175)], ["Shrine", Vector2(640, 165)]],
	[["Mill", Vector2(600, 950)], ["South farms", Vector2(460, 935)]], # kept clear of the squad bar
]
const POPUP_TIME := 2.0
const SCOUT_POINTS := 2 # enemy squads you can scout per battle

# --- Our squads' initiative ---
const INITIATIVE_RADIUS := 220.0 # idle squads help allies fighting this close
const FLANK_ARRIVE := 22.0 # close enough to the flank point: attack

# --- Deployment and formation ---
## Where our squads may be placed during planning
const DEPLOY_ZONE := Rect2(40, 90, 420, 1030)
const CAM_MIN_ZOOM := 1.0
const CAM_MAX_ZOOM := 3.0
const CAM_PAN_SPEED := 700.0 # screen px per second with the arrow keys
const CAM_EDGE_MARGIN := Vector2(40, 40) # screen px you can pan past the map edge
const CAM_EDGE_MARGIN_TOP_LEFT := Vector2(40, 80) # more at the top: the top bar covers it
const ROTATE_STEP := deg_to_rad(15.0) # Q / E during planning
const ALLY_GAP := 6.0 # allies keep at least this much space between formations
const ENEMY_OVERLAP := 2.0 # enemies may press this far into each other, no further

var phase := Phase.PLANNING
var squads: Array[Squad] = []
var selected: Array[Squad] = []

## Trigger zones drawn by the player during planning
var zones: Array[Rect2] = []
## Planned orders: { squad: Squad, zone: Rect2, action: Action, fired: bool }
## One order per squad for now (later: limited by the leader's Tactics).
var orders: Array[Dictionary] = []
## Direct orders on their way by messenger:
## { squad, kind: "move"/"attack", pos, facing, enemy, left, total }
var pending: Array[Dictionary] = []
var commander: Squad = null
var _ai_timer := 0.0
var _ai_phase := "advance" # "advance" (form a line and march) -> "charge"
var _ai_clock := 0.0 # seconds spent in the current AI phase
var scout_points := SCOUT_POINTS
## { name, pos, progress 0..1, lost }
var objectives: Array[Dictionary] = []
## Short floating messages: { squad, text, left }
var _popups: Array[Dictionary] = []

var help_panel: PanelContainer
var _help_cols: HBoxContainer # two columns of control sections (Tab)
var _hint: Label # one line of the essentials, above the squad bar
var _st: Dictionary = {} # top bar labels by name
var tooltip: Label # who is the soldier under the mouse (screen space)
var cards: Array[SquadCard] = [] # the squad bar at the bottom of the screen
var _last_hotkey := -1
var _last_hotkey_ms := 0
var _ui: CanvasLayer
var pause_label: Label
var end_label: Label
var end_title: Label
var _end_card: PanelContainer
var _end_body: VBoxContainer
var _card_bar: HBoxContainer
var _hint_left := 0.0 # in battle the hint strip shows briefly, then only while paused
var end_screen: Control
var field: Battlefield
var overlay: Node2D # labels and previews, drawn above every squad
var cam: Camera2D
var _cam_zoom := 1.0 # 1 = whole map; the vertical squash (View.TILT) comes on top
var _panning := false
var _start_soldiers := 0
## Our losses this battle, as Soldier records (for the roll call)
var _dead: Array[Soldier] = []
var _wounded: Array[Soldier] = []
## Soldiers of squads that fled off the map: they live, they'll be back
var _fled: Array[Soldier] = []

var _zone_mode := false # next left-drag draws a zone instead of selecting
var _dragging := false
var _drag_start := Vector2.ZERO
var _drag_end := Vector2.ZERO
var _rdragging := false # right-drag sets the facing of a move/placement
var _rdrag_start := Vector2.ZERO
var _rdrag_end := Vector2.ZERO


func _ready() -> void:
	# Battle keeps handling input while the game is paused
	process_mode = Node.PROCESS_MODE_ALWAYS

	# 2.5D: draw nearer things (lower on the map) over farther ones
	y_sort_enabled = true
	cam = Camera2D.new()
	add_child(cam)
	cam.make_current()
	_reset_camera()

	field = Battlefield.new()
	add_child(field)
	overlay = Node2D.new()
	overlay.z_index = 10
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)

	for sites in OBJ_SITES:
		var pick: Array = sites.pick_random()
		objectives.append({ "name": pick[0], "pos": pick[1], "progress": 0.0, "lost": false })

	# Our side: one squad per leader, made of his fit soldiers (the army lives
	# in the Campaign autoload and carries over from battle to battle)
	var row := 0
	for l in Campaign.leaders:
		if l.is_commander:
			continue
		var roster := Campaign.fit_roster(l)
		if roster.is_empty():
			continue
		var sq := _spawn_squad(Vector2(270, 290 + row * 190), 0, PLAYER_COLOR, 0.0, roster.size(), l.command)
		sq.leader = l
		sq.members = roster
		row += 1

	# Their side: 75 soldiers in 5 squads, each led within its Command
	# Enemy army: 5 squads, roles and sizes shuffled every battle so they
	# have to be scouted. 2 flank, 2 line, 1 reserve.
	var roles := ["flank", "flank", "line", "line", "reserve"]
	roles.shuffle()
	var sizes := [12, 14, 15, 16, 18] # 75 in all: fewer, but they raid instead of charging into us
	sizes.shuffle()
	# Line and flank squads take line slots top to bottom; a flanker swings
	# out to the side of its slot (top half -> our top flank).
	var slots := [-1.5, -0.5, 0.5, 1.5]
	var next_slot := 0
	for i in roles.size():
		var e := _spawn_squad(Vector2(1060, 230 + i * 175), 1, ENEMY_COLOR, PI, sizes[i], sizes[i])
		e.set_meta("role", roles[i])
		if roles[i] == "reserve":
			e.set_meta("slot", 0.0)
		else:
			e.set_meta("slot", slots[next_slot])
			next_slot += 1
		e.set_meta("scouted", false)
		e.concealed = true

	var cl := Campaign.commander()
	commander = Squad.new()
	commander.team = 0
	commander.is_commander = true
	commander.leader = cl
	commander.members = Campaign.fit_roster(cl) # the bodyguard
	commander.soldier_count = maxi(commander.members.size(), 1)
	commander.command = cl.command # room to take in rallied soldiers before overloading
	commander.color = COMMANDER_COLOR
	commander.position = Vector2(130, 575)
	add_child(commander)
	squads.append(commander)
	commander.died.connect(_on_squad_died)
	commander.routed.connect(_on_squad_routed)
	commander.soldier_fell.connect(_on_soldier_fell)
	_start_soldiers = _count_soldiers(0)

	_build_ui()
	_build_cards()

	# Planning happens with the world frozen
	get_tree().paused = true
	Sound.music("music_plan")
	Sound.loop("amb_field", -16.0)
	_update_help()


# --- Squad bar -------------------------------------------------------------
# One card per squad of ours along the bottom of the screen: click to select
# (shift adds), double-click or press its number twice to move the camera there.

func _build_cards() -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(bar)
	_card_bar = bar
	var ours: Array[Squad] = []
	if is_instance_valid(commander):
		ours.append(commander)
	for s in squads:
		if s.team == 0 and s != commander:
			ours.append(s)
	for i in ours.size():
		var card := SquadCard.new()
		card.squad = ours[i]
		card.hotkey = i + 1
		card.color = ours[i].color
		card.title = ours[i].leader.name if ours[i].leader != null else "Squad %d" % (i + 1)
		card.picked.connect(_on_card_picked)
		card.focus_requested.connect(_on_card_focus)
		bar.add_child(card)
		cards.append(card)
	var w := ours.size() * SquadCard.SIZE.x + maxi(ours.size() - 1, 0) * 8
	bar.position = Vector2(640 - w / 2.0, 720 - SquadCard.SIZE.y - 8)


func _on_card_picked(card: SquadCard, add: bool) -> void:
	if card.is_gone():
		return
	Sound.play("ui_select")
	if not add:
		_clear_selection()
		_select(card.squad)
	elif card.squad in selected:
		_deselect(card.squad)
	else:
		_select(card.squad)


func _on_card_focus(card: SquadCard) -> void:
	if card.squad == null or not is_instance_valid(card.squad):
		return
	_on_card_picked(card, false)
	cam.position = card.squad.center()
	_cam_zoom = maxf(_cam_zoom, 1.8)
	_apply_camera()


## Number keys: select that squad; the same number twice quickly = go there.
func _hotkey(i: int) -> void:
	if i < 0 or i >= cards.size():
		return
	var now := Time.get_ticks_msec()
	if i == _last_hotkey and now - _last_hotkey_ms < 350:
		_on_card_focus(cards[i])
	else:
		_on_card_picked(cards[i], Input.is_key_pressed(KEY_SHIFT))
	_last_hotkey = i
	_last_hotkey_ms = now


func _update_cards() -> void:
	for card in cards:
		if card.squad == null or not is_instance_valid(card.squad):
			card.status = ""
			continue
		var st := _squad_status(card.squad)
		card.status = st[0]
		card.status_color = st[1]


## A one-word state for the card: what is this squad doing right now?
func _squad_status(s: Squad) -> Array:
	if s.routing:
		return ["BROKEN", Color(1.0, 0.45, 0.4)]
	if s.rallying:
		return ["RALLYING", COMMANDER_COLOR]
	if s.withdrawing > 0.0:
		return ["WITHDRAWING", Color(1.0, 0.85, 0.5)]
	if s.engaged_with != null:
		return ["FIGHTING", Color(1.0, 0.6, 0.4)]
	if s.has_meta("init_target"):
		return ["FLANKING", Color(0.6, 1.0, 0.55)]
	for o in pending:
		if o.squad == s:
			return ["ORDER EN ROUTE", Color(0.9, 0.9, 0.9)]
	for o in orders:
		if not o.fired and o.squad == s:
			return ["AMBUSH" if o.action == Action.ATTACK else "WILL RETREAT", ATTACK_COLOR if o.action == Action.ATTACK else RETREAT_COLOR]
	if s.get_meta("hold", false):
		return ["HOLD", Color(0.8, 0.85, 1.0)]
	if s.attack_target != null:
		return ["ATTACKING", Color(1.0, 0.7, 0.5)]
	if s.is_hidden():
		return ["HIDDEN", Color(0.55, 0.85, 0.55)]
	if s.global_position.distance_to(s.target_position) > 25.0:
		return ["MARCHING", Color(0.85, 0.9, 1.0)]
	return ["READY", Color(0.65, 0.7, 0.65)]


# --- Camera ----------------------------------------------------------------

func _reset_camera() -> void:
	_cam_zoom = 1.0
	cam.position = View.MAP_SIZE / 2.0
	_apply_camera()


func _apply_camera() -> void:
	# Same zoom both ways, then squash vertically: the field is seen at an angle
	cam.zoom = Vector2(_cam_zoom, _cam_zoom * View.TILT)
	# Keep the view on the map, with a little room past the edges so nothing
	# at the edge has to stay hidden under the top bar
	var half := get_viewport_rect().size / 2.0 / cam.zoom
	var lo := half - CAM_EDGE_MARGIN_TOP_LEFT / cam.zoom
	var hi := View.MAP_SIZE - half + CAM_EDGE_MARGIN / cam.zoom
	cam.position.x = clampf(cam.position.x, lo.x, maxf(lo.x, hi.x)) if hi.x >= lo.x else View.MAP_SIZE.x / 2.0
	cam.position.y = clampf(cam.position.y, lo.y, maxf(lo.y, hi.y)) if hi.y >= lo.y else View.MAP_SIZE.y / 2.0


## Zoom by `factor`, keeping the spot under the mouse where it is on screen.
func _zoom_at_mouse(factor: float) -> void:
	var screen_off := get_viewport().get_mouse_position() - get_viewport_rect().size / 2.0
	var world_before := cam.position + screen_off / cam.zoom
	_cam_zoom = clampf(_cam_zoom * factor, CAM_MIN_ZOOM, CAM_MAX_ZOOM)
	cam.zoom = Vector2(_cam_zoom, _cam_zoom * View.TILT)
	cam.position = world_before - screen_off / cam.zoom
	_apply_camera()


func _pan_with_keys(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if dir != Vector2.ZERO:
		cam.position += dir * CAM_PAN_SPEED * delta / cam.zoom
		_apply_camera()


# --- UI --------------------------------------------------------------------

func _panel_style(alpha: float = 0.78, radius: int = 8) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.08, alpha)
	sb.border_color = Color(0.85, 0.75, 0.45, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


func _build_ui() -> void:
	var ui := CanvasLayer.new()
	add_child(ui)
	_ui = ui

	# Top bar: battle and phase | armies | village, scouts, gold
	var bar := PanelContainer.new()
	var bar_style := _panel_style(0.78, 0)
	bar_style.border_color = Color(0.85, 0.75, 0.45, 0.3)
	bar_style.border_width_left = 0
	bar_style.border_width_right = 0
	bar_style.border_width_top = 0
	bar_style.content_margin_left = 16
	bar_style.content_margin_right = 16
	bar.add_theme_stylebox_override("panel", bar_style)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE # clicks go through to the field
	bar.position = Vector2.ZERO
	bar.size = Vector2(1280, 34)
	ui.add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(row)
	_st.battle = _bar_label(row, QUIET_GOLD, 14)
	_st.phase = _bar_label(row, Color(0.08, 0.08, 0.08), 12)
	_bar_spacer(row)
	_st.ours = _bar_label(row, PLAYER_COLOR.lightened(0.25), 17)
	_bar_label(row, QUIET_GOLD, 13).text = "soldiers  vs"
	_st.enemy = _bar_label(row, ENEMY_COLOR.lightened(0.15), 17)
	_bar_spacer(row)
	_st.village = _bar_label(row, COMMANDER_COLOR, 14)
	_st.scouts = _bar_label(row, Color(0.8, 0.9, 1.0), 14)
	_st.gold = _bar_label(row, COMMANDER_COLOR, 14)
	_st.help = _bar_label(row, QUIET_GOLD, 13)
	_st.help.text = "Tab  controls"

	# The essentials, always on screen, just above the squad bar
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.93, 0.9, 0.8))
	var hint_style := _panel_style(0.6, 12)
	hint_style.content_margin_left = 14
	hint_style.content_margin_right = 14
	hint_style.content_margin_top = 3
	hint_style.content_margin_bottom = 3
	_hint.add_theme_stylebox_override("normal", hint_style)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_hint)

	# All controls (Tab to show/hide): two columns of sections
	help_panel = PanelContainer.new()
	var help_style := _panel_style(0.9, 10)
	help_style.content_margin_left = 22
	help_style.content_margin_right = 22
	help_style.content_margin_top = 16
	help_style.content_margin_bottom = 16
	help_panel.add_theme_stylebox_override("panel", help_style)
	help_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	help_panel.visible = false
	ui.add_child(help_panel)
	_help_cols = HBoxContainer.new()
	_help_cols.add_theme_constant_override("separation", 36)
	help_panel.add_child(_help_cols)

	# Soldier tooltip, follows the mouse
	tooltip = Label.new()
	tooltip.add_theme_font_size_override("font_size", 13)
	tooltip.add_theme_color_override("font_color", Color(0.95, 0.92, 0.82))
	var tip_style := _panel_style(0.9, 6)
	tip_style.content_margin_left = 8
	tip_style.content_margin_right = 8
	tip_style.content_margin_top = 4
	tip_style.content_margin_bottom = 4
	tooltip.add_theme_stylebox_override("normal", tip_style)
	tooltip.visible = false
	ui.add_child(tooltip)

	# Paused pill
	pause_label = Label.new()
	pause_label.text = "PAUSED  -  Space to resume"
	pause_label.add_theme_font_size_override("font_size", 18)
	pause_label.add_theme_color_override("font_color", Color(1, 0.95, 0.8))
	pause_label.add_theme_stylebox_override("normal", _panel_style(0.8, 14))
	pause_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pause_label.position = Vector2(490, 50)
	pause_label.size = Vector2(300, 0)
	pause_label.visible = false
	ui.add_child(pause_label)

	# End screen: dim the field, centred panel
	end_screen = Control.new()
	end_screen.size = Vector2(1280, 720)
	end_screen.visible = false
	ui.add_child(end_screen)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.size = Vector2(1280, 720)
	end_screen.add_child(dim)
	_end_card = PanelContainer.new()
	var card_style := _panel_style(0.94, 12)
	card_style.content_margin_left = 44
	card_style.content_margin_right = 44
	card_style.content_margin_top = 24
	card_style.content_margin_bottom = 24
	_end_card.add_theme_stylebox_override("panel", card_style)
	end_screen.add_child(_end_card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.custom_minimum_size = Vector2(600, 0)
	_end_card.add_child(col)
	end_title = Label.new()
	end_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_title.add_theme_font_size_override("font_size", 40)
	col.add_child(end_title)
	end_label = Label.new() # the reason
	end_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	end_label.add_theme_font_size_override("font_size", 14)
	end_label.add_theme_color_override("font_color", QUIET_GOLD)
	col.add_child(end_label)
	_end_body = VBoxContainer.new()
	_end_body.add_theme_constant_override("separation", 12)
	col.add_child(_end_body)


## Wrapped labels only know their height after a layout pass: size the
## card a frame later, then centre it.
func _center_end_card() -> void:
	await get_tree().process_frame
	_end_card.size = Vector2.ZERO
	_end_card.reset_size()
	_end_card.position = ((Vector2(1280, 720) - _end_card.size) / 2.0).round()


func _bar_label(row: HBoxContainer, c: Color, size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size_flags_vertical = Control.SIZE_EXPAND_FILL
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(l)
	return l


func _bar_spacer(row: HBoxContainer) -> void:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(c)


## A small coloured tag (the phase in the top bar).
func _chip_style(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	return sb


func _update_status() -> void:
	_st.battle.text = "BATTLE %d" % Campaign.battle_number
	var names := { Phase.PLANNING: "PLANNING", Phase.BATTLE: "BATTLE", Phase.ENDED: "OVER" }
	var chips := { Phase.PLANNING: PLAYER_COLOR.lightened(0.35), Phase.BATTLE: Color(0.95, 0.6, 0.35), Phase.ENDED: Color(0.6, 0.6, 0.55) }
	_st.phase.text = names[phase]
	_st.phase.add_theme_stylebox_override("normal", _chip_style(chips[phase]))
	_st.ours.text = str(_count_soldiers(0))
	_st.enemy.text = str(_count_soldiers(1))
	var safe := 0
	for o in objectives:
		if not o.lost:
			safe += 1
	_st.village.text = "Village %d/%d" % [safe, objectives.size()]
	_st.village.add_theme_color_override("font_color", COMMANDER_COLOR if safe == objectives.size() else Color(1.0, 0.5, 0.4))
	_st.scouts.visible = phase == Phase.PLANNING
	_st.scouts.text = "Scouts %d" % scout_points
	_st.gold.text = "Gold %d" % Campaign.gold


func _spawn_squad(pos: Vector2, team: int, color: Color, facing: float,
		soldiers: int = 10, command: int = 10) -> Squad:
	var s := Squad.new()
	s.team = team
	s.soldier_count = soldiers
	s.command = command
	s.color = color
	s.position = pos
	s.rotation = facing
	add_child(s)
	squads.append(s)
	s.died.connect(_on_squad_died)
	s.routed.connect(_on_squad_routed)
	s.rallied.connect(_on_squad_rallied)
	s.rally_started.connect(_on_rally_started)
	s.soldier_fell.connect(_on_soldier_fell)
	return s


func _on_squad_died(s: Squad) -> void:
	squads.erase(s)
	selected.erase(s)
	# Removed with men still alive = it ran off the map: they'll be back
	if s.team == 0 and s.soldier_count > 0 and not s.rallying:
		_fled.append_array(s.members)


func _on_soldier_fell(pos: Vector2, color: Color, who: Soldier, wounded: bool) -> void:
	field.add_fallen(pos, color)
	Sound.play("hit", 0.0, 0.12, 90)
	if who == null:
		return
	if wounded:
		_wounded.append(who)
	else:
		_dead.append(who)


func _on_rally_started(s: Squad) -> void:
	selected.erase(s)
	s.selected = false
	_popups.append({ "squad": s, "text": "Rallying to the Commander!", "left": POPUP_TIME })
	Sound.play("rally")


func _on_squad_rallied(_s: Squad, cmd: Squad, count: int) -> void:
	_popups.append({ "squad": cmd, "text": "+%d joined" % count, "left": POPUP_TIME })


func _on_squad_routed(s: Squad) -> void:
	# Fleeing squads ignore orders, so drop them from the selection
	selected.erase(s)
	if phase == Phase.BATTLE:
		# Theirs breaking sounds a bit lower than ours
		Sound.play("rout", 0.0 if s.team == 0 else -2.0, 0.0)


func _process(delta: float) -> void:
	_pan_with_keys(delta)
	if phase == Phase.BATTLE and not get_tree().paused:
		_check_triggers()
		_tick_messengers(delta)
		_ai_timer -= delta
		if _ai_timer <= 0.0:
			_ai_timer = AI_THINK_INTERVAL
			_think_enemies()
			_our_initiative()
		_tick_objectives(delta)
		_hint_left -= delta
		_battle_sounds(delta)
		_separate_squads()
		_check_end()
		if Engine.get_process_frames() % 10 == 0:
			_update_status()
	elif phase == Phase.BATTLE:
		Sound.loop("battle_din", -80.0) # paused: hush the fighting
		Sound.loop("fire", -80.0)
	elif phase == Phase.PLANNING:
		# Placed squads may not overlap or leave the deployment area
		_separate_squads()
		for sq in squads:
			if sq.team == 0:
				sq.place_at(_clamp_to_deploy(sq.global_position), sq.rotation)
	if phase != Phase.ENDED and not (phase == Phase.BATTLE and get_tree().paused):
		for i in range(_popups.size() - 1, -1, -1):
			_popups[i].left -= delta
			if _popups[i].left <= 0.0:
				_popups.remove_at(i)
	queue_redraw() # order lines follow the squads
	overlay.queue_redraw()
	_update_tooltip()
	_update_cards()
	if phase != Phase.ENDED:
		_hint.visible = phase == Phase.PLANNING or get_tree().paused or _hint_left > 0.0


## Hovering one of our soldiers shows who he is.
func _update_tooltip() -> void:
	tooltip.visible = false
	if phase == Phase.ENDED:
		return
	# Hovering a squad card: its leader
	var screen_mouse := get_viewport().get_mouse_position()
	for card in cards:
		if card.get_global_rect().has_point(screen_mouse) and card.squad != null \
				and is_instance_valid(card.squad) and card.squad.leader != null:
			var l: Leader = card.squad.leader
			var lines: Array[String] = [
				l.name + ("  (Commander)" if l.is_commander else ""),
				"Command %d   Charisma %d   Tactics %d   Valor %d" % [l.command, l.charisma, l.tactics, l.valor],
			]
			for t in l.traits:
				lines.append("%s: %s" % [t, Leader.TRAIT_INFO.get(t, "")])
			lines.append("Soldiers' familiarity: %d" % roundi(card.squad.familiarity()))
			var wounded := Campaign.wounded_count(l)
			if wounded > 0:
				lines.append("%d wounded, sitting this one out" % wounded)
			tooltip.text = "\n".join(lines)
			tooltip.reset_size()
			var r := card.get_global_rect()
			tooltip.position = Vector2(clampf(r.position.x, 4, 1280 - tooltip.size.x - 4), r.position.y - tooltip.size.y - 6)
			tooltip.visible = true
			return
	var mouse := get_global_mouse_position()
	for s in squads:
		if s.team != 0 or s.members.is_empty():
			continue
		var i := s.man_at(mouse)
		if i < 0 or i >= s.members.size():
			continue
		var who: Soldier = s.members[i]
		var l := Campaign.leader_of(who)
		tooltip.text = "%s\n%s's men  -  %d battle%s  -  familiarity %d" % [
			who.name, l.name if l != null else "?", who.battles, "" if who.battles == 1 else "s", roundi(who.familiarity)]
		tooltip.reset_size()
		var at := get_viewport().get_mouse_position() + Vector2(16, -tooltip.size.y - 8)
		at.x = clampf(at.x, 4, 1280 - tooltip.size.x - 4)
		at.y = clampf(at.y, 40, 720 - tooltip.size.y - 4)
		tooltip.position = at
		tooltip.visible = true
		return


# --- Win / lose ------------------------------------------------------------
# Win: every enemy squad is destroyed or fleeing.
# Lose: the Commander falls or flees. (Broken squads can still rally to the
# Commander, so the fight goes on as long as the Commander stands.)

func _check_end() -> void:
	var enemy_standing := false
	for s in squads:
		if s.team == 1 and not s.routing:
			enemy_standing = true

	var commander_lost := not is_instance_valid(commander) or commander.routing
	var all_burned := not objectives.is_empty()
	for o in objectives:
		if not o.lost:
			all_burned = false
	if commander_lost:
		_end_battle(false, "Your Commander has fallen.")
	elif all_burned:
		_end_battle(false, "The village's lands are burning. The army falls back to save what's left.")
	elif not enemy_standing:
		_end_battle(true, "The enemy is broken.")


func _end_battle(won: bool, reason: String) -> void:
	phase = Phase.ENDED
	get_tree().paused = true
	pause_label.visible = false
	# Everyone of ours still on the field (fleeing or not), plus those who ran off
	var survivors: Array[Soldier] = _fled.duplicate()
	for s in squads:
		if s.team == 0:
			survivors.append_array(s.members)
	var burned: Array[String] = []
	for o in objectives:
		if o.lost:
			burned.append(o.name)
	var r := Campaign.apply_result(won, _dead, _wounded, survivors, burned)
	end_title.text = "VICTORY" if won else "DEFEAT"
	end_title.add_theme_color_override("font_color", Color(0.7, 0.95, 0.55) if won else Color(1.0, 0.5, 0.42))
	end_label.text = reason
	_fill_roll_call(r)
	end_screen.visible = true
	help_panel.visible = false
	_hint.visible = false
	_card_bar.visible = false
	Sound.stop_loops()
	Sound.loop("amb_field", -18.0)
	Sound.music("")
	Sound.play("victory" if won else "defeat")
	_center_end_card.call_deferred()
	_update_status()


## The roll call shown after a battle: the numbers, then who fell, who was
## left behind and who is wounded, by name.
func _fill_roll_call(r: Dictionary) -> void:
	for c in _end_body.get_children():
		c.queue_free()
	var stats := HBoxContainer.new()
	stats.alignment = BoxContainer.ALIGNMENT_CENTER
	stats.add_theme_constant_override("separation", 14)
	_end_body.add_child(stats)
	_stat_box(stats, r.survivors, "came back", Color(0.75, 0.9, 1.0))
	_stat_box(stats, r.fallen.size(), "fallen", Color(1.0, 0.55, 0.45))
	_stat_box(stats, r.wounded.size() + r.left_behind.size(), "wounded", Color(1.0, 0.8, 0.45))
	var burned: Array = r.get("burned", [])
	if not burned.is_empty():
		_stat_box(stats, burned.size(), "burned", Color(1.0, 0.5, 0.3))
	if not burned.is_empty():
		_name_section("Burned", Color(1.0, 0.5, 0.3), ", ".join(burned) +
			"   (-%d gold, -%d volunteers each)" % [Campaign.BURN_GOLD, Campaign.BURN_VOLUNTEERS])
	_name_section("Fallen", Color(1.0, 0.55, 0.45), _names(r.fallen, "No one. Everyone came home."))
	if not r.left_behind.is_empty():
		_name_section("Wounded, left on the field", Color(1.0, 0.6, 0.4), _names(r.left_behind, ""))
	_name_section("Wounded, back in 1-2 battles", Color(1.0, 0.8, 0.45), _names(r.wounded, "None."))
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	_end_body.add_child(buttons)
	buttons.add_child(_end_button("To camp   [Enter]", true, _go_to_camp))
	buttons.add_child(_end_button("New campaign   [N]", false, _new_campaign))


func _stat_box(parent: HBoxContainer, n: int, what: String, c: Color) -> void:
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.05)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 4
	sb.content_margin_bottom = 6
	box.add_theme_stylebox_override("panel", sb)
	parent.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -4)
	box.add_child(v)
	var num := Label.new()
	num.text = str(n)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.add_theme_font_size_override("font_size", 26)
	num.add_theme_color_override("font_color", c)
	v.add_child(num)
	var cap := Label.new()
	cap.text = what
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_theme_font_size_override("font_size", 12)
	cap.add_theme_color_override("font_color", QUIET_GOLD)
	v.add_child(cap)


func _name_section(title: String, c: Color, body: String) -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	_end_body.add_child(v)
	var t := Label.new()
	t.text = title.to_upper()
	t.add_theme_font_size_override("font_size", 12)
	t.add_theme_color_override("font_color", c)
	v.add_child(t)
	var b := Label.new()
	b.text = body
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.custom_minimum_size = Vector2(600, 0)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", Color(0.92, 0.91, 0.86))
	v.add_child(b)


func _names(who: Array, empty: String) -> String:
	if who.is_empty():
		return empty
	var names: Array[String] = []
	for s in who:
		names.append(s.name)
	return ", ".join(names)


func _end_button(text: String, main: bool, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(190, 34)
	b.add_theme_font_size_override("font_size", 14)
	var sb := _chip_style(Color(0.85, 0.72, 0.4) if main else Color(1, 1, 1, 0.1))
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	var hover := sb.duplicate() as StyleBoxFlat
	hover.bg_color = hover.bg_color.lightened(0.15)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var fc := Color(0.1, 0.08, 0.05) if main else Color(0.92, 0.9, 0.84)
	b.add_theme_color_override("font_color", fc)
	b.add_theme_color_override("font_hover_color", fc)
	b.add_theme_color_override("font_pressed_color", fc)
	b.pressed.connect(func() -> void:
		Sound.play("ui_click")
		on_press.call())
	return b


func _go_to_camp() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/camp.tscn")


func _new_campaign() -> void:
	Campaign.new_campaign()
	get_tree().paused = false
	get_tree().reload_current_scene()


## Soldiers of a team still in the fight (fleeing squads don't count).
func _count_soldiers(team: int) -> int:
	var n := 0
	for s in squads:
		if s.team == team and not s.routing:
			n += s.soldier_count
	return n


# --- Phases ----------------------------------------------------------------

func _start_battle() -> void:
	phase = Phase.BATTLE
	_zone_mode = false
	get_tree().paused = false
	_ai_timer = 0.0
	_ai_phase = "advance"
	_ai_clock = 0.0
	# Once they march into view we can count them, but unscouted roles stay
	# unknown until they show it by how they move.
	for s in squads:
		if s.team == 1:
			s.concealed = false
	help_panel.visible = false # Tab brings it back
	_hint_left = 8.0
	Sound.play("battle_start")
	Sound.music("music_battle")
	_update_help()


# --- Enemy AI --------------------------------------------------------------
# The enemy fights as one army:
#   1. ADVANCE: form a line facing our main body and march up together.
#   2. CHARGE: the line squads hit our front; the flank squads swing wide
#      around our edges and hit us from the side and rear; the reserve waits
#      and joins wherever an ally is about to break.
# Each squad's role is shown under it during the battle (intel).
# Routing is handled by morale, not here.

func _think_enemies() -> void:
	var ours := _body_center(0)
	var theirs := _body_center(1)
	if ours == Vector2.INF or theirs == Vector2.INF:
		return
	var dir := (theirs - ours).normalized() # from us toward them
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	var perp := -dir.orthogonal() # "down" the enemy line (matches negative slot = top)
	var face_us := (-dir).angle()
	var anchor := ours + dir * AI_STANDOFF
	_ai_clock += AI_THINK_INTERVAL
	# Raiders go for undefended objectives whatever phase the rest is in.
	# While one is burning a place unopposed, the main body won't charge
	# into a waiting army: it holds its line and lets the fire do the work.
	var burning := _ai_raid()

	if _ai_phase == "advance":
		var line_set := true
		var close := false
		for s in squads:
			if s.team != 1 or s.routing or s.has_meta("raid"):
				continue
			if s.get_meta("role", "line") == "reserve":
				s.move_to(anchor + dir * AI_RESERVE_BACK, face_us)
				continue
			var slot_pos := anchor + perp * float(s.get_meta("slot", 0.0)) * AI_LINE_SPACING
			s.move_to(slot_pos, face_us)
			if s.global_position.distance_to(slot_pos) > 40.0:
				line_set = false
			if s.engaged_with != null or _nearest_dist(s.global_position, 0) < AI_CONTACT:
				close = true
		if line_set or close or _ai_clock > AI_MAX_ADVANCE_TIME:
			_ai_phase = "charge"
			_ai_clock = 0.0
		return

	# CHARGE
	var spread := _body_spread(0, ours, perp)
	for s in squads:
		if s.team != 1 or s.routing or s.engaged_with != null or s.has_meta("raid"):
			continue
		var role: String = s.get_meta("role", "line")
		if burning and role != "flank" and _nearest_dist(s.global_position, 0) > AI_CONTACT:
			# Don't take the bait: wait in line, out of reach
			if role == "reserve":
				s.move_to(anchor + dir * AI_RESERVE_BACK, face_us)
			else:
				s.move_to(anchor + perp * float(s.get_meta("slot", 0.0)) * AI_LINE_SPACING, face_us)
			continue
		if _steer_flank(s):
			continue # already swinging around to hit someone's side
		match role:
			"line":
				_ai_choose_target(s)
			"flank":
				if s.get_meta("wrapped", false):
					_ai_choose_target(s)
					continue
				var side := signf(float(s.get_meta("slot", 1.0)))
				var wrap := ours + perp * side * (spread + AI_FLANK_WIDTH) - dir * AI_FLANK_DEPTH
				if s.global_position.distance_to(wrap) < 60.0 or _nearest_dist(s.global_position, 0) < 70.0:
					s.set_meta("wrapped", true)
					_ai_choose_target(s)
				else:
					s.move_to(wrap)
			"reserve":
				var help := _ally_in_trouble(s.team)
				if help != null:
					s.attack(help)
				elif _ai_clock > AI_RESERVE_TIMEOUT:
					_ai_choose_target(s)


## Sends raiders at objectives nobody (visible) is guarding and steers the
## ones already out. Returns true while a raider is burning a place unopposed.
func _ai_raid() -> bool:
	var burning := false
	var raiders := 0
	for s in squads:
		if s.team != 1 or not s.has_meta("raid"):
			continue
		if s.routing:
			s.remove_meta("raid")
			continue
		var o: Dictionary = objectives[int(s.get_meta("raid"))]
		if o.lost:
			s.remove_meta("raid") # job done: back to the army
			continue
		raiders += 1
		if s.engaged_with != null:
			continue
		var guard := _visible_guard(o.pos, OBJ_DEFEND_RADIUS + 40.0)
		if guard != null:
			s.attack(guard) # someone came to stop us: fight him
		else:
			s.move_to(o.pos)
			if s.global_position.distance_to(o.pos) < OBJ_RADIUS:
				burning = true
	if raiders >= AI_MAX_RAIDERS:
		return burning
	for i in objectives.size():
		var o: Dictionary = objectives[i]
		if o.lost or _raider_on(i) or _visible_guard(o.pos, AI_GUARD_RADIUS) != null:
			continue
		# Flankers are fast hands for this; the reserve stays put
		var best: Squad = null
		var best_score := INF
		for s in squads:
			if s.team != 1 or s.routing or s.engaged_with != null or s.has_meta("raid") \
					or s.get_meta("role", "line") == "reserve":
				continue
			var score := s.global_position.distance_to(o.pos)
			if s.get_meta("role", "line") == "flank":
				score -= 250.0
			if score < best_score:
				best_score = score
				best = s
		if best != null:
			best.set_meta("raid", i)
			best.remove_meta("init_target")
			best.move_to(o.pos)
			raiders += 1
			if raiders >= AI_MAX_RAIDERS:
				break
	return burning


func _raider_on(i: int) -> bool:
	for s in squads:
		if s.team == 1 and not s.routing and s.has_meta("raid") and int(s.get_meta("raid")) == i:
			return true
	return false


## Nearest squad of ours the enemy can see within `radius` of `p`.
func _visible_guard(p: Vector2, radius: float) -> Squad:
	var best: Squad = null
	var best_d := radius
	for s in squads:
		if s.team != 0 or s.routing or s.is_hidden():
			continue
		var d := s.global_position.distance_to(p)
		if d < best_d:
			best_d = d
			best = s
	return best


## The sound of the fight: a din that swells with every melee, single clangs
## on top, and fire while a place burns.
func _battle_sounds(delta: float) -> void:
	var fights := 0
	for s in squads:
		if s.engaged_with != null and not s.routing:
			fights += 1
	fights = fights / 2 + fights % 2 # two squads per melee, roughly
	Sound.loop("battle_din", -80.0 if fights == 0 else -20.0 + minf(fights, 5) * 2.2)
	if fights > 0 and randf() < delta * (1.5 + fights * 1.8):
		Sound.play("clash", randf_range(-4.0, 1.0), 0.1)
	var burning := false
	for o in objectives:
		if o.get("burning", false) and not o.lost:
			burning = true
		o.burning = false # set again next frame if still burning
	Sound.loop("fire", -13.0 if burning else -80.0)


## Burning: an enemy squad inside, none of ours near (hidden ones count:
## they're really there).
func _tick_objectives(delta: float) -> void:
	for o in objectives:
		if o.lost:
			continue
		var raiders := 0
		var defended := false
		for s in squads:
			if s.routing:
				continue
			var d := s.center().distance_to(o.pos)
			if s.team == 1 and d < OBJ_RADIUS:
				raiders += 1
			elif s.team == 0 and d < OBJ_DEFEND_RADIUS:
				defended = true
		if raiders > 0 and not defended:
			o.progress = minf(1.0, o.progress + delta / OBJ_BURN_TIME)
			if o.progress >= 1.0:
				o.lost = true
				_popups.append({ "pos": o.pos, "text": "%s burned!" % o.name, "left": POPUP_TIME * 1.5 })
				Sound.play("burned")
			elif o.progress - delta / OBJ_BURN_TIME <= 0.0:
				_popups.append({ "pos": o.pos, "text": "%s is under attack!" % o.name, "left": POPUP_TIME })
				Sound.play("bell")
			o.burning = true


## A free enemy squad decides what to do:
##   1. if one of our squads nearby is already fighting one of theirs, swing
##      round and hit its side (unless enough of them are on it already);
##   2. otherwise attack the best target: close, shaken, or our Commander.
func _ai_choose_target(s: Squad) -> void:
	var busy := _enemy_fighting_near(s, AI_HELP_RADIUS)
	if busy != null and _attackers_on(busy, s) < AI_MAX_GANG:
		s.set_meta("init_target", busy)
		s.move_to(_flank_point(s, busy))
		return
	_ai_attack_best(s)


func _ai_attack_best(s: Squad) -> void:
	var best: Squad = null
	var best_score := INF
	for p in squads:
		if p.team == s.team or p.routing or p.is_hidden():
			continue # can't attack what you don't know is there
		var score := _target_score(s, p)
		if score < best_score:
			best_score = score
			best = p
	if best == null:
		return
	var cur := s.attack_target
	var cur_bad := cur == null or not is_instance_valid(cur) or cur.routing
	if cur_bad or best_score + AI_RETARGET_MARGIN < _target_score(s, cur):
		s.attack(best)


## Lower is better: near, low on morale, and the Commander above all.
func _target_score(s: Squad, p: Squad) -> float:
	var score := s.global_position.distance_to(p.global_position)
	score -= (Squad.MAX_MORALE - p.morale) * AI_WEAK_WEIGHT
	if p.is_commander:
		score -= AI_COMMANDER_BONUS
	return score


## How many squads of the other side are already fighting or heading for `p`.
func _attackers_on(p: Squad, exclude: Squad) -> int:
	var n := 0
	for q in squads:
		if q == exclude or q.team == p.team or q.routing:
			continue
		if q.engaged_with == p or q.attack_target == p or (q.has_meta("init_target") and q.get_meta("init_target") == p):
			n += 1
	return n


## The enemy of an ally of `team` that is in melee and close to breaking.
func _ally_in_trouble(team: int) -> Squad:
	var worst: Squad = null
	var worst_morale := AI_RESERVE_COMMIT_MORALE
	for s in squads:
		if s.team != team or s.routing or s.engaged_with == null:
			continue
		if s.morale < worst_morale and is_instance_valid(s.engaged_with):
			worst_morale = s.morale
			worst = s.engaged_with
	return worst


## Middle of a side's fighting squads (the Commander only if nobody else is left).
func _body_center(team: int) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	var fallback := Vector2.INF
	for s in squads:
		if s.team != team or s.routing or s.is_hidden():
			continue # the enemy plans around what it can see
		if s.is_commander:
			fallback = s.global_position
			continue
		sum += s.global_position
		n += 1
	return sum / n if n > 0 else fallback


## How far our formation reaches sideways from its middle (along `perp`).
func _body_spread(team: int, middle: Vector2, perp: Vector2) -> float:
	var far := 0.0
	for s in squads:
		if s.team == team and not s.routing:
			far = maxf(far, absf((s.global_position - middle).dot(perp)) + s.radius())
	return far


func _nearest_dist(from: Vector2, team: int) -> float:
	var t := _nearest_squad(from, team)
	return INF if t == null else from.distance_to(t.global_position)


func _nearest_squad(from: Vector2, team: int) -> Squad:
	var best: Squad = null
	var best_d := INF
	for s in squads:
		if s.team != team or s.routing:
			continue
		var d := from.distance_to(s.global_position)
		if d < best_d:
			best_d = d
			best = s
	return best


func _update_help() -> void:
	var left: Array
	var right: Array
	if phase == Phase.PLANNING:
		if _zone_mode:
			_hint.text = "Drawing a zone: left-drag on the map     Z  cancel"
		else:
			_hint.text = "Right-click  place     Q / E  rotate     Z  draw zone     S  scout     Enter  START BATTLE     Tab  all controls"
		left = [
			["Deploy  (the world is frozen)", [
				["Left-drag", "select squads"],
				["Right-click", "place, inside the blue area"],
				["Right-drag", "place and set facing"],
				["Q / E", "rotate"],
				["H", "hold: stay put, no initiative"]]],
			["Battle plan", [
				["Z, then drag", "draw a trigger zone"],
				["A  over a zone", "selected squads ATTACK whoever enters"],
				["R  over a zone", "selected squads RETREAT when an enemy enters"],
				["X  over a zone", "delete it"]]],
			["Intel", [
				["S  over an enemy", "scout it: role and size (2 per battle)"]]],
		]
		right = _terrain_help() + [_view_help()]
	else:
		_hint.text = "Space  pause     Right-click  order     Right-drag  move + facing     H  hold     Tab  all controls"
		left = [
			["Orders", [
				["Space", "pause (orders still work)"],
				["Right-click", "move, or attack an enemy"],
				["Right-drag", "move and set facing"],
				["H", "hold: stay put, no initiative"]]],
			["Messengers", [
				["Far squads", "orders ride out from the Commander: they react later"],
				["Commander's circle", "orders are instant, fleeing squads rally"],
				["Planned orders", "always instant, with a surprise bonus"]]],
		]
		right = _terrain_help() + [_view_help()]
	for c in _help_cols.get_children():
		c.queue_free()
	_help_cols.add_child(_help_column(left))
	_help_cols.add_child(_help_column(right))
	_hint.reset_size()
	_hint.position = Vector2(640 - _hint.size.x / 2.0, 720 - SquadCard.SIZE.y - 12 - _hint.size.y)
	help_panel.reset_size()
	help_panel.position = Vector2(640 - help_panel.size.x / 2.0, _hint.position.y - 8 - help_panel.size.y)
	_update_status()


func _terrain_help() -> Array:
	return [
		["Terrain", [
			["Forest", "hides you from the enemy, cover, slow"],
			["Hill", "hit harder downhill"],
			["Stream", "cross only at the bridge or a ford"],
			["Ford", "slow, bad footing"],
			["Road", "a bit faster"]]],
		["Village", [
			["Burning", "an enemy alone on a place burns it: -gold, -volunteers"],
			["All burned", "the battle is lost"],
			["Raiders", "go for places they see unguarded (forest guards are unseen)"]]],
	]


func _view_help() -> Array:
	return ["View", [
		["1-9", "select a squad (twice: go to it)"],
		["Wheel, arrows", "zoom and pan; Home resets"]]]


## One column of sections: a title, then key / what-it-does rows.
func _help_column(sections: Array) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	for sec in sections:
		var t := Label.new()
		t.text = String(sec[0]).to_upper()
		t.add_theme_font_size_override("font_size", 12)
		t.add_theme_color_override("font_color", COMMANDER_COLOR)
		col.add_child(t)
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 14)
		grid.add_theme_constant_override("v_separation", 2)
		col.add_child(grid)
		for row in sec[1]:
			var k := Label.new()
			k.text = row[0]
			k.custom_minimum_size = Vector2(130, 0)
			k.add_theme_font_size_override("font_size", 13)
			k.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
			grid.add_child(k)
			var d := Label.new()
			d.text = row[1]
			d.add_theme_font_size_override("font_size", 13)
			d.add_theme_color_override("font_color", Color(0.9, 0.89, 0.84))
			grid.add_child(d)
	return col


# --- Input -----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := get_global_mouse_position()
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_at_mouse(1.15)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_at_mouse(1.0 / 1.15)
			return
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = event.pressed
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_drag_start = mouse
				_drag_end = mouse
			elif _dragging:
				_dragging = false
				_on_left_release(mouse, event.shift_pressed)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed and not selected.is_empty():
				_rdragging = true
				_rdrag_start = mouse
				_rdrag_end = mouse
			elif not event.pressed and _rdragging:
				_rdragging = false
				_on_right_release(mouse)

	elif event is InputEventMouseMotion:
		if _panning:
			cam.position -= event.relative / cam.zoom
			_apply_camera()
		if _dragging:
			_drag_end = get_global_mouse_position()
		if _rdragging:
			_rdrag_end = get_global_mouse_position()

	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key(event.keycode)


func _on_left_release(mouse: Vector2, additive: bool) -> void:
	var is_drag := _drag_start.distance_to(mouse) >= DRAG_THRESHOLD
	var rect := Rect2(_drag_start, mouse - _drag_start).abs()
	if _zone_mode:
		if is_drag:
			zones.append(rect)
		_zone_mode = false
		_update_help()
	elif is_drag:
		_box_select(rect, additive)
	else:
		_click_select(mouse, additive)


## Right-click: move there (attack, if it's an enemy during battle).
## Right-drag: move to where you pressed, facing the way you dragged.
func _on_right_release(mouse: Vector2) -> void:
	if selected.is_empty():
		return
	var dragged := _rdrag_start.distance_to(mouse) >= DRAG_THRESHOLD
	Sound.play("order" if phase == Phase.BATTLE else "ui_select", 0.0, 0.06, 80)
	if not dragged:
		var enemy := _squad_at(mouse, 1)
		if phase == Phase.BATTLE and enemy != null:
			for s in selected:
				_issue(s, { "kind": "attack", "enemy": enemy })
			return
		_order_move(mouse)
	else:
		_order_move(_rdrag_start, (mouse - _rdrag_start).angle())


func _on_key(key: Key) -> void:
	if phase == Phase.ENDED:
		if key == KEY_ENTER or key == KEY_KP_ENTER or key == KEY_R:
			_go_to_camp()
		elif key == KEY_N:
			_new_campaign()
		return
	match key:
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
			_hotkey(key - KEY_1)
		KEY_HOME:
			_reset_camera()
		KEY_TAB:
			help_panel.visible = not help_panel.visible
		KEY_SPACE:
			if phase == Phase.BATTLE:
				get_tree().paused = not get_tree().paused
				pause_label.visible = get_tree().paused
		KEY_ENTER, KEY_KP_ENTER:
			if phase == Phase.PLANNING:
				_start_battle()
		KEY_Z:
			if phase == Phase.PLANNING:
				_zone_mode = not _zone_mode
				_update_help()
		KEY_A:
			_assign_order(Action.ATTACK)
		KEY_R:
			_assign_order(Action.RETREAT)
		KEY_X:
			_delete_zone_under_mouse()
		KEY_Q:
			_rotate_selected(-ROTATE_STEP)
		KEY_E:
			_rotate_selected(ROTATE_STEP)
		KEY_S:
			_scout_under_mouse()
		KEY_H:
			_toggle_hold()


## Selected squads ignore initiative and stay where they're put (toggle).
func _toggle_hold() -> void:
	if selected.is_empty():
		return
	var all_held := true
	for s in selected:
		if not s.get_meta("hold", false):
			all_held = false
	for s in selected:
		s.set_meta("hold", not all_held)
		_cancel_initiative(s)


## Planning only: spend a scout point to reveal an enemy squad's role and size.
func _scout_under_mouse() -> void:
	if phase != Phase.PLANNING or scout_points <= 0:
		return
	var e := _squad_at(get_global_mouse_position(), 1)
	if e == null or e.get_meta("scouted", false):
		return
	e.set_meta("scouted", true)
	e.concealed = false
	scout_points -= 1
	_popups.append({ "squad": e, "text": "Scouted: %s, %d soldiers" % [String(e.get_meta("role")).capitalize(), e.soldier_count], "left": POPUP_TIME })
	Sound.play("scout")
	_update_help()


## Planning only: turn each selected squad in place.
func _rotate_selected(angle: float) -> void:
	if phase != Phase.PLANNING:
		return
	for s in selected:
		s.place_at(s.global_position, s.rotation + angle)


func _squad_at(point: Vector2, team: int) -> Squad:
	for s in squads:
		if s.team == team and s.contains_point(point):
			return s
	return null


func _zone_at(point: Vector2) -> int:
	# Newest zone wins when zones overlap
	for i in range(zones.size() - 1, -1, -1):
		if zones[i].has_point(point):
			return i
	return -1


# --- Planning --------------------------------------------------------------

func _assign_order(action: Action) -> void:
	if phase != Phase.PLANNING or selected.is_empty():
		return
	var zi := _zone_at(get_global_mouse_position())
	if zi < 0:
		return
	for s in selected:
		_remove_orders_for(s)
		orders.append({ "squad": s, "zone": zones[zi], "action": action, "fired": false })
	Sound.play("ui_select")


func _remove_orders_for(s: Squad) -> void:
	for i in range(orders.size() - 1, -1, -1):
		if orders[i].squad == s:
			orders.remove_at(i)


func _delete_zone_under_mouse() -> void:
	if phase != Phase.PLANNING:
		return
	var zi := _zone_at(get_global_mouse_position())
	if zi < 0:
		return
	var zone := zones[zi]
	zones.remove_at(zi)
	for i in range(orders.size() - 1, -1, -1):
		if orders[i].zone == zone:
			orders.remove_at(i)


## Fire every planned order whose zone an enemy has entered.
func _check_triggers() -> void:
	for order in orders:
		if order.fired:
			continue
		if not is_instance_valid(order.squad) or order.squad.routing:
			order.fired = true
			continue
		var s: Squad = order.squad
		var intruder := _enemy_in_zone(order.zone)
		if intruder == null:
			continue
		order.fired = true
		Sound.play("signal", 0.0, 0.03, 300) # the plan goes off
		match order.action:
			Action.ATTACK:
				_cancel_initiative(s)
				s.attack(intruder, true)
			Action.RETREAT:
				var back := s.global_position + Vector2.LEFT * RETREAT_DISTANCE
				back.x = maxf(back.x, 60.0)
				_cancel_initiative(s)
				s.withdraw_to(back, 0.0)


func _enemy_in_zone(zone: Rect2) -> Squad:
	for s in squads:
		if s.team == 1 and not s.routing and zone.has_point(s.global_position):
			return s
	return null


# --- Selection -------------------------------------------------------------

func _click_select(point: Vector2, additive: bool) -> void:
	var hit := _squad_at(point, 0)
	if not additive:
		_clear_selection()
	if hit == null:
		return
	if additive and hit in selected:
		_deselect(hit)
	else:
		_select(hit)


func _box_select(rect: Rect2, additive: bool) -> void:
	if not additive:
		_clear_selection()
	for s in squads:
		if s.team == 0 and s.touches_rect(rect):
			_select(s)


func _select(s: Squad) -> void:
	if s.routing or s.rallying:
		return
	if s not in selected:
		selected.append(s)
		s.selected = true


func _deselect(s: Squad) -> void:
	selected.erase(s)
	s.selected = false


func _clear_selection() -> void:
	for s in selected:
		s.selected = false
	selected.clear()


# --- Orders ----------------------------------------------------------------

## Move all selected squads to the target, lined up side by side, all
## facing the direction of travel. During planning they are placed at once,
## stacked vertically and facing the enemy side.
func _order_move(target: Vector2, facing_override: float = NAN) -> void:
	var center := Vector2.ZERO
	for s in selected:
		center += s.global_position
	center /= selected.size()

	var planning := phase == Phase.PLANNING
	var dir := target - center
	if dir.length() < 1.0:
		dir = Vector2.RIGHT.rotated(selected[0].rotation)
	dir = dir.normalized()
	# Facing: the dragged direction if given; while planning, keep the current
	# facing; in battle, face the way the squads walk.
	var facing := dir.angle()
	if not is_nan(facing_override):
		facing = facing_override
	elif planning:
		facing = selected[0].rotation
	# Squads line up side by side, across the facing direction
	var perp := Vector2.RIGHT.rotated(facing).orthogonal()

	# Keep squads in their current order so paths don't cross
	var ordered: Array[Squad] = selected.duplicate()
	ordered.sort_custom(func(a: Squad, b: Squad) -> bool:
		return a.global_position.dot(perp) < b.global_position.dot(perp))

	var n := ordered.size()
	for i in n:
		var pos := target + perp * (i - (n - 1) / 2.0) * LINE_SPACING
		if planning:
			ordered[i].place_at(_clamp_to_deploy(pos), facing)
		else:
			_issue(ordered[i], { "kind": "move", "pos": pos, "facing": facing })


func _clamp_to_deploy(p: Vector2) -> Vector2:
	var r := DEPLOY_ZONE.grow(-30.0)
	return Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))


# --- Separation ------------------------------------------------------------
# Formations push each other apart so they never overlap: allies keep a small
# gap, enemies meet edge to edge (and fight). Fleeing squads slip through.

func _separate_squads() -> void:
	var n := squads.size()
	for i in n:
		var a := squads[i]
		if a.routing:
			continue
		for j in range(i + 1, n):
			var b := squads[j]
			if b.routing:
				continue
			var min_dist := a.radius() + b.radius()
			min_dist += ALLY_GAP if a.team == b.team else -ENEMY_OVERLAP
			var delta := b.center() - a.center()
			var d := delta.length()
			if d >= min_dist:
				continue
			var push := (delta / d) if d > 0.01 else Vector2.RIGHT
			var overlap := min_dist - d
			_nudge(a, -push * overlap * 0.5)
			_nudge(b, push * overlap * 0.5)


## Move a squad aside. If it was standing at its destination, the destination
## moves too, otherwise it would walk straight back and jitter against its
## neighbour.
func _nudge(s: Squad, by: Vector2) -> void:
	var settled := s.global_position.distance_to(s.target_position) < 30.0 and s.attack_target == null
	if Terrain.in_water(s.center() + by) and not Terrain.in_water(s.center()):
		return # don't shove anyone into the stream
	s.global_position += by
	if settled:
		s.target_position += by


# --- Messengers ------------------------------------------------------------

## Send a direct order. The commander obeys at once; everyone else waits
## for a messenger. A newer order replaces one still on its way.
func _issue(s: Squad, order: Dictionary) -> void:
	for i in range(pending.size() - 1, -1, -1):
		if pending[i].squad == s:
			pending.remove_at(i)
	var delay := _order_delay(s)
	if delay <= 0.0:
		_deliver(s, order)
		return
	order.squad = s
	order.left = delay
	order.total = delay
	pending.append(order)


func _order_delay(s: Squad) -> float:
	if s == commander:
		return 0.0
	if not is_instance_valid(commander) or commander.routing:
		return MAX_ORDER_DELAY
	var d := commander.global_position.distance_to(s.global_position)
	# Inside the Commander's aura, orders are shouted directly: instant
	if d < Squad.COMMANDER_AURA_RADIUS:
		return 0.0
	# An overloaded squad also takes longer to get moving (up to +1.4 s)
	var sluggish := (1.0 - s.efficiency()) * 2.0
	var delay := MIN_ORDER_DELAY + d / MESSENGER_SPEED + sluggish
	# A sharp leader (Tactics) acts on orders faster; a Hothead argues first
	delay *= 1.3 - s.stat("tactics") * 0.006
	if s.has_trait("Hothead"):
		delay += 0.6
	# Men who know their leader's ways get moving sooner
	delay -= 0.6 * s.familiarity() / 100.0
	return clampf(delay, MIN_ORDER_DELAY, MAX_ORDER_DELAY)


func _tick_messengers(delta: float) -> void:
	for i in range(pending.size() - 1, -1, -1):
		var o: Dictionary = pending[i]
		o.left -= delta
		if o.left > 0.0:
			continue
		pending.remove_at(i)
		if is_instance_valid(o.squad) and not o.squad.routing:
			_deliver(o.squad, o)


func _deliver(s: Squad, order: Dictionary) -> void:
	_cancel_initiative(s) # your orders always override initiative
	# ...and replace any plan this squad was still waiting on
	for o in orders:
		if o.squad == s and not o.fired:
			o.fired = true
	if order.kind == "attack":
		if is_instance_valid(order.enemy):
			s.attack(order.enemy)
	else:
		s.withdraw_to(order.pos, order.facing) # same as move_to unless it's in melee


# --- Initiative ------------------------------------------------------------
# An idle squad of ours (no fight, no order, no messenger on the way, not an
# ambush waiting for its trigger, not on HOLD) that sees an ally fighting
# nearby swings around to the side of that ally's enemy and hits it there.

func _our_initiative() -> void:
	for s in squads:
		if s.team != 0 or s.is_commander or s.routing or s.rallying:
			continue
		if _steer_flank(s):
			continue
		if not _is_idle(s):
			continue
		# A tactically sharp leader notices fights further away
		var enemy := _enemy_fighting_near(s, INITIATIVE_RADIUS * (0.6 + s.stat("tactics") * 0.008))
		if enemy != null:
			s.set_meta("init_target", enemy)
			s.move_to(_flank_point(s, enemy))


## A squad swinging round to someone's side: keep steering to the moving
## flank point, then attack. Returns false if the squad isn't flanking.
func _steer_flank(s: Squad) -> bool:
	if not s.has_meta("init_target"):
		return false
	var e = s.get_meta("init_target")
	if not is_instance_valid(e) or e.routing or s.engaged_with != null:
		_cancel_initiative(s)
		return true
	var point := _flank_point(s, e)
	if s.global_position.distance_to(point) < FLANK_ARRIVE:
		_cancel_initiative(s)
		s.attack(e)
	else:
		s.move_to(point)
	return true


func _is_idle(s: Squad) -> bool:
	if s.get_meta("hold", false) or s.engaged_with != null or s.attack_target != null:
		return false
	if s.global_position.distance_to(s.target_position) > 25.0:
		return false # still walking somewhere you sent it
	for o in pending:
		if o.squad == s:
			return false
	for o in orders:
		if not o.fired and o.squad == s:
			return false # an ambush waiting for its trigger stays hidden
	return true


## The closest foe that is in melee with one of `s`'s allies near `s`.
func _enemy_fighting_near(s: Squad, radius: float = INITIATIVE_RADIUS) -> Squad:
	var best: Squad = null
	var best_d := radius
	for ally in squads:
		if ally.team != s.team or ally == s or ally.routing or ally.engaged_with == null:
			continue
		if not is_instance_valid(ally.engaged_with) or ally.engaged_with.routing:
			continue
		var d := s.global_position.distance_to(ally.global_position)
		if d < best_d:
			best_d = d
			best = ally.engaged_with
	return best


## Beside the enemy, on the side nearest to us, a little behind its front.
func _flank_point(s: Squad, e: Squad) -> Vector2:
	var forward := Vector2.RIGHT.rotated(e.rotation)
	var side := forward.orthogonal()
	if (s.center() - e.center()).dot(side) < 0.0:
		side = -side
	return e.center() + side * (e.radius() + s.radius() + 6.0) - forward * 8.0


func _cancel_initiative(s: Squad) -> void:
	if s.has_meta("init_target"):
		s.remove_meta("init_target")


# --- Drawing ---------------------------------------------------------------

## Text with a dark outline so it reads on any part of the field.
func _text(ci: CanvasItem, pos: Vector2, text: String, size: int, c: Color,
		align := HORIZONTAL_ALIGNMENT_CENTER, width := 160.0) -> void:
	var font := ThemeDB.fallback_font
	# The text box is given in world units (`pos` = its left end, `width`
	# long). Pin it at the point its alignment hangs from (middle for centred,
	# right end for right-aligned), so it stays put when its size changes.
	var w := maxf(width, 0.0)
	var anchor := pos
	var start := Vector2.ZERO
	if width > 0.0 and align == HORIZONTAL_ALIGNMENT_CENTER:
		anchor = pos + Vector2(w / 2.0, 0)
		start = Vector2(-w / 2.0, 0)
	elif width > 0.0 and align == HORIZONTAL_ALIGNMENT_RIGHT:
		anchor = pos + Vector2(w, 0)
		start = Vector2(-w, 0)
	# Text stands upright (undo the camera's vertical squash) and keeps the
	# same size on screen whatever the zoom
	ci.draw_set_transform(anchor, 0.0, View.upright_scale() / _cam_zoom)
	ci.draw_string_outline(font, start, text, align, width, size, 4, Color(0, 0, 0, 0.65 * c.a))
	ci.draw_string(font, start, text, align, width, size, c)
	ci.draw_set_transform(Vector2.ZERO, 0.0)


## A dashed rectangle outline.
func _dashed_rect(ci: CanvasItem, r: Rect2, c: Color, width := 1.5) -> void:
	ci.draw_dashed_line(r.position, Vector2(r.end.x, r.position.y), c, width, 8.0)
	ci.draw_dashed_line(Vector2(r.end.x, r.position.y), r.end, c, width, 8.0)
	ci.draw_dashed_line(r.end, Vector2(r.position.x, r.end.y), c, width, 8.0)
	ci.draw_dashed_line(Vector2(r.position.x, r.end.y), r.position, c, width, 8.0)


# Ground level: under the squads
func _draw() -> void:
	# Deployment area (planning only)
	if phase == Phase.PLANNING:
		draw_rect(DEPLOY_ZONE, Color(PLAYER_COLOR, 0.08), true)
		_dashed_rect(self, DEPLOY_ZONE, Color(PLAYER_COLOR.lightened(0.3), 0.75), 2.0)
		_text(self, DEPLOY_ZONE.position + Vector2(10, DEPLOY_ZONE.size.y - 12), "DEPLOYMENT AREA", 13,
			Color(PLAYER_COLOR.lightened(0.4), 0.9), HORIZONTAL_ALIGNMENT_LEFT, -1)

	for o in objectives:
		_draw_objective(o)

	# Trigger zones
	for i in zones.size():
		var z := zones[i]
		draw_rect(z, Color(ZONE_COLOR, 0.13), true)
		_dashed_rect(self, z, Color(ZONE_COLOR, 0.85), 1.5)
		_text(self, z.position + Vector2(8, 18), "ZONE %d" % (i + 1), 12, Color(ZONE_COLOR.lightened(0.3), 0.95),
			HORIZONTAL_ALIGNMENT_LEFT, -1)

	# Planned orders: a dashed line from each squad to its zone, with an arrowhead
	for order in orders:
		if order.fired or not is_instance_valid(order.squad):
			continue
		var s: Squad = order.squad
		var c: Color = ATTACK_COLOR if order.action == Action.ATTACK else RETREAT_COLOR
		var to: Vector2 = order.zone.get_center()
		draw_dashed_line(s.global_position, to, Color(c, 0.75), 2.0, 8.0)
		var dir := (to - s.global_position).normalized()
		draw_colored_polygon(PackedVector2Array([to, to - dir.rotated(0.45) * 12.0, to - dir.rotated(-0.45) * 12.0]), Color(c, 0.85))


## A cluster of houses on a ground circle; a ring fills up as it burns.
func _draw_objective(o: Dictionary) -> void:
	var p: Vector2 = o.pos
	var lost: bool = o.lost
	draw_circle(p, OBJ_RADIUS, Color(0.1, 0.07, 0.04, 0.35) if lost else Color(OBJ_COLOR, 0.1))
	draw_arc(p, OBJ_RADIUS, 0, TAU, 48, Color(OBJ_COLOR, 0.55) if not lost else Color(0.3, 0.25, 0.2, 0.6), 2.0)
	if o.progress > 0.0 and not lost:
		draw_arc(p, OBJ_RADIUS, -PI / 2, -PI / 2 + TAU * o.progress, 48, Color(1.0, 0.4, 0.2, 0.95), 5.0)
	# Houses, upright
	var t := Time.get_ticks_msec() / 1000.0
	var houses := [Vector2(-22, -6), Vector2(14, -14), Vector2(4, 12)]
	for i in houses.size():
		var h: Vector2 = p + houses[i]
		draw_set_transform(h, 0.0, View.upright_scale())
		var wall := Color(0.25, 0.22, 0.2) if lost else Color(0.78, 0.68, 0.5)
		var roof := Color(0.15, 0.13, 0.12) if lost else Color(0.6, 0.3, 0.22)
		draw_rect(Rect2(-9, -12, 18, 12), wall)
		draw_colored_polygon(PackedVector2Array([Vector2(-12, -12), Vector2(0, -22), Vector2(12, -12)]), roof)
		var on_fire: bool = (not lost and o.progress > 0.15 * (i + 1)) or (lost and i == 0)
		if on_fire:
			var f := 4.0 + sin(t * 9.0 + i * 2.0) * 2.0
			draw_colored_polygon(PackedVector2Array([Vector2(-5, -20), Vector2(0, -28 - f), Vector2(5, -20)]), Color(1.0, 0.55, 0.15, 0.9))
			draw_circle(Vector2(sin(t + i) * 4.0, -34 - f - fmod(t * 8.0, 10.0)), 4.0, Color(0.3, 0.3, 0.3, 0.35))
	draw_set_transform(Vector2.ZERO)
	var label: String = o.name + ("  (burned)" if lost else "")
	_text(self, p + Vector2(-100, OBJ_RADIUS + 18.0), label, 12,
		Color(0.7, 0.6, 0.5, 0.9) if lost else Color(OBJ_COLOR, 0.95), HORIZONTAL_ALIGNMENT_CENTER, 200)


# Overlay: above the squads (labels, previews, messengers)
func _draw_overlay() -> void:
	var o2 := overlay

	# Right-drag preview: where the squads go and which way they'll face
	if _rdragging and _rdrag_start.distance_to(_rdrag_end) >= DRAG_THRESHOLD:
		var dir := (_rdrag_end - _rdrag_start).normalized()
		var tip := _rdrag_start + dir * maxf(40.0, _rdrag_start.distance_to(_rdrag_end))
		var g := Color(0.6, 1.0, 0.6, 0.9)
		o2.draw_line(_rdrag_start, tip, g, 2.0)
		o2.draw_colored_polygon(PackedVector2Array([tip + dir * 6.0, tip - dir.rotated(0.5) * 10.0, tip - dir.rotated(-0.5) * 10.0]), g)
		o2.draw_line(_rdrag_start - dir.orthogonal() * 40.0, _rdrag_start + dir.orthogonal() * 40.0, Color(g, 0.6), 3.0)

	# Messengers on their way: a rider from the Commander to the squad
	for o in pending:
		if not is_instance_valid(o.squad):
			continue
		var s: Squad = o.squad
		var from := commander.global_position if is_instance_valid(commander) else s.global_position
		var progress := 1.0 - float(o.left) / float(o.total)
		var rider := from.lerp(s.global_position, progress)
		o2.draw_dashed_line(from, s.global_position, Color(1, 1, 1, 0.18), 1.0, 5.0)
		o2.draw_circle(rider + Vector2(1, 1), 4.5, Color(0, 0, 0, 0.35))
		o2.draw_circle(rider, 4.5, Color(0.95, 0.92, 0.8))
		o2.draw_circle(rider, 2.2, COMMANDER_COLOR)
		var dest: Vector2 = o.pos if o.kind == "move" else (o.enemy.global_position if is_instance_valid(o.enemy) else s.global_position)
		o2.draw_dashed_line(s.global_position, dest, Color(1, 1, 1, 0.3), 1.0, 4.0)
		_text(o2, s.global_position + Vector2(-140, 4), "order in %.1fs" % o.left, 12, Color(1, 1, 1, 0.9),
			HORIZONTAL_ALIGNMENT_RIGHT, 110)

	# Labels under squads: enemy role (intel); ours only when it matters
	var hovered := _squad_at(get_global_mouse_position(), 0)
	for s in squads:
		if s.routing:
			continue
		var under := s.center() + Vector2(0, s.radius() + 28.0)
		if s.team == 1:
			# Scouted roles always; "unknown" only while planning (in battle it's just clutter)
			var scouted: bool = s.get_meta("scouted", false)
			if scouted or phase == Phase.PLANNING:
				var role := String(s.get_meta("role", "line")).to_upper() if scouted else "UNKNOWN"
				_text(o2, under + Vector2(-80, 0), role, 11, Color(1.0, 0.72, 0.68, 0.95))
			continue
		if s.is_commander:
			if phase == Phase.PLANNING or s.selected or s == hovered:
				_text(o2, under + Vector2(-80, 0), "COMMANDER", 11, Color(COMMANDER_COLOR, 0.95))
			continue
		var tags := []
		var c := Color(0.85, 0.9, 1.0, 0.95)
		if s.rallying:
			_text(o2, under + Vector2(-110, 0), "RALLYING", 11, Color(COMMANDER_COLOR, 0.95), HORIZONTAL_ALIGNMENT_CENTER, 220)
			continue
		if s.is_overloaded():
			tags.append("OVERLOADED %d%%" % roundi(s.efficiency() * 100))
			c = Color(1.0, 0.65, 0.35)
		if s.withdrawing > 0.0:
			tags.append("WITHDRAWING")
			c = Color(1.0, 0.85, 0.5)
		if s.get_meta("hold", false):
			tags.append("HOLD")
		elif s.has_meta("init_target"):
			tags.append("FLANKING")
			c = Color(0.6, 1.0, 0.55)
		for order in orders:
			if not order.fired and order.squad == s:
				tags.append("AMBUSH" if order.action == Action.ATTACK else "WILL RETREAT")
		var show_count := s.selected or s == hovered
		if tags.is_empty() and not show_count:
			continue
		var who_leads := s.leader.name + "  " if s.leader != null else ""
		var text := "%s%d / %d" % [who_leads, s.soldier_count, s.command]
		if not tags.is_empty():
			text = text + "  " + "  ".join(tags) if show_count else "  ".join(tags)
		_text(o2, under + Vector2(-110, 0), text, 11, c, HORIZONTAL_ALIGNMENT_CENTER, 220)

	# Floating messages (scouting, rallying)
	for p in _popups:
		var rise := (POPUP_TIME - float(p.left)) * 15.0
		if p.has("pos"):
			_text(o2, p.pos + Vector2(-130, -110.0 - rise), p.text, 15,
				Color(1.0, 0.6, 0.4, clampf(p.left, 0.0, 1.0)), HORIZONTAL_ALIGNMENT_CENTER, 260)
			continue
		if not is_instance_valid(p.squad):
			continue
		var ps: Squad = p.squad
		_text(o2, ps.center() + Vector2(-110, -ps.radius() - 72.0 - rise), p.text, 14,
			Color(COMMANDER_COLOR.lightened(0.2), clampf(p.left, 0.0, 1.0)), HORIZONTAL_ALIGNMENT_CENTER, 220)

	# Selection box or zone being drawn
	if _dragging and _drag_start.distance_to(_drag_end) >= DRAG_THRESHOLD:
		var r := Rect2(_drag_start, _drag_end - _drag_start).abs()
		var c2 := ZONE_COLOR if _zone_mode else BOX_COLOR
		o2.draw_rect(r, Color(c2, 0.12), true)
		_dashed_rect(o2, r, Color(c2, 0.9), 1.5)
