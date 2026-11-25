extends "res://scripts/proto/view3d.gd"
## The real battle drawn in 3D. The battle is still simulated on the flat 2D
## map; this reads it every frame and draws it: terrain, soldiers, banners,
## the village places, trigger zones, planned orders, messengers and labels.
##
## Camera: arrow keys pan, wheel zoom, middle-drag orbit/tilt, Home reset.

const MAX_MEN := 480
const MAX_SQUADS := 24
const MAX_RIDERS := 16
const HOUSE_OFFSETS := [Vector2(-22, -6), Vector2(14, -14), Vector2(4, 12)]

var _poles: MultiMesh
var _flags: MultiMesh
var _riders: MultiMesh
var _houses: Array = [] # per objective: Array of { body, roof, flame }
var _house_mats := {}
var _last_pos := {} # Man -> where he stood last frame, to tell who's walking
var _gait := {} # Man -> walk cycle phase


func _init(the_battle) -> void:
	super(the_battle)


# --- Building ------------------------------------------------------------------

func _build_soldiers() -> void:
	var body := CapsuleMesh.new()
	body.radius = 0.17
	body.height = 0.58
	body.radial_segments = 8
	body.rings = 2
	var head := SphereMesh.new()
	head.radius = 0.13
	head.height = 0.26
	head.radial_segments = 8
	head.rings = 4
	var shield := CylinderMesh.new()
	shield.top_radius = 0.18
	shield.bottom_radius = 0.18
	shield.height = 0.05
	shield.radial_segments = 10
	var spear := CylinderMesh.new()
	spear.top_radius = 0.012
	spear.bottom_radius = 0.018
	spear.height = 1.25
	spear.radial_segments = 4
	_parts.body = _multimesh(body, MAX_MEN, _colored(0.8))
	_parts.head = _multimesh(head, MAX_MEN, _colored(0.35, 0.6))
	_parts.shield = _multimesh(shield, MAX_MEN, _colored(0.7))
	_parts.spear = _multimesh(spear, MAX_MEN, _colored(0.9))
	var leg := CapsuleMesh.new()
	leg.radius = 0.06
	leg.height = 0.36
	leg.radial_segments = 6
	leg.rings = 1
	_parts.leg_l = _multimesh(leg, MAX_MEN, _colored(0.85))
	_parts.leg_r = _multimesh(leg, MAX_MEN, _colored(0.85))
	for p in _parts.values():
		p.visible_instance_count = 0
	var lying := CapsuleMesh.new()
	lying.radius = 0.16
	lying.height = 0.6
	lying.radial_segments = 6
	lying.rings = 2
	_corpse_mm = _multimesh(lying, MAX_CORPSES, _colored(0.9), false)
	_corpse_mm.visible_instance_count = 0

	# Banners: a pole and a flag behind every block
	var pole := CylinderMesh.new()
	pole.top_radius = 0.025
	pole.bottom_radius = 0.03
	pole.height = 1.6
	pole.radial_segments = 5
	var flag := BoxMesh.new()
	flag.size = Vector3(0.42, 0.26, 0.03)
	_poles = _multimesh(pole, MAX_SQUADS, _colored(0.9))
	_flags = _multimesh(flag, MAX_SQUADS, _colored(0.8))
	_poles.visible_instance_count = 0
	_flags.visible_instance_count = 0

	# Messengers: a rider riding out from the Commander
	var rider := SphereMesh.new()
	rider.radius = 0.2
	rider.height = 0.4
	rider.radial_segments = 8
	rider.rings = 4
	_riders = _multimesh(rider, MAX_RIDERS, _colored(0.5))
	_riders.visible_instance_count = 0

	_build_houses()


func _build_houses() -> void:
	var wall := StandardMaterial3D.new()
	wall.albedo_color = Color(0.78, 0.68, 0.5)
	var roof := StandardMaterial3D.new()
	roof.albedo_color = Color(0.6, 0.3, 0.22)
	var ash := StandardMaterial3D.new()
	ash.albedo_color = Color(0.2, 0.18, 0.16)
	var fire := StandardMaterial3D.new()
	fire.albedo_color = Color(1.0, 0.55, 0.15)
	fire.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_house_mats = { "wall": wall, "roof": roof, "ash": ash }
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(0.6, 0.45, 0.5)
	var roof_mesh := PrismMesh.new()
	roof_mesh.size = Vector3(0.75, 0.35, 0.58)
	var flame_mesh := CylinderMesh.new()
	flame_mesh.top_radius = 0.0
	flame_mesh.bottom_radius = 0.16
	flame_mesh.height = 0.5
	flame_mesh.radial_segments = 6
	for o in sim.objectives:
		var group := []
		for off: Vector2 in HOUSE_OFFSETS:
			var at: Vector3 = ground(o.pos + off)
			var b := MeshInstance3D.new()
			b.mesh = body_mesh
			b.material_override = wall
			b.position = at + Vector3(0, 0.225, 0)
			add_child(b)
			var r := MeshInstance3D.new()
			r.mesh = roof_mesh
			r.material_override = roof
			r.position = at + Vector3(0, 0.62, 0)
			add_child(r)
			var f := MeshInstance3D.new()
			f.mesh = flame_mesh
			f.material_override = fire
			f.position = at + Vector3(0, 0.95, 0)
			f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			f.visible = false
			add_child(f)
			group.append({ "body": b, "roof": r, "flame": f })
		_houses.append(group)


# --- Camera ------------------------------------------------------------------------

## Arrow keys only: WASD, Q and E are battle keys here.
func _camera_keys(delta: float) -> void:
	var move := Vector2(
		float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT)),
		float(Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_UP)))
	if move == Vector2.ZERO:
		return
	var speed := dist * 0.9 * delta
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var back := Vector3(sin(yaw), 0, cos(yaw))
	target += (right * move.x + back * move.y) * speed
	target.x = clampf(target.x, 0.0, View.MAP_SIZE.x * S)
	target.z = clampf(target.z, 0.0, View.MAP_SIZE.y * S)
	_place_camera()


func focus(p: Vector2) -> void:
	target = Vector3(p.x * S, 0.0, p.y * S)
	dist = minf(dist, 24.0)
	_place_camera()


# --- Picking (screen space: soldiers stand up) -----------------------------------------

func squad_at_screen(screen: Vector2, team_of: int) -> Squad:
	var best: Squad = null
	var best_d := 18.0
	for s in sim.squads:
		if not is_instance_valid(s) or s.team != team_of:
			continue
		if s.concealed:
			var d0 := to_screen(s.center(), 0.6).distance_to(screen)
			if d0 < 30.0 and d0 < best_d + 12.0:
				best = s
				best_d = d0 - 12.0
			continue
		for m in s._m:
			var d := to_screen(m.pos, 0.45).distance_to(screen)
			if d < best_d:
				best_d = d
				best = s
	if best == null:
		# Not on a man: inside a block's footprint on the ground?
		var p := pick(screen)
		for s in sim.squads:
			if is_instance_valid(s) and s.team == team_of and s.contains_point(p):
				return s
	return best


func man_index_at_screen(s: Squad, screen: Vector2) -> int:
	var best := -1
	var best_d := 12.0
	for i in s._m.size():
		var d := to_screen(s._m[i].pos, 0.5).distance_to(screen)
		if d < best_d:
			best_d = d
			best = i
	return best


func squad_in_screen_rect(s: Squad, rect: Rect2) -> bool:
	if rect.has_point(to_screen(s.center(), 0.4)):
		return true
	for m in s._m:
		if rect.has_point(to_screen(m.pos, 0.45)):
			return true
	return false


# --- Every frame ---------------------------------------------------------------------

func _update_soldiers() -> void:
	var i := 0
	var banners := 0
	var dt := get_process_delta_time()
	var seen := {}
	for s in sim.squads:
		if not is_instance_valid(s) or s.concealed:
			continue
		var squad_face := Vector2.RIGHT.rotated(s.rotation)
		var base_c: Color = s.color
		if s.routing:
			base_c = base_c.darkened(0.3)
		for m in s._m:
			if i >= MAX_MEN:
				break
			var face: Vector2 = squad_face
			if m.target != null and m.target.alive:
				face = (m.target.pos - m.pos).normalized()
			var fwd := Vector3(face.x, 0.0, face.y)
			if fwd.length() < 0.01:
				fwd = Vector3.RIGHT
			# Walking? Swing the legs and bob, in step with how fast he's going
			var last: Vector2 = _last_pos.get(m, m.pos)
			var speed := last.distance_to(m.pos) / maxf(dt, 0.001)
			_last_pos[m] = m.pos
			seen[m] = true
			var phase: float = _gait.get(m, randf() * TAU)
			var walking := speed > 8.0 and not get_tree().paused
			if walking:
				phase += dt * clampf(speed * 0.16, 6.0, 14.0)
			_gait[m] = phase
			var stride := sin(phase) * (0.55 if walking else 0.0)
			var bob := absf(sin(phase)) * 0.05 if walking else 0.0
			var t := Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), ground(m.pos, bob))
			var c := base_c.lerp(Color.WHITE, 0.75) if m.flash > 0.0 else base_c
			var trousers := c.darkened(0.45)
			_parts.leg_l.set_instance_transform(i, t * Transform3D(Basis(Vector3.RIGHT, stride), Vector3(-0.07, 0.17 - bob, 0)))
			_parts.leg_l.set_instance_color(i, trousers)
			_parts.leg_r.set_instance_transform(i, t * Transform3D(Basis(Vector3.RIGHT, -stride), Vector3(0.07, 0.17 - bob, 0)))
			_parts.leg_r.set_instance_color(i, trousers)
			var thrust := sin(m.swing / Squad.SWING_ANIM * PI) * 0.22 if m.swing > 0.0 else 0.0
			var level := -1.25 if m.target != null else -0.3 # leveled to fight, sloped to march
			if s.routing:
				level = 0.25
			_parts.body.set_instance_transform(i, t * Transform3D(Basis(), Vector3(0, 0.5, 0)))
			_parts.body.set_instance_color(i, c)
			_parts.head.set_instance_transform(i, t * Transform3D(Basis(), Vector3(0, 0.92, 0)))
			_parts.head.set_instance_color(i, Color.WHITE if m.flash > 0.0 else Color(0.58, 0.59, 0.62))
			_parts.shield.set_instance_transform(i, t * Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(0.11, 0.55, -0.19)))
			_parts.shield.set_instance_color(i, c.darkened(0.35))
			_parts.spear.set_instance_transform(i, t * Transform3D(Basis(Vector3.RIGHT, level), Vector3(-0.15, 0.65, -0.12 - thrust)))
			_parts.spear.set_instance_color(i, Color(0.5, 0.38, 0.24))
			i += 1
		# Banner just behind the block
		if not s.routing and banners < MAX_SQUADS and not s._m.is_empty():
			var h: Vector2 = s.half_size()
			var back: Vector2 = s.center() - squad_face * (h.y + 9.0)
			var tall := 1.25 if s.is_commander else 1.0
			var base_pos := ground(back)
			_poles.set_instance_transform(banners, Transform3D(Basis().scaled(Vector3(1, tall, 1)), base_pos + Vector3(0, 0.8 * tall, 0)))
			_poles.set_instance_color(banners, Color(0.45, 0.33, 0.2))
			var wave := sin(Time.get_ticks_msec() / 300.0 + banners) * 0.15
			var fb := Basis(Vector3.UP, -s.rotation + PI + wave).scaled(Vector3.ONE * (1.3 if s.is_commander else 1.0))
			var top := base_pos + Vector3(0, 1.45 * tall, 0)
			_flags.set_instance_transform(banners, Transform3D(fb, top + fb * Vector3(0.22, 0, 0))) # flies back off the pole
			_flags.set_instance_color(banners, s.color.lightened(0.1))
			banners += 1
	for p in _parts.values():
		p.visible_instance_count = i
	# Forget the fallen and the departed
	if _last_pos.size() > seen.size() + 64:
		for m in _last_pos.keys():
			if not seen.has(m):
				_last_pos.erase(m)
				_gait.erase(m)
	_poles.visible_instance_count = banners
	_flags.visible_instance_count = banners

	# The fallen stay where they fell
	var n := mini(_corpses.size(), MAX_CORPSES)
	for k in n:
		var cp: Dictionary = _corpses[_corpses.size() - n + k]
		var f: Vector2 = cp.face
		var basis := Basis(Vector3.UP, atan2(-f.y, f.x)) * Basis(Vector3.FORWARD, PI / 2.0)
		_corpse_mm.set_instance_transform(k, Transform3D(basis, ground(cp.pos, 0.12)))
		_corpse_mm.set_instance_color(k, Color(cp.color).darkened(0.45))
	_corpse_mm.visible_instance_count = n

	# Messengers riding out
	var r := 0
	for o in sim.pending:
		if r >= MAX_RIDERS or not is_instance_valid(o.squad):
			continue
		var from: Vector2 = sim.commander.center() if is_instance_valid(sim.commander) else o.squad.center()
		var progress := 1.0 - float(o.left) / float(o.total)
		var at: Vector2 = from.lerp(o.squad.center(), progress)
		var bob := absf(sin(Time.get_ticks_msec() / 90.0)) * 0.12
		_riders.set_instance_transform(r, Transform3D(Basis(), ground(at, 0.55 + bob)))
		_riders.set_instance_color(r, Color(0.95, 0.85, 0.35))
		r += 1
	_riders.visible_instance_count = r

	# The village places: houses go up in flames as they burn
	var t_now := Time.get_ticks_msec() / 1000.0
	for k in _houses.size():
		if k >= sim.objectives.size():
			break
		var o: Dictionary = sim.objectives[k]
		for j in _houses[k].size():
			var hs: Dictionary = _houses[k][j]
			var lost: bool = o.lost
			hs.body.material_override = _house_mats.ash if lost else _house_mats.wall
			hs.roof.material_override = _house_mats.ash if lost else _house_mats.roof
			var on_fire: bool = (not lost and o.progress > 0.15 * (j + 1)) or (lost and j == 0)
			hs.flame.visible = on_fire
			if on_fire:
				var fl := 1.0 + sin(t_now * 9.0 + j * 2.0) * 0.25
				hs.flame.scale = Vector3(1.0, fl, 1.0)


## Laid on the ground: the deployment area, trigger zones and their orders,
## the village circles, the Commander's circle, selections, flank arcs,
## attack lines, messengers' roads and the drag previews.
func _update_decals() -> void:
	_decals.clear_surfaces()
	var tris: Array = []
	var lines: Array = []
	var b = sim

	if b.phase == b.Phase.PLANNING:
		_rect(tris, lines, b.DEPLOY_ZONE, Color(b.PLAYER_COLOR, 0.1), Color(b.PLAYER_COLOR.lightened(0.3), 0.8))
	for z: Rect2 in b.zones:
		_rect(tris, lines, z, Color(b.ZONE_COLOR, 0.16), Color(b.ZONE_COLOR, 0.9))
	for order in b.orders:
		if order.fired or not is_instance_valid(order.squad):
			continue
		var c: Color = b.ATTACK_COLOR if order.action == b.Action.ATTACK else b.RETREAT_COLOR
		var from: Vector2 = order.squad.center()
		var to: Vector2 = order.zone.get_center()
		_dashed(lines, from, to, Color(c, 0.85))
		var d := (to - from).normalized()
		_tri(tris, to, to - d.rotated(0.45) * 12.0, to - d.rotated(-0.45) * 12.0, Color(c, 0.9))

	for o in b.objectives:
		var col := Color(0.3, 0.25, 0.2, 0.7) if o.lost else Color(b.OBJ_COLOR, 0.65)
		_ring(lines, o.pos, b.OBJ_RADIUS, col)
		if o.progress > 0.0 and not o.lost:
			_arc(tris, o.pos, b.OBJ_RADIUS, b.OBJ_RADIUS + 6.0, -PI / 2.0, -PI / 2.0 + TAU * o.progress, Color(1.0, 0.4, 0.2, 0.95))

	if is_instance_valid(b.commander) and not b.commander.routing:
		var cc: Vector2 = b.commander.center()
		var spin := Time.get_ticks_msec() / 6000.0
		for k in 40:
			var a := TAU * k / 40.0 + spin
			_line(lines, cc + Vector2.from_angle(a) * Squad.COMMANDER_AURA_RADIUS, cc + Vector2.from_angle(a + TAU / 80.0) * Squad.COMMANDER_AURA_RADIUS, Color(b.COMMANDER_COLOR, 0.55))

	for s in b.squads:
		if not is_instance_valid(s) or s.concealed or s.routing:
			continue
		var h: Vector2 = s.half_size() + Vector2(4, 4)
		var fwd := Vector2.RIGHT.rotated(s.rotation)
		var side := fwd.orthogonal()
		var c0: Vector2 = s.center()
		var cs := [c0 + fwd * h.y + side * h.x, c0 + fwd * h.y - side * h.x, c0 - fwd * h.y - side * h.x, c0 - fwd * h.y + side * h.x]
		if s.selected:
			_tri(tris, cs[0], cs[1], cs[2], Color(1.0, 0.9, 0.35, 0.14))
			_tri(tris, cs[0], cs[2], cs[3], Color(1.0, 0.9, 0.35, 0.14))
			for k in 4:
				_line(lines, cs[k], cs[(k + 1) % 4], Color(1.0, 0.9, 0.35, 0.95))
		if s.flank_t > 0.0:
			var r: float = s.half_size().length() + 8.0
			var a0: float = s.flank_dir.angle()
			_arc(tris, c0, r, r + 6.0, a0 - 0.6, a0 + 0.6, Color(1.0, 0.45, 0.2, 0.95 * minf(1.0, s.flank_t)))
		if s.team == 0 and s.attack_target != null and is_instance_valid(s.attack_target) and not s.in_contact:
			_dashed(lines, c0, s.attack_target.center(), Color(1.0, 0.55, 0.45, 0.85))

	for o in b.pending:
		if not is_instance_valid(o.squad):
			continue
		var s2: Squad = o.squad
		if is_instance_valid(b.commander):
			_dashed(lines, b.commander.center(), s2.center(), Color(1, 1, 1, 0.35))
		var dest: Vector2 = o.pos if o.kind == "move" else (o.enemy.center() if is_instance_valid(o.enemy) else s2.center())
		_dashed(lines, s2.center(), dest, Color(1, 1, 1, 0.5))

	var g := Color(0.6, 1.0, 0.6, 0.95)
	if b._rdragging and b._rdrag_start.distance_to(b._rdrag_end) >= b.DRAG_THRESHOLD:
		var dir: Vector2 = (b._rdrag_end - b._rdrag_start).normalized()
		var tip: Vector2 = b._rdrag_start + dir * maxf(40.0, b._rdrag_start.distance_to(b._rdrag_end))
		_line(lines, b._rdrag_start, tip, g)
		_tri(tris, tip + dir * 8.0, tip - dir.rotated(0.5) * 10.0, tip - dir.rotated(-0.5) * 10.0, g)
		_line(lines, b._rdrag_start - dir.orthogonal() * 40.0, b._rdrag_start + dir.orthogonal() * 40.0, Color(g, 0.6))
	if b._dragging and b._zone_mode and b._drag_start.distance_to(b._drag_end) >= b.DRAG_THRESHOLD:
		_rect(tris, lines, Rect2(b._drag_start, b._drag_end - b._drag_start).abs(), Color(b.ZONE_COLOR, 0.12), Color(b.ZONE_COLOR, 0.9))

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if not tris.is_empty():
		_decals.surface_begin(Mesh.PRIMITIVE_TRIANGLES, mat)
		for k in range(0, tris.size(), 2):
			_decals.surface_set_color(tris[k + 1])
			_decals.surface_add_vertex(tris[k])
		_decals.surface_end()
	if not lines.is_empty():
		_decals.surface_begin(Mesh.PRIMITIVE_LINES, mat)
		for k in range(0, lines.size(), 2):
			_decals.surface_set_color(lines[k + 1])
			_decals.surface_add_vertex(lines[k])
		_decals.surface_end()


## A rectangle on the ground, split into cells so it follows the hills.
func _rect(tris: Array, lines: Array, r: Rect2, fill: Color, edge: Color) -> void:
	var nx := maxi(1, int(r.size.x / 40.0))
	var ny := maxi(1, int(r.size.y / 40.0))
	for i in nx:
		for j in ny:
			var a := r.position + Vector2(r.size.x * i / nx, r.size.y * j / ny)
			var b2 := r.position + Vector2(r.size.x * (i + 1) / nx, r.size.y * (j + 1) / ny)
			_tri(tris, a, Vector2(b2.x, a.y), b2, fill)
			_tri(tris, a, b2, Vector2(a.x, b2.y), fill)
	var cs := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
	for k in 4:
		_dashed(lines, cs[k], cs[(k + 1) % 4], edge, 10.0, 6.0)


func _dashed(out: Array, a: Vector2, b2: Vector2, col: Color, dash := 8.0, gap := 8.0) -> void:
	var d := a.distance_to(b2)
	if d < 0.5:
		return
	var k := 0.0
	while k < d:
		_line(out, a.lerp(b2, k / d), a.lerp(b2, minf(k + dash, d) / d), col)
		k += dash + gap


func _ring(out: Array, c: Vector2, r: float, col: Color) -> void:
	for k in 36:
		_line(out, c + Vector2.from_angle(TAU * k / 36.0) * r, c + Vector2.from_angle(TAU * (k + 1) / 36.0) * r, col)


func _arc(out: Array, c: Vector2, r0: float, r1: float, a0: float, a1: float, col: Color) -> void:
	var steps := maxi(4, int(absf(a1 - a0) / 0.12))
	for k in steps:
		var x := a0 + (a1 - a0) * k / steps
		var y := a0 + (a1 - a0) * (k + 1) / steps
		var p1 := c + Vector2.from_angle(x) * r0
		var p2 := c + Vector2.from_angle(y) * r0
		var q1 := c + Vector2.from_angle(x) * r1
		var q2 := c + Vector2.from_angle(y) * r1
		_tri(out, p1, p2, q2, col)
		_tri(out, p1, q2, q1, col)


# --- Screen-space overlay -------------------------------------------------------------

func _label(ci: Control, at: Vector2, text: String, size: int, col: Color, width := 240.0) -> void:
	var p := at - Vector2(width / 2.0, 0)
	ci.draw_string_outline(_font, p, text, HORIZONTAL_ALIGNMENT_CENTER, width, size, 3, Color(0, 0, 0, 0.65 * col.a))
	ci.draw_string(_font, p, text, HORIZONTAL_ALIGNMENT_CENTER, width, size, col)


func draw_overlay(ci: Control) -> void:
	var b = sim
	var screen_mouse := get_viewport().get_mouse_position()
	var hovered: Squad = squad_at_screen(screen_mouse, 0) if b.phase != b.Phase.ENDED else null

	if b.phase == b.Phase.PLANNING:
		var dz: Rect2 = b.DEPLOY_ZONE
		var corner := Vector2(dz.position.x + 90.0, dz.end.y - 14.0)
		if on_screen(corner, 0.1):
			_label(ci, to_screen(corner, 0.1), "DEPLOYMENT AREA", 12, Color(b.PLAYER_COLOR.lightened(0.4), 0.9))
	for i in b.zones.size():
		var z: Rect2 = b.zones[i]
		var zp := z.position + Vector2(36, 16)
		if on_screen(zp, 0.1):
			_label(ci, to_screen(zp, 0.1), "ZONE %d" % (i + 1), 12, Color(b.ZONE_COLOR.lightened(0.3), 0.95), 100.0)
	for o in b.objectives:
		var lp: Vector2 = o.pos + Vector2(0, b.OBJ_RADIUS + 14.0)
		if on_screen(lp, 0.1):
			var txt: String = o.name + ("  (burned)" if o.lost else "")
			_label(ci, to_screen(lp, 0.1), txt, 12, Color(0.7, 0.6, 0.5, 0.95) if o.lost else Color(b.OBJ_COLOR, 0.95))

	for s in b.squads:
		if not is_instance_valid(s) or not on_screen(s.center(), 1.0):
			continue
		var top := to_screen(s.center(), 1.7)
		if s.concealed:
			var fog_at := to_screen(s.center(), 0.6)
			for off in [Vector2(-16, -10), Vector2(12, -14), Vector2(14, -2), Vector2(-12, 0), Vector2(0, -20), Vector2(0, -6)]:
				ci.draw_circle(fog_at + off, 16.0, Color(0.82, 0.82, 0.86, 0.22))
			_label(ci, fog_at + Vector2(0, 8), "?", 28, s.color.lightened(0.2), 60.0)
			continue
		if not s.routing:
			# Morale bar above the block
			var frac := clampf(s.morale / Squad.MAX_MORALE, 0.0, 1.0)
			var bar_c := Color(0.45, 0.85, 0.4)
			if frac < 0.5:
				bar_c = Color(0.95, 0.75, 0.25)
			if frac < 0.25:
				bar_c = Color(0.95, 0.32, 0.28)
			ci.draw_rect(Rect2(top + Vector2(-20, -4), Vector2(40, 6)), Color(0, 0, 0, 0.6))
			ci.draw_rect(Rect2(top + Vector2(-19, -3), Vector2(38 * frac, 4)), bar_c)
			if s.flank_t > 0.0:
				var tag := "REAR!" if s.flank_rear else "FLANKED"
				var tc := Color(1.0, 0.5, 0.3) if s.team == 0 else Color(0.6, 1.0, 0.5)
				_label(ci, top + Vector2(0, -9), tag, 12, Color(tc, minf(1.0, s.flank_t)), 120.0)
		# Label under the block (intel on theirs, tags on ours)
		var lab: Array = b.squad_label(s, hovered)
		if not lab.is_empty():
			_label(ci, to_screen(s.center() + Vector2(0, s.radius() + 4.0), 0.0) + Vector2(0, 16), lab[0], 12, lab[1])
		# Sparks where its men were struck
		for sp in s._sparks:
			var q := to_screen(sp.pos, 0.6)
			var a: float = sp.left / 0.15
			var col := Color(1.0, 0.6, 0.25, a) if sp.flank else Color(1, 0.95, 0.6, a)
			for k in 4:
				var d := Vector2.from_angle(k * PI / 2.0 + 0.6)
				ci.draw_line(q + d * 2.0, q + d * 6.0, col, 1.5)

	for o in b.pending:
		if is_instance_valid(o.squad):
			_label(ci, to_screen(o.squad.center(), 1.7) + Vector2(0, -16), "order in %.1fs" % o.left, 12, Color(1, 1, 1, 0.95), 160.0)

	for p in b._popups:
		var rise: float = (b.POPUP_TIME - float(p.left)) * 15.0
		var alpha := clampf(p.left, 0.0, 1.0)
		if p.has("pos"):
			_label(ci, to_screen(p.pos, 2.0) + Vector2(0, -rise), p.text, 15, Color(1.0, 0.6, 0.4, alpha), 300.0)
		elif is_instance_valid(p.squad):
			_label(ci, to_screen(p.squad.center(), 2.2) + Vector2(0, -18 - rise), p.text, 14, Color(b.COMMANDER_COLOR.lightened(0.2), alpha), 260.0)

	# Selection box (on the screen)
	if b._dragging and not b._zone_mode and b._drag_screen_start.distance_to(screen_mouse) > 6.0:
		var r := Rect2(b._drag_screen_start, screen_mouse - b._drag_screen_start).abs()
		ci.draw_rect(r, Color(b.BOX_COLOR, 0.12), true)
		ci.draw_rect(r, Color(b.BOX_COLOR, 0.9), false, 1.5)
