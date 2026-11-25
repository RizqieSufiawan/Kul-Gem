extends Node3D
## 3D view for the skirmish prototype. The fight is still simulated on the
## flat 2D map (pixels); this only draws it in 3D: 1 map px = S world units,
## hills from Terrain.height, the stream carved into the ground.
##
## Camera: WASD / arrows pan, Q / E turn, wheel zoom, middle-drag orbit, Home reset.

const S := 0.05 # world units per map pixel
const HILL_H := 2.6
const RIVER_DEPTH := 0.55
const WATER_Y := -0.2
const CELL := 10.0 # map px per terrain grid cell
const MARGIN := 320.0 # ground beyond the map edge, so the horizon isn't a cliff
const MAX_CORPSES := 600

var sim # the skirmish (untyped: it preloads this script)
var cam: Camera3D
var target := Vector3.ZERO
var yaw := 0.0
var pitch := deg_to_rad(55.0)
var dist := 44.0
var overlay: Control
var _orbiting := false
var _decals := ImmediateMesh.new()
var _parts := {} # part name -> MultiMesh
var _corpse_mm: MultiMesh
var _corpses: Array[Dictionary] = [] # { pos: Vector2, color: Color, face: Vector2 }
var _font: Font


func _init(skirmish) -> void:
	sim = skirmish


func _ready() -> void:
	_font = ThemeDB.fallback_font
	_build_environment()
	_build_terrain()
	_build_water()
	_build_bridge()
	_build_trees_and_stones()
	_build_soldiers()
	var mi := MeshInstance3D.new()
	mi.mesh = _decals
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	cam = Camera3D.new()
	cam.fov = 45.0
	cam.far = 400.0
	add_child(cam)
	cam.make_current()
	reset_camera()


# --- Map <-> world ------------------------------------------------------------

## How far the stream bed is carved down at `p` (0 on dry land).
func _carve(p: Vector2) -> float:
	var dx := absf(p.x - Terrain.stream_x(p.y))
	var edge := Terrain.STREAM_HALF_WIDTH + 8.0
	if dx >= edge:
		return 0.0
	var depth := RIVER_DEPTH * smoothstep(edge, Terrain.STREAM_HALF_WIDTH - 8.0, dx)
	if Terrain.on_ford(p) or _near_ford(p):
		depth *= 0.3 # shallow: you can see the stones
	return depth


func _near_ford(p: Vector2) -> bool:
	for fy in Terrain.FORDS:
		if absf(p.y - fy) < Terrain.FORD_HALF_LENGTH:
			return true
	return false


func height_at(p: Vector2) -> float:
	var h := Terrain.height(p) * HILL_H - _carve(p)
	if Terrain.on_bridge(p):
		h = maxf(h, 0.14) # on the deck
	return h


func ground(p: Vector2, lift := 0.0) -> Vector3:
	return Vector3(p.x * S, height_at(p) + lift, p.y * S)


## The map point under a screen position (the ray walks onto the hills).
func pick(screen: Vector2) -> Vector2:
	var o := cam.project_ray_origin(screen)
	var d := cam.project_ray_normal(screen)
	if absf(d.y) < 0.001:
		return Vector2(o.x / S, o.z / S)
	var h := 0.0
	var mp := Vector2.ZERO
	for i in 5:
		var t := (h - o.y) / d.y
		var hit := o + d * t
		mp = Vector2(hit.x / S, hit.z / S)
		h = height_at(mp)
	return mp


func to_screen(p: Vector2, lift := 0.45) -> Vector2:
	return cam.unproject_position(ground(p, lift))


func on_screen(p: Vector2, lift := 0.45) -> bool:
	return not cam.is_position_behind(ground(p, lift))


## An enemy soldier drawn under the mouse (screen space: bodies stand up).
func enemy_at_screen(screen: Vector2, team: int):
	var best = null
	var best_d := 22.0
	for u in sim.units:
		if not u.alive or u.team != team or u.sq.gone():
			continue
		var d := to_screen(u.pos).distance_to(screen)
		if d < best_d:
			best_d = d
			best = u
	return best


# --- Camera -------------------------------------------------------------------

func reset_camera() -> void:
	target = Vector3(View.MAP_SIZE.x * S / 2.0, 0.0, View.MAP_SIZE.y * S / 2.0 + 2.0)
	yaw = 0.0
	pitch = deg_to_rad(55.0)
	dist = 44.0
	_place_camera()


func _place_camera() -> void:
	var off := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * dist
	cam.position = target + off
	cam.look_at(target, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					dist = clampf(dist / 1.12, 8.0, 80.0)
					_place_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					dist = clampf(dist * 1.12, 8.0, 80.0)
					_place_camera()
			MOUSE_BUTTON_MIDDLE:
				_orbiting = event.pressed
	elif event is InputEventMouseMotion and _orbiting:
		yaw -= event.relative.x * 0.008
		pitch = clampf(pitch + event.relative.y * 0.006, deg_to_rad(20.0), deg_to_rad(85.0))
		_place_camera()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_HOME:
		reset_camera()


func _camera_keys(delta: float) -> void:
	var move := Vector2(
		float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)),
		float(Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP)))
	var turn := float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q))
	if move == Vector2.ZERO and turn == 0.0:
		return
	yaw += turn * 1.6 * delta
	var speed := dist * 0.9 * delta
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var back := Vector3(sin(yaw), 0, cos(yaw))
	target += (right * move.x + back * move.y) * speed
	target.x = clampf(target.x, 0.0, View.MAP_SIZE.x * S)
	target.z = clampf(target.z, 0.0, View.MAP_SIZE.y * S)
	_place_camera()


# --- World building -------------------------------------------------------------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.36, 0.52, 0.72)
	sky_mat.sky_horizon_color = Color(0.72, 0.76, 0.74)
	sky_mat.ground_horizon_color = Color(0.5, 0.55, 0.45)
	sky_mat.ground_bottom_color = Color(0.25, 0.3, 0.2)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.4
	# Linear and no fog: under the Compatibility renderer, Filmic and fog wash the colours out
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-48.0), deg_to_rad(-35.0), 0.0)
	sun.light_energy = 0.85
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)


func _ground_color(p: Vector2, noise: FastNoiseLite) -> Color:
	var n := noise.get_noise_2d(p.x, p.y)
	var c := Color(0.36, 0.5, 0.24).lerp(Color(0.42, 0.55, 0.27), n * 0.5 + 0.5)
	c = c.lightened(Terrain.height(p) * 0.12)
	if Terrain.in_forest(p):
		c = Color(0.22, 0.33, 0.17).lerp(c, 0.25)
	if Terrain.on_road(p):
		var edge := absf(p.y - Terrain.road_y(p.x)) / Terrain.ROAD_HALF_WIDTH
		c = Color(0.52, 0.43, 0.3).lerp(c, smoothstep(0.7, 1.0, edge))
	var carve := _carve(p)
	if carve > 0.0:
		var mud := Color(0.62, 0.56, 0.4) if _near_ford(p) else Color(0.34, 0.29, 0.21)
		c = c.lerp(mud, clampf(carve / 0.12, 0.0, 1.0))
	return c


func _build_terrain() -> void:
	var noise := FastNoiseLite.new()
	noise.frequency = 0.004
	noise.seed = 3
	var x0 := -MARGIN
	var y0 := -MARGIN
	var nx := int((View.MAP_SIZE.x + MARGIN * 2.0) / CELL) + 1
	var ny := int((View.MAP_SIZE.y + MARGIN * 2.0) / CELL) + 1
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in ny:
		for i in nx:
			var p := Vector2(x0 + i * CELL, y0 + j * CELL)
			st.set_color(_ground_color(p, noise))
			st.add_vertex(Vector3(p.x * S, Terrain.height(p) * HILL_H - _carve(p), p.y * S))
	for j in ny - 1:
		for i in nx - 1:
			var a := j * nx + i
			st.add_index(a)
			st.add_index(a + 1)
			st.add_index(a + nx)
			st.add_index(a + 1)
			st.add_index(a + nx + 1)
			st.add_index(a + nx)
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.95
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	add_child(mi)


func _build_water() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var y := -MARGIN
	var w := Terrain.STREAM_HALF_WIDTH + 6.0
	while y <= View.MAP_SIZE.y + MARGIN:
		var x := Terrain.stream_x(y)
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3((x - w) * S, WATER_Y, y * S))
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3((x + w) * S, WATER_Y, y * S))
		y += 12.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.42, 0.55, 0.78)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.12
	mat.metallic = 0.15
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _build_bridge() -> void:
	var b := Terrain.bridge_point()
	var along := Vector2(1.0, Terrain.road_y(b.x + 1.0) - Terrain.road_y(b.x - 1.0)).normalized()
	var length := (Terrain.STREAM_HALF_WIDTH * 2.0 + 30.0) * S
	var width := Terrain.BRIDGE_HALF_LENGTH * 2.0 * S
	var holder := Node3D.new()
	holder.position = Vector3(b.x * S, 0.06, b.y * S)
	holder.rotation.y = -along.angle()
	add_child(holder)
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.5, 0.36, 0.22)
	wood.roughness = 0.9
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.33, 0.23, 0.13)
	var deck := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(length, 0.14, width)
	deck.mesh = box
	deck.material_override = wood
	holder.add_child(deck)
	for side in [-1.0, 1.0]:
		var rail := MeshInstance3D.new()
		var rb := BoxMesh.new()
		rb.size = Vector3(length, 0.08, 0.08)
		rail.mesh = rb
		rail.material_override = dark
		rail.position = Vector3(0, 0.42, side * width / 2.0)
		holder.add_child(rail)
		for k in 5:
			var post := MeshInstance3D.new()
			var pb := BoxMesh.new()
			pb.size = Vector3(0.08, 0.4, 0.08)
			post.mesh = pb
			post.material_override = dark
			post.position = Vector3(-length / 2.0 + k * length / 4.0, 0.22, side * width / 2.0)
			holder.add_child(post)
		var pile := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.09
		cyl.bottom_radius = 0.09
		cyl.height = 1.0
		pile.mesh = cyl
		pile.material_override = dark
		pile.position = Vector3(0, -0.45, side * width / 2.5)
		holder.add_child(pile)


func _multimesh(mesh: Mesh, count: int, mat: Material, shadows := true) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mm


func _colored(roughness := 0.85, metallic := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true # our colours are picked by eye, in sRGB
	m.roughness = roughness
	m.metallic = metallic
	return m


func _build_trees_and_stones() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var spots: Array[Vector2] = []
	for forest in Terrain.FORESTS:
		for c in forest:
			var center := Vector2(c[0], c[1])
			var r: float = c[2]
			for k in int(r * r / 260.0):
				spots.append(center + Vector2.RIGHT.rotated(rng.randf() * TAU) * sqrt(rng.randf()) * (r - 6.0))
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.06
	trunk.bottom_radius = 0.1
	trunk.height = 0.9
	var crown := SphereMesh.new()
	crown.radius = 0.62
	crown.height = 1.5
	crown.radial_segments = 10
	crown.rings = 6
	var trunks := _multimesh(trunk, spots.size(), _colored())
	var crowns := _multimesh(crown, spots.size(), _colored(0.9))
	for i in spots.size():
		var p := spots[i]
		var sc := rng.randf_range(0.55, 0.85) # trees a few men tall, not giants
		var base := ground(p)
		trunks.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * sc), base + Vector3(0, 0.45 * sc, 0)))
		trunks.set_instance_color(i, Color(0.36, 0.26, 0.17))
		crowns.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * sc), base + Vector3(0, 1.35 * sc, 0)))
		crowns.set_instance_color(i, Color(0.16, 0.36, 0.17).lerp(Color(0.27, 0.46, 0.22), rng.randf()))
	# Stones in the grass
	var stone := SphereMesh.new()
	stone.radius = 0.14
	stone.height = 0.16
	stone.radial_segments = 6
	stone.rings = 3
	var stones: Array[Vector2] = []
	while stones.size() < 90:
		var p := Vector2(rng.randf() * View.MAP_SIZE.x, rng.randf() * View.MAP_SIZE.y)
		if not (Terrain.in_stream(p) or Terrain.in_forest(p) or Terrain.on_road(p)):
			stones.append(p)
	var smm := _multimesh(stone, stones.size(), _colored(1.0))
	for i in stones.size():
		var sc := rng.randf_range(0.6, 1.8)
		smm.set_instance_transform(i, Transform3D(Basis().rotated(Vector3.UP, rng.randf() * TAU).scaled(Vector3(sc, sc * 0.7, sc)), ground(stones[i], 0.02)))
		smm.set_instance_color(i, Color(0.55, 0.55, 0.52).darkened(rng.randf() * 0.2))


func _build_soldiers() -> void:
	var n: int = sim.units.size()
	var body := CapsuleMesh.new()
	body.radius = 0.17
	body.height = 0.62
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
	_parts.body = _multimesh(body, n, _colored(0.8))
	_parts.head = _multimesh(head, n, _colored(0.35, 0.6))
	_parts.shield = _multimesh(shield, n, _colored(0.7))
	_parts.spear = _multimesh(spear, n, _colored(0.9))
	var lying := CapsuleMesh.new()
	lying.radius = 0.16
	lying.height = 0.6
	lying.radial_segments = 6
	lying.rings = 2
	_corpse_mm = _multimesh(lying, MAX_CORPSES, _colored(0.9), false)
	_corpse_mm.visible_instance_count = 0


func add_corpse(p: Vector2, color: Color, face: Vector2) -> void:
	if _corpses.size() >= MAX_CORPSES:
		_corpses.pop_front()
	_corpses.append({ "pos": p, "color": color, "face": face })


# --- Every frame ------------------------------------------------------------------

func _process(delta: float) -> void:
	_camera_keys(delta)
	_update_soldiers()
	_update_decals()
	if overlay != null:
		overlay.queue_redraw()


func _update_soldiers() -> void:
	var i := 0
	var corpses: Array[Dictionary] = _corpses.duplicate()
	for u in sim.units:
		if not u.alive:
			if u.dead_for < 900.0:
				corpses.append({ "pos": u.pos, "color": u.sq.color, "face": u.face })
			continue
		var fwd := Vector3(u.face.x, 0.0, u.face.y)
		if fwd.length() < 0.01:
			fwd = Vector3.RIGHT
		var t := Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), ground(u.pos))
		var c: Color = u.sq.color
		if u.flash > 0.0:
			c = c.lerp(Color.WHITE, 0.75)
		if u.sq.routing:
			c = c.darkened(0.3)
		var thrust := sin(u.swing / 0.22 * PI) * 0.22 if u.swing > 0.0 else 0.0
		var level := -1.25 if u.target != null else -0.3 # spear leveled to fight, sloped to march
		if u.sq.routing:
			level = 0.25
		_parts.body.set_instance_transform(i, t * Transform3D(Basis(), Vector3(0, 0.38, 0)))
		_parts.body.set_instance_color(i, c)
		_parts.head.set_instance_transform(i, t * Transform3D(Basis(), Vector3(0, 0.8, 0)))
		_parts.head.set_instance_color(i, Color(0.58, 0.59, 0.62) if u.flash <= 0.0 else Color.WHITE)
		_parts.shield.set_instance_transform(i, t * Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(0.11, 0.45, -0.19)))
		_parts.shield.set_instance_color(i, c.darkened(0.35))
		_parts.spear.set_instance_transform(i, t * Transform3D(Basis(Vector3.RIGHT, level), Vector3(-0.15, 0.55, -0.12 - thrust)))
		_parts.spear.set_instance_color(i, Color(0.5, 0.38, 0.24))
		i += 1
	for part in _parts.values():
		part.visible_instance_count = i
	var n := mini(corpses.size(), MAX_CORPSES)
	for k in n:
		var cp: Dictionary = corpses[corpses.size() - n + k]
		var f: Vector2 = cp.face
		var yaw_c := atan2(-f.y, f.x)
		var basis := Basis(Vector3.UP, yaw_c) * Basis(Vector3.FORWARD, PI / 2.0)
		_corpse_mm.set_instance_transform(k, Transform3D(basis, ground(cp.pos, 0.12)))
		_corpse_mm.set_instance_color(k, Color(cp.color).darkened(0.45))
	_corpse_mm.visible_instance_count = n


## Lines and shapes laid on the ground: each block's footprint and facing,
## flank arcs, selection rings, attack lines, the right-drag arrow.
func _update_decals() -> void:
	_decals.clear_surfaces()
	var tris: Array = [] # [Vector3, Color] triples flattened
	var lines: Array = []
	for s in sim.squads:
		if s.gone():
			continue
		var h: Vector2 = sim._half(s.alive().size()) + Vector2(5, 5)
		var fwd := Vector2.from_angle(s.facing)
		var side := fwd.orthogonal()
		var cs := [s.pos + fwd * h.y + side * h.x, s.pos + fwd * h.y - side * h.x,
			s.pos - fwd * h.y - side * h.x, s.pos - fwd * h.y + side * h.x]
		var fill := Color(s.color, 0.16)
		_tri(tris, cs[0], cs[1], cs[2], fill)
		_tri(tris, cs[0], cs[2], cs[3], fill)
		var edge := Color(0.6, 1.0, 0.6, 0.95) if s.selected else Color(s.color.lightened(0.2), 0.7)
		for k in 4:
			_line(lines, cs[k], cs[(k + 1) % 4], edge)
		var tip: Vector2 = s.pos + fwd * (h.y + 10.0)
		_tri(tris, tip, tip - fwd * 7.0 + side * 7.0, tip - fwd * 7.0 - side * 7.0, Color(s.color.lightened(0.3), 0.9))
		if s.flank_t > 0.0:
			var r := h.length() + 6.0
			var a0: float = s.flank_dir.angle()
			var alpha := minf(1.0, s.flank_t)
			var col := Color(1.0, 0.45, 0.2, 0.95 * alpha)
			var steps := 12
			for k in steps:
				var a1 := a0 - 0.6 + 1.2 * k / steps
				var a2 := a0 - 0.6 + 1.2 * (k + 1) / steps
				var p1: Vector2 = s.pos + Vector2.from_angle(a1) * r
				var p2: Vector2 = s.pos + Vector2.from_angle(a2) * r
				var q1: Vector2 = s.pos + Vector2.from_angle(a1) * (r + 6.0)
				var q2: Vector2 = s.pos + Vector2.from_angle(a2) * (r + 6.0)
				_tri(tris, p1, p2, q2, col)
				_tri(tris, p1, q2, q1, col)
		if s.selected:
			for u in s.alive():
				_circle(lines, u.pos, 7.0, Color(0.6, 1.0, 0.6, 0.9))
		if s.team == 0 and s.attack != null and not s.in_contact:
			var a: Vector2 = s.pos
			var b: Vector2 = s.attack.pos
			var dlen := a.distance_to(b)
			var k := 0.0
			while k < dlen:
				_line(lines, a.lerp(b, k / dlen), a.lerp(b, minf(k + 8.0, dlen) / dlen), Color(1.0, 0.55, 0.45, 0.85))
				k += 16.0
	if sim._rdrag and sim._rdrag_a.distance_to(sim._rdrag_b) > 12.0:
		var a: Vector2 = sim._rdrag_a
		var b: Vector2 = sim._rdrag_b
		_line(lines, a, b, Color(0.6, 1.0, 0.6, 0.95))
		var d := (b - a).normalized()
		_tri(tris, b + d * 8.0, b - d * 4.0 + d.orthogonal() * 7.0, b - d * 4.0 - d.orthogonal() * 7.0, Color(0.6, 1.0, 0.6, 0.95))

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


func _tri(out: Array, a: Vector2, b: Vector2, c: Vector2, col: Color) -> void:
	for p in [a, b, c]:
		out.append(ground(p, 0.05))
		out.append(col)


func _line(out: Array, a: Vector2, b: Vector2, col: Color) -> void:
	out.append(ground(a, 0.06))
	out.append(col)
	out.append(ground(b, 0.06))
	out.append(col)


func _circle(out: Array, c: Vector2, r: float, col: Color) -> void:
	for k in 10:
		_line(out, c + Vector2.from_angle(TAU * k / 10.0) * r, c + Vector2.from_angle(TAU * (k + 1) / 10.0) * r, col)


# --- Screen-space overlay (tags, sparks, health, drag box) ---------------------------

func draw_overlay(ci: Control) -> void:
	for s in sim.squads:
		if s.gone() or not on_screen(s.pos, 1.6):
			continue
		var h: Vector2 = sim._half(s.alive().size())
		var p := to_screen(s.pos - Vector2(0, h.y), 1.7)
		var m := clampf(s.morale / 100.0, 0.0, 1.0)
		if s.team == 0:
			ci.draw_string(_font, p + Vector2(-60, -8), "%s %d" % [s.name, s.alive().size()], HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(0.88, 0.92, 1.0))
		ci.draw_rect(Rect2(p + Vector2(-20, -3), Vector2(40, 4)), Color(0, 0, 0, 0.65))
		ci.draw_rect(Rect2(p + Vector2(-20, -3), Vector2(40 * m, 4)), Color(1.0 - m, 0.4 + 0.5 * m, 0.3))
		if s.flank_t > 0.0:
			var tag := "REAR!" if s.flank_rear else "FLANKED"
			var tc := Color(1.0, 0.55, 0.3) if s.team == 0 else Color(0.6, 1.0, 0.5)
			ci.draw_string(_font, p + Vector2(-60, -22 if s.team == 0 else -8), tag, HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(tc, minf(1.0, s.flank_t)))
	for sp in sim.sparks:
		var q := to_screen(sp.pos, 0.6)
		var a: float = sp.left / 0.15
		var col := Color(1.0, 0.6, 0.25, a) if sp.flank else Color(1, 0.95, 0.6, a)
		for k in 4:
			var d := Vector2.from_angle(k * PI / 2.0 + 0.6)
			ci.draw_line(q + d * 2.0, q + d * 6.0, col, 1.5)
	for s in sim.squads:
		if not s.selected:
			continue
		for u in s.alive():
			if u.hp < sim.HP:
				var q := to_screen(u.pos, 1.15)
				var f := clampf(u.hp / sim.HP, 0.0, 1.0)
				ci.draw_rect(Rect2(q + Vector2(-6, 0), Vector2(12, 2)), Color(0, 0, 0, 0.6))
				ci.draw_rect(Rect2(q + Vector2(-6, 0), Vector2(12 * f, 2)), Color(1.0 - f, 0.85 * f + 0.15, 0.2))
	if sim._drag and sim._drag_a.distance_to(sim._drag_b) > 6.0:
		var r := Rect2(sim._drag_a, sim._drag_b - sim._drag_a).abs()
		ci.draw_rect(r, Color(0.6, 1.0, 0.6, 0.1), true)
		ci.draw_rect(r, Color(0.6, 1.0, 0.6, 0.85), false, 1.0)
