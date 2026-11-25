class_name SquadCard
extends Control
## One card in the bar at the bottom of the screen: a squad at a glance, and
## a sure way to select it in the middle of a fight.

signal picked(card: SquadCard, add: bool) # click (shift = add to selection)
signal focus_requested(card: SquadCard) # double-click: move the camera there

const SIZE := Vector2(168, 70)

var squad: Squad
var hotkey := 1
var title := ""
var color := Color.WHITE
var status := "" # set by the battle each frame
var status_color := Color(0.8, 0.8, 0.8)


func _init() -> void:
	custom_minimum_size = SIZE
	size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP # clicks on a card never reach the field


func is_gone() -> bool:
	return squad == null or not is_instance_valid(squad) or squad.routing or squad.rallying


func _process(_delta: float) -> void:
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if event.double_click:
			focus_requested.emit(self)
		else:
			picked.emit(self, event.shift_pressed)
		accept_event()


func _star(c: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	for k in 10:
		var r := 4.5 if k % 2 == 0 else 2.0
		pts.append(c + Vector2.UP.rotated(k * TAU / 10.0) * r)
	draw_colored_polygon(pts, col)


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var alive := squad != null and is_instance_valid(squad)
	var gone := is_gone()
	var sel := alive and squad.selected
	var hover := get_global_rect().has_point(get_viewport().get_mouse_position())

	# Card body
	var bg := Color(0.09, 0.10, 0.09, 0.9)
	if hover and not gone:
		bg = Color(0.14, 0.15, 0.13, 0.95)
	draw_rect(Rect2(Vector2.ZERO, SIZE), bg, true)
	var border := Color(1.0, 0.9, 0.35) if sel else Color(0.85, 0.75, 0.45, 0.45)
	draw_rect(Rect2(Vector2.ZERO, SIZE), border, false, 2.0 if sel else 1.0)

	# Banner stripe in the squad's colour
	var c := color if not gone else color.lerp(Color(0.4, 0.4, 0.4), 0.7)
	draw_rect(Rect2(Vector2(0, 0), Vector2(6, SIZE.y)), c, true)
	draw_colored_polygon(PackedVector2Array([Vector2(12, 8), Vector2(24, 11), Vector2(12, 15)]), c)
	draw_line(Vector2(12, 8), Vector2(12, 22), Color(0.6, 0.48, 0.32), 1.5)

	var ink := Color(0.95, 0.92, 0.82) if not gone else Color(0.55, 0.55, 0.52)
	draw_string(font, Vector2(30, 18), title, HORIZONTAL_ALIGNMENT_LEFT, SIZE.x - 52, 13, ink)
	draw_string(font, Vector2(SIZE.x - 18, 16), str(hotkey), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.75, 0.7, 0.55))

	# Familiarity stars: 0 green, 1 drilled (25+), 2 seasoned (50+), 3 veteran (75+)
	if squad != null and is_instance_valid(squad):
		var stars := int(squad.familiarity() / 25.0)
		for k in 3:
			var lit := k < stars and not is_gone()
			_star(Vector2(19 + k * 11, 58), Color(0.95, 0.8, 0.35) if lit else Color(0.35, 0.35, 0.32))

	if not alive:
		draw_string(font, Vector2(14, 44), "GONE", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 0.55, 0.5))
		return

	# Soldiers / Command (orange when overloaded)
	var count := "%d / %d" % [squad.soldier_count, squad.command]
	var bonus := floori(squad.command_effective() - squad.command)
	if bonus > 0:
		count += "+%d" % bonus # veterans are easier to lead
	var count_col := Color(1.0, 0.65, 0.35) if squad.is_overloaded() and not gone else ink
	draw_string(font, Vector2(14, 38), count, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, count_col)
	draw_string(font, Vector2(78, 38), status, HORIZONTAL_ALIGNMENT_LEFT, SIZE.x - 82, 11, status_color if not gone else Color(0.7, 0.5, 0.45))

	# Morale bar
	var frac := clampf(squad.morale / Squad.MAX_MORALE, 0.0, 1.0)
	var bar_col := Color(0.45, 0.85, 0.4)
	if frac < 0.5:
		bar_col = Color(0.95, 0.75, 0.25)
	if frac < 0.25:
		bar_col = Color(0.95, 0.32, 0.28)
	if gone:
		bar_col = bar_col.lerp(Color(0.4, 0.4, 0.4), 0.6)
	draw_rect(Rect2(Vector2(54, 54), Vector2(SIZE.x - 66, 8)), Color(0, 0, 0, 0.6), true)
	draw_rect(Rect2(Vector2(55, 55), Vector2((SIZE.x - 68) * frac, 6)), bar_col, true)
