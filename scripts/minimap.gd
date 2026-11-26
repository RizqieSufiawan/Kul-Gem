extends Control
## Corner map for the 3D view: the field, the villages, every squad you can
## see, and the patch of ground the camera is looking at. Left-click or drag
## on it to look there. M hides it.

const WIDTH := 210.0

var b # the battle
var v # its 3D view
var _tex: ImageTexture
var _dragging := false


func _init(battle, view) -> void:
	b = battle
	v = view


func _ready() -> void:
	size = Vector2(WIDTH, roundf(WIDTH * View.MAP_SIZE.y / View.MAP_SIZE.x))
	custom_minimum_size = size
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = ""
	_tex = ImageTexture.create_from_image(_bake())


func _process(_delta: float) -> void:
	if visible:
		queue_redraw()


func _k() -> float:
	return size.x / View.MAP_SIZE.x


func _at(p: Vector2) -> Vector2:
	return p * _k()


## The field painted once: grass shaded by height, forests, road, stream, crossings.
func _bake() -> Image:
	var w := int(size.x)
	var h := int(size.y)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var p := Vector2(x + 0.5, y + 0.5) / _k()
			var c := Color(0.34, 0.5, 0.25).lerp(Color(0.58, 0.64, 0.36), clampf(Terrain.height(p), 0.0, 1.0))
			if Terrain.in_forest(p):
				c = Color(0.17, 0.32, 0.17)
			if Terrain.on_road(p):
				c = Color(0.62, 0.52, 0.36)
			if Terrain.in_stream(p):
				c = Color(0.45, 0.62, 0.78) if Terrain.on_ford(p) else Color(0.24, 0.44, 0.7)
			if Terrain.on_bridge(p):
				c = Color(0.52, 0.36, 0.22)
			img.set_pixel(x, y, c)
	return img


func _draw() -> void:
	var k := _k()
	draw_texture(_tex, Vector2.ZERO)
	if b.phase == b.Phase.PLANNING:
		var dz: Rect2 = b.DEPLOY_ZONE
		draw_rect(Rect2(dz.position * k, dz.size * k), Color(b.PLAYER_COLOR, 0.16))
		draw_rect(Rect2(dz.position * k, dz.size * k), Color(b.PLAYER_COLOR.lightened(0.3), 0.7), false, 1.0)
	for z: Rect2 in b.zones:
		draw_rect(Rect2(z.position * k, z.size * k), Color(b.ZONE_COLOR, 0.3))
	for o in b.objectives:
		var col := Color(0.25, 0.22, 0.2, 0.9) if o.lost else Color(b.OBJ_COLOR, 0.95)
		draw_arc(_at(o.pos), maxf(b.OBJ_RADIUS * k, 4.0), 0.0, TAU, 20, col, 1.5)
		if o.progress > 0.0 and not o.lost:
			draw_arc(_at(o.pos), maxf(b.OBJ_RADIUS * k, 4.0) + 2.0, -PI / 2.0, -PI / 2.0 + TAU * o.progress, 16, Color(1.0, 0.4, 0.2), 2.0)
		if not o.lost and (o.get("threat", false) or o.progress > 0.0):
			var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 160.0)
			draw_arc(_at(o.pos), maxf(b.OBJ_RADIUS * k, 4.0) + 4.0 + pulse * 3.0, 0.0, TAU, 20, Color(1.0, 0.3, 0.2, 0.5 + 0.5 * pulse), 1.5)
			var r = o.get("raider")
			if r != null and is_instance_valid(r):
				draw_dashed_line(_at(r.center()), _at(o.pos), Color(1.0, 0.35, 0.25, 0.9), 1.2, 4.0)

	# Squads: a little block, the way it faces
	for s in b.squads:
		if not is_instance_valid(s) or s._m.is_empty():
			continue
		var p := _at(s.center())
		if s.concealed:
			draw_circle(p, 3.0, Color(0.85, 0.85, 0.9, 0.55))
			continue
		var hs: Vector2 = s.half_size() * k
		hs = Vector2(maxf(hs.x, 2.5), maxf(hs.y, 1.5))
		var c: Color = s.color
		if s.routing:
			c = Color(c.darkened(0.35), 0.6)
		draw_set_transform(p, s.rotation)
		var r := Rect2(Vector2(-hs.y, -hs.x), Vector2(hs.y * 2.0, hs.x * 2.0))
		draw_rect(r, c)
		draw_line(Vector2(hs.y, -hs.x), Vector2(hs.y, hs.x), c.lightened(0.5), 1.5) # the front
		if s.selected:
			draw_rect(r.grow(1.5), Color(1.0, 0.9, 0.35), false, 1.2)
		elif s.is_commander:
			draw_rect(r.grow(1.0), Color(b.COMMANDER_COLOR, 0.9), false, 1.0)
		draw_set_transform(Vector2.ZERO, 0.0)

	# Where the camera looks
	var vp := get_viewport_rect().size
	var pts := PackedVector2Array()
	for corner in [Vector2(0, 40), Vector2(vp.x, 40), vp, Vector2(0, vp.y)]:
		pts.append(_at(v.ground_hit(corner)))
	draw_colored_polygon(pts, Color(1, 1, 1, 0.1))
	pts.append(pts[0])
	draw_polyline(pts, Color(1, 1, 1, 0.9), 1.2)
	draw_circle(_at(Vector2(v.target.x, v.target.z) / v.S), 2.0, Color(1, 1, 1, 0.9))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
			if event.pressed:
				_look(event.position)
		accept_event() # nothing on the minimap reaches the field
	elif event is InputEventMouseMotion and _dragging:
		_look(event.position)
		accept_event()


func _look(local: Vector2) -> void:
	v.following = false
	var p := local / _k()
	v.target_goal = Vector3(p.x * v.S, 0.0, p.y * v.S)
	v._clamp_goal()
