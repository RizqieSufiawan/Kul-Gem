extends CanvasLayer
## Autoload "Guide": everything the player needs explained, in plain words.
##   - The guide book: F1 anywhere (Esc or F1 closes). Pauses the game.
##   - Tips: a small card the first time something happens (a flank, a raid,
##     an overloaded squad...). Each tip shows once, remembered between runs.
## Call Guide.tip("id") from the game; the tip texts live in TIPS below.

const SAVE_PATH := "user://tips.cfg"
const GOLD := Color(0.95, 0.8, 0.3)
const INK := Color(0.93, 0.91, 0.84)
const QUIET := Color(0.68, 0.66, 0.58)
const KEY_COL := "#bfd9ff" # keys and buttons in the text
const TERM_COL := "#f2cc4d" # game words

var is_open := false
var _was_paused := false
var _book: Control
var _topics: VBoxContainer
var _title: Label
var _body: RichTextLabel
var _current := ""
var _topic_buttons := {}

var _tip_card: PanelContainer
var _tip_title: Label
var _tip_body: Label
var _tip_more: Button
var _tip_queue: Array[String] = []
var _tip_queued_at := {} # id -> when it was queued (ms): stale ones are dropped
var _tip_showing := ""
var _tip_shown_at := 0
const TIP_STALE_MS := 20000 # a tip still waiting after this no longer fits the moment
const TIP_MIN_MS := 7000 # a newer tip replaces the shown one after this long
var _seen := {}
var tips_on := true


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load()
	_build_book()
	_build_tip_card()


# --- Pages ---------------------------------------------------------------------

func _k(key: String) -> String:
	return "[color=%s][b]%s[/b][/color]" % [KEY_COL, key]


func _t(term: String) -> String:
	return "[color=%s]%s[/color]" % [TERM_COL, term]


## [id, title, bbcode text]
func _pages() -> Array:
	return [
		["goal", "What is this game?", """You lead a [b]small village army[/b] against a bigger enemy. You can't win by being stronger, so you win by [b]planning better[/b]: good positions, flank attacks, ambushes and keeping your men from breaking.

%s  every enemy squad is destroyed or running away.

%s
•  your %s breaks or is killed, [b]or[/b]
•  the enemy burns [b]both[/b] places of the village.

Between battles you go to %s. Your soldiers are real people with names: the dead are gone for good, the wounded need time (or a healer), and survivors get better every battle.

Press %s any time to open this guide. %s shows all keys.""" % [_t("You win when"), _t("You lose when"), _t("Commander"), _t("camp"), _k("F1"), _k("Tab")]],

		["steps", "A battle, step by step", """[b]1. Planning[/b]  (time is frozen)
•  Your squads must stand inside the [b]blue area[/b]. Select a squad and %s to place it. %s to also choose which way it faces.
•  Spend your 2 %s: %s over an enemy squad shows what it is and how big.
•  Draw %s and give squads %s (see "Plans").
•  Press %s to start.

[b]2. Battle[/b]  (time runs)
•  %s an enemy to attack it, or the ground to move there.
•  %s pauses. You can still give orders while paused.
•  Watch the %s bars. A squad that runs out of morale breaks and flees.

[b]3. After the battle[/b]
•  The roll call shows who died, who is wounded and who came back.
•  Then you go to %s to heal, recruit and reorganise.""" % [_k("Right-click"), _k("Shift + right-drag"), _t("scouts"), _k("Shift+S"), _t("zones"), _t("ambush orders"), _k("Enter"), _k("Right-click"), _k("Space"), _t("morale"), _t("camp")]],

		["controls", "Camera and controls", """[b]Camera[/b]
•  %s or arrows: move.   %s: turn left / right.
•  %s: pull the map.
•  %s: zoom, from the whole map down to eye level.
•  %s: turn and tilt.   %s: reset.
•  [b]Minimap[/b] (top right): click or drag to look there. %s hides it.
•  %s: the camera follows the selected squad(s).   %s: 3D / 2D.

[b]Selecting[/b]
•  %s a squad, or drag a box around several.   %s adds to the selection.
•  The cards at the bottom: click to select, double-click to follow.
•  %s select a squad; press the number twice to follow it.

[b]Orders[/b]
•  %s ground: move.   %s enemy: attack.
•  %s: move and face the way you dragged.
•  %s: hold (stay put, no initiative).   %s: pause.""" % [_k("W A S D"), _k("Q / E"), _k("Hold right-click + drag"), _k("Mouse wheel"), _k("Middle-drag"), _k("Home"), _k("M"), _k("F"), _k("F3"), _k("Left-click"), _k("Shift"), _k("1 - 9"), _k("Right-click"), _k("Right-click"), _k("Shift + right-drag"), _k("H"), _k("Space")]],

		["squads", "Reading a squad card", """Each card at the bottom is one of your squads.

•  [b]Name[/b]  the leader. The small number is its hotkey.
•  %s  soldiers / the leader's %s. "+1" is a bonus from men who know their leader well. [color=#ffa65a]Orange[/color] means overloaded.
•  [b]Word on the right[/b]  what it is doing now (hover the card to see what it means).
•  %s  how well the men know their leader (familiarity): ☆☆☆ new, ★☆☆ drilled, ★★☆ seasoned, ★★★ veteran.
•  [b]Bar[/b]  %s. Green is fine, yellow is shaken, red is about to break.

Hover a card for the leader's stats and traits. Hover one of your soldiers on the field to see his name and record.""" % [_t("\"15 / 15+1\""), _t("Command"), _t("Stars"), _t("morale")]],

		["command", "Command and overload", """Every leader has a %s: how many soldiers he can lead well.

If a squad has [b]more soldiers than its Command[/b], it is %s (the card number turns orange and the field shows e.g. "OVERLOADED 80%%"). The percentage is how well it works:
•  its men hit softer and get hurt more,
•  it is slower to obey orders,
•  it breaks more easily.

Example: Mira Holt leads 25 men but her Command is 15. More men is still more spears, but not as many as it looks.

[b]How to fix it:[/b] in camp, move one of her groups to a leader who has room. Overload also goes away as the squad loses men. Some traits change how much overload hurts (Disciplinarian: less, Small-unit specialist: more).""" % [_t("Command"), _t("overloaded")]],

		["morale", "Morale and breaking", """%s is a squad's nerve: the bar above it and on its card.

[b]It goes down when[/b]
•  its men fall,
•  it is fighting in melee (slowly),
•  it is hit in the side or rear (fast!),
•  it pulls out of a fight (withdraw),
•  a squad next to it breaks.

[b]It comes back[/b]  out of combat, near the %s (even in melee), and near an [i]Inspiring[/i] leader.

When morale drops under 15 (5 for a [i]Steady[/i] leader) the squad is %s: it runs and ignores orders. If it reaches the Commander's circle it %s: it turns back and joins the Commander's squad.

Veterans (more stars) lose less morale per casualty. So does a leader with high Charisma.""" % [_t("Morale"), _t("Commander"), _t("BROKEN"), _t("rallies")]],

		["fighting", "Fighting and flanks", """Fights happen man by man. Squads keep their block: the [b]front rank[/b] steps out and fights, the [b]second rank[/b] stabs over their shoulders (half damage), the rest wait their turn.

[b]Where you hit matters most:[/b]
•  From the front: normal.
•  From the %s: ×1.5 damage and easier to hit.
•  From the %s: ×2.5 damage and much easier to hit.

A squad hit in the side or rear also loses morale fast. You'll see %s or %s above it and an orange arc on the side being hit.

A squad locked in melee [b]cannot turn[/b] to face a new attacker. That is how you win: hold an enemy with one squad, then hit its side with another.

Your idle squads do this on their own (%s) when a friend nearby is fighting. Press %s if you want a squad to stay where it is.""" % [_t("side"), _t("rear"), _t("FLANKED"), _t("REAR!"), _t("FLANKING"), _k("H")]],

		["commander", "The Commander and messengers", """The gold squad is your %s and her bodyguard. They are elite: they hit twice as hard and take half the damage.

[b]If the Commander breaks or falls, you lose the battle.[/b] She only breaks when her guard is almost gone.

[b]The circle around her[/b]
•  Orders to squads inside it are instant (she shouts them).
•  Squads inside slowly regain morale, even while fighting.
•  Broken squads run to it and rally.

[b]Squads outside the circle[/b] get orders by %s: a rider carries the order (you see him ride, and the card says %s). Delay goes up with distance and overload, and down with the leader's Tactics and the men's familiarity. A Hothead leader argues first.

Orders you plan before the battle (ambushes) are always instant.""" % [_t("Commander"), _t("messenger"), _t("ORDER EN ROUTE")]],

		["plans", "Plans: zones and ambushes", """Before the battle you can set traps.

1.  Press %s, then drag on the map to draw a %s (purple box).
2.  Select one or more squads.
3.  Point the mouse at the zone and press:
     •  %s  %s: they attack the first enemy who enters the zone.
     •  %s  %s: they fall back when an enemy enters.
4.  %s over a zone deletes it.

Planned orders fire [b]instantly[/b], no messenger. An ambush also gives a %s: the enemy loses morale when it is hit by surprise (twice as much with an [i]Ambusher[/i] leader).

Good trick: hide a squad in a forest next to the zone. The enemy can't see it until it is close.""" % [_k("Z"), _t("zone"), _k("Shift+A"), _t("AMBUSH"), _k("R"), _t("WILL RETREAT"), _k("X"), _t("surprise shock")]],

		["enemy", "The enemy and scouting", """The enemy has [b]5 squads[/b] (about 75 men), but their jobs change every battle:
•  %s  hold the front and march at your army.
•  %s  swing wide around your edges to hit your side and rear.
•  %s  waits behind and joins where a friend is losing.

Before the battle you don't know which is which (%s). You have [b]2 scouts[/b]: %s over an enemy squad shows its job and size.

Enemy squads you can't see well show as grey fog with a "?".

Some enemy squads go %s: they skip your army and try to burn the village (see "Village").""" % [_t("LINE"), _t("FLANK"), _t("RESERVE"), _t("UNKNOWN"), _k("Shift+S"), _t("raiding")]],

		["village", "Protecting the village", """There are two village places on your side of the map (gold circles, e.g. "North farms").

•  An enemy squad standing in a place with [b]none of your squads near[/b] starts burning it. The ring fills up: about [b]30 seconds[/b] to burn.
•  When raiders set off for a place you get a warning, a red line shows their path, and a red arrow at the edge of the screen points to the place. Smoke rises as it burns: you can see it from anywhere.
•  Send any squad there: as soon as one of yours is close, the burning stops.
•  Each burned place costs [b]30 gold[/b] and [b]4 volunteers[/b].
•  [b]If both burn, you lose the battle.[/b]

Raiders go for places they think are unguarded. A squad hidden in a forest doesn't count as a guard to them, so they may walk right into it.""" ],

		["terrain", "Terrain", """•  %s  hides your squad (unless an enemy is very close), gives cover (you take less damage), but you move slowly.
•  %s  fighting downhill hits harder.
•  %s  can only be crossed at the [b]bridge[/b] or the two [b]fords[/b] (shallow light-blue spots). Squads in water move slowly and fight badly.
•  %s  a bit faster.

The bridge and the fords are the natural chokepoints: a few men can hold them against many.""" % [_t("Forest"), _t("Hill"), _t("Stream"), _t("Road")]],

		["orders", "Hold, withdraw, initiative", """%s  The squad stays exactly where you put it and won't go help others by itself. Press %s again to release it.

%s  Your idle squads help friends fighting nearby by swinging round to the enemy's side (card says FLANKING). Your own order always overrides this.

%s  If you order a squad that is fighting to move away, it pulls out: it moves fast for a moment and the enemy needs a moment to follow, but turning your back costs morale.

%s  A squad that breaks runs for the Commander. If it reaches her circle it rallies and joins her squad.""" % [_t("HOLD (H)"), _k("H"), _t("Initiative"), _t("Withdrawing"), _t("Rallying")]],

		["camp", "Camp: between battles", """[b]Your soldiers[/b] live from battle to battle. Each leader has [b]groups[/b] of up to 10 men.

•  %s  Wounded men sit out 1–2 battles. %s (15 gold each) makes them fit for the next one. If you [b]lose[/b] a battle, half the wounded are left behind.
•  %s  Recruits who fight in the wounded men's places until they come back.
•  %s  New men from the village (10 gold each) fill empty places. %s are how many villagers are still willing.
•  %s  Spare soldiers with no group. They fill gaps for free.
•  %s  A new group of up to 10 for a leader.
•  %s  Give a group to another leader. The men lose some familiarity (less if the two leaders have a similar style).

[b]Gold[/b]  +120 for a victory (+40 for a defeat), +40 from the village, −1 per soldier for food and pay, −30 per burned place. If you can't pay, men desert.""" % [_t("Wounded"), _t("Treat"), _t("Stand-ins"), _t("Recruit"), _t("Volunteers"), _t("Reserves"), _t("Raise a new group"), _t("Move to another leader")]],

		["leaders", "Leaders: stats and traits", """[b]Stats[/b] (0–100)
•  %s  how many men the leader can lead well (see "Command and overload").
•  %s  the squad loses less morale when men fall.
•  %s  orders are obeyed faster; the squad notices fights further away.
•  %s  the men hit harder.

[b]Traits[/b]
%s

[b]Style[/b]  (cautious / aggressive, loose / strict, steady / mobile). Men moved between leaders of a similar style keep more of their familiarity.""" % [_t("CMD  Command"), _t("CHA  Charisma"), _t("TAC  Tactics"), _t("VAL  Valor"), _trait_lines()]],
	]


func _trait_lines() -> String:
	var lines: Array[String] = []
	for t in Leader.TRAIT_INFO:
		lines.append("•  %s  %s" % [_t(t), Leader.TRAIT_INFO[t]])
	return "\n".join(lines)


# --- The book -------------------------------------------------------------------

func _build_book() -> void:
	_book = Control.new()
	_book.size = Vector2(1280, 720)
	_book.mouse_filter = Control.MOUSE_FILTER_STOP
	_book.visible = false
	add_child(_book)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.size = Vector2(1280, 720)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_book.add_child(dim)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(Color(0.075, 0.085, 0.075, 0.97), Color(GOLD, 0.45), 10, 18))
	panel.position = Vector2(110, 50)
	panel.size = Vector2(1060, 620)
	panel.custom_minimum_size = panel.size
	_book.add_child(panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	panel.add_child(outer)

	var head := HBoxContainer.new()
	outer.add_child(head)
	head.add_child(_label("THIN LINE  ·  GUIDE", 13, GOLD))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(gap)
	head.add_child(_label("F1 or Esc to close  ·  the game is paused", 12, QUIET))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(row)

	# Topics down the left
	var left := ScrollContainer.new()
	left.custom_minimum_size = Vector2(230, 0)
	left.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	row.add_child(left)
	_topics = VBoxContainer.new()
	_topics.add_theme_constant_override("separation", 3)
	_topics.custom_minimum_size = Vector2(222, 0)
	left.add_child(_topics)
	for p in _pages():
		var b := Button.new()
		b.text = p[1]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 13)
		b.add_theme_stylebox_override("normal", _style(Color(1, 1, 1, 0.03), Color(0, 0, 0, 0), 5, 8))
		b.add_theme_stylebox_override("hover", _style(Color(1, 1, 1, 0.08), Color(0, 0, 0, 0), 5, 8))
		b.add_theme_stylebox_override("pressed", _style(Color(GOLD, 0.25), Color(GOLD, 0.6), 5, 8))
		b.add_theme_color_override("font_color", INK)
		b.add_theme_color_override("font_hover_color", Color.WHITE)
		var id: String = p[0]
		b.pressed.connect(func() -> void: show_topic(id))
		_topics.add_child(b)
		_topic_buttons[id] = b

	# The page
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 10)
	row.add_child(right)
	_title = _label("", 22, GOLD)
	right.add_child(_title)
	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.scroll_active = true
	_body.add_theme_font_size_override("normal_font_size", 15)
	_body.add_theme_font_size_override("bold_font_size", 15)
	_body.add_theme_font_size_override("italics_font_size", 15)
	_body.add_theme_color_override("default_color", INK)
	_body.add_theme_constant_override("line_separation", 4)
	right.add_child(_body)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 10)
	outer.add_child(foot)
	var tips_btn := _small_button("")
	tips_btn.text = "Tips: on" if tips_on else "Tips: off"
	tips_btn.pressed.connect(func() -> void:
		tips_on = not tips_on
		tips_btn.text = "Tips: on" if tips_on else "Tips: off"
		_save())
	foot.add_child(tips_btn)
	var again := _small_button("Show all tips again")
	again.pressed.connect(func() -> void:
		_seen.clear()
		tips_on = true
		tips_btn.text = "Tips: on"
		_save())
	foot.add_child(again)
	var g2 := Control.new()
	g2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(g2)
	var close := _small_button("Close   (F1)")
	close.pressed.connect(close_book)
	foot.add_child(close)


func show_topic(id: String) -> void:
	for p in _pages():
		if p[0] == id:
			_current = id
			_title.text = p[1]
			_body.text = p[2]
			_body.scroll_to_line(0)
	for k in _topic_buttons:
		var b: Button = _topic_buttons[k]
		b.add_theme_color_override("font_color", GOLD if k == _current else INK)
		b.add_theme_stylebox_override("normal", _style(Color(GOLD, 0.16) if k == _current else Color(1, 1, 1, 0.03), Color(0, 0, 0, 0), 5, 8))


func open(topic := "") -> void:
	if not is_open:
		_was_paused = get_tree().paused
		get_tree().paused = true
	is_open = true
	_book.visible = true
	_tip_card.visible = false
	show_topic(topic if topic != "" else (_current if _current != "" else "goal"))


func close_book() -> void:
	if not is_open:
		return
	is_open = false
	_book.visible = false
	get_tree().paused = _was_paused
	if _tip_showing != "":
		_tip_card.visible = true


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			if is_open:
				close_book()
			else:
				open()
			get_viewport().set_input_as_handled()
			return
		if is_open and event.keycode == KEY_ESCAPE:
			close_book()
			get_viewport().set_input_as_handled()
			return
	if is_open and event is InputEventKey:
		get_viewport().set_input_as_handled() # nothing reaches the game behind the book


# --- Tips -------------------------------------------------------------------------

## [title, text, guide topic]
const TIPS := {
	"welcome": ["Welcome, Commander",
		"The enemy has more men than you. Win by planning: good positions, hitting their sides, ambushes.\nPress F1 any time for the guide.", "goal"],
	"planning": ["Planning: time is frozen",
		"1. Click a squad (or its card below).\n2. Right-click inside the blue area to place it.\n3. Press Enter when you're ready to fight.", "steps"],
	"select": ["Squad selected",
		"Right-click to send it somewhere. Shift + right-drag also sets the way it faces. Hover its card to see what the numbers mean.", "squads"],
	"overload": ["This squad is overloaded",
		"It has more soldiers than its leader's Command. It fights and obeys worse (the % shows how well). Fix it in camp by moving a group to another leader.", "command"],
	"zone": ["Drawing a zone",
		"Drag on the map to draw a box. Then select squads, point at the box and press Shift+A (ambush) or R (retreat when an enemy enters).", "plans"],
	"scouted": ["Scouted",
		"Now you know this squad's job: LINE holds the front, FLANK goes round your side, RESERVE waits to help.", "enemy"],
	"battle": ["The battle has begun",
		"Right-click to give orders. Space pauses (orders still work while paused). Keep an eye on the morale bars.", "steps"],
	"messenger": ["Order sent by messenger",
		"This squad is outside the Commander's circle, so a rider carries the order: it takes a few seconds. Keep important squads close to her.", "commander"],
	"contact": ["Melee!",
		"Only the front ranks fight. A squad in melee can't turn. Hit an enemy that is busy fighting from its side or rear for big damage.", "fighting"],
	"flanked": ["Hit in the side!",
		"Attacks from the side (x1.5) and rear (x2.5) hurt much more and drain morale fast. Watch for the orange arc and FLANKED / REAR! tags.", "fighting"],
	"initiative": ["Your squad acts on its own",
		"FLANKING: an idle squad saw a friend fighting nearby and is going round to hit the enemy's side. Press H to make a squad hold its place instead.", "orders"],
	"raid": ["Raiders are going for the village!",
		"An enemy squad is heading for a village place (red line, and a red arrow at the edge of the screen). Send any squad there: it can't burn while one of yours is close. If both places burn, you lose.", "village"],
	"burned": ["A place burned",
		"It will cost 30 gold and 4 volunteers after the battle. If the other place burns too, the battle is lost.", "village"],
	"broken": ["A squad broke!",
		"Its morale ran out and it is running. If it reaches the Commander's circle, it rallies and joins her squad. Squads near a breaking one lose morale too.", "morale"],
	"withdraw": ["Pulling out of a fight",
		"The squad turns its back to get away: it costs morale, but the enemy needs a moment to follow.", "orders"],
	"hidden": ["Hidden in the forest",
		"The enemy can't see this squad until it comes close. Great for ambushes and for guarding the village unseen.", "terrain"],
	"camp": ["Camp",
		"Heal the wounded, fill the gaps with recruits, move groups between leaders. Hover anything to see what it does. Then press Next battle.", "camp"],
	"wounded": ["Wounded men",
		"They sit out 1-2 battles. Treat them (15 gold each) to have them back now, or hire stand-ins to fill their places.", "camp"],
}


func _build_tip_card() -> void:
	_tip_card = PanelContainer.new()
	_tip_card.add_theme_stylebox_override("panel", _style(Color(0.07, 0.08, 0.07, 0.94), Color(GOLD, 0.6), 8, 12))
	_tip_card.position = Vector2(12, 46)
	_tip_card.custom_minimum_size = Vector2(330, 0)
	_tip_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_tip_card.visible = false
	add_child(_tip_card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_tip_card.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var tag := _label("TIP", 10, Color(0.1, 0.08, 0.05))
	var sb := _style(GOLD, Color(0, 0, 0, 0), 3, 5)
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	tag.add_theme_stylebox_override("normal", sb)
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(tag)
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(6, 0)
	head.add_child(sp)
	_tip_title = _label("", 15, GOLD)
	head.add_child(_tip_title)
	_tip_body = _label("", 13, INK)
	_tip_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_body.custom_minimum_size = Vector2(306, 0)
	v.add_child(_tip_body)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	var ok := _small_button("Got it")
	ok.pressed.connect(_next_tip)
	row.add_child(ok)
	_tip_more = _small_button("More in the guide (F1)")
	_tip_more.pressed.connect(func() -> void:
		var topic: String = TIPS[_tip_showing][2] if TIPS.has(_tip_showing) else ""
		_next_tip()
		open(topic))
	row.add_child(_tip_more)
	var off := _small_button("No more tips")
	off.pressed.connect(func() -> void:
		tips_on = false
		_tip_queue.clear()
		_next_tip()
		_save())
	row.add_child(off)


## Where the tip card sits (each screen puts it where it covers the least).
func tip_at(pos: Vector2) -> void:
	_tip_card.position = pos


## Show tip `id` if it hasn't been seen yet (once per player, ever).
func tip(id: String) -> void:
	if not tips_on or not TIPS.has(id) or _seen.has(id) or id == _tip_showing or id in _tip_queue:
		return
	_tip_queue.append(id)
	_tip_queued_at[id] = Time.get_ticks_msec()
	# Nobody reading the shown one for a while (and time is running): move on
	var idle := Time.get_ticks_msec() - _tip_shown_at > TIP_MIN_MS and not get_tree().paused
	if _tip_showing == "" or idle:
		_next_tip()


func _next_tip() -> void:
	if _tip_showing != "":
		_seen[_tip_showing] = true
		_save()
	_tip_showing = ""
	_tip_card.visible = false
	while not _tip_queue.is_empty():
		var id: String = _tip_queue.pop_front()
		var waited: int = Time.get_ticks_msec() - int(_tip_queued_at.get(id, 0))
		if _seen.has(id) or waited > TIP_STALE_MS:
			continue # stale: not marked seen, so it can come again when it fits
		_tip_showing = id
		_tip_shown_at = Time.get_ticks_msec()
		_tip_title.text = TIPS[id][0]
		_tip_body.text = TIPS[id][1]
		_tip_card.reset_size()
		_tip_card.visible = not is_open
		Sound.play("ui_click")
		return


## Drop tips that only make sense in a scene we're leaving.
func clear_pending() -> void:
	_tip_queue.clear()
	if _tip_showing != "":
		_next_tip()


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	tips_on = cfg.get_value("tips", "on", true)
	for id in cfg.get_value("tips", "seen", []):
		_seen[id] = true


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("tips", "on", tips_on)
	cfg.set_value("tips", "seen", _seen.keys())
	cfg.save(SAVE_PATH)


# --- Little helpers ---------------------------------------------------------------------

func _style(bg: Color, border: Color, radius: int, margin: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1 if border.a > 0.0 else 0)
	s.set_corner_radius_all(radius)
	s.content_margin_left = margin
	s.content_margin_right = margin
	s.content_margin_top = margin * 0.6
	s.content_margin_bottom = margin * 0.6
	return s


func _label(text: String, size: int, c: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	return l


func _small_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_stylebox_override("normal", _style(Color(1, 1, 1, 0.07), Color(1, 1, 1, 0.12), 4, 8))
	b.add_theme_stylebox_override("hover", _style(Color(1, 1, 1, 0.14), Color(GOLD, 0.5), 4, 8))
	b.add_theme_stylebox_override("pressed", _style(Color(GOLD, 0.3), Color(GOLD, 0.7), 4, 8))
	b.add_theme_color_override("font_color", INK)
	return b
