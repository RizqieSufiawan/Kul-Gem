extends Node3D
## 3D view for the skirmish prototype. The fight is still simulated on the
## flat 2D map (pixels); this only draws it in 3D: 1 map px = S world units,
## hills from Terrain.height, the stream carved into the ground.
##
## Camera: WASD / arrows pan, Q / E turn, wheel zoom (toward the cursor, from
## the whole map down to eye level), middle-drag turn / tilt, Home reset.

const S := 0.05 # world units per map pixel
const HILL_H := 2.6
const RIVER_DEPTH := 0.55
const WATER_Y := -0.2
const CELL := 6.0 # map px per terrain grid cell
const MARGIN := 320.0 # ground beyond the map edge, so the horizon isn't a cliff
const MAX_CORPSES := 600
const MIN_DIST := 2.2 # closest zoom: among the men

# --- Art direction ----------------------------------------------------------------
# The world is muted and misty, like a storybook picture (Bad North); only what
# you have to read is strong colour: the squads, banners and village flags
# (Thronefall); many small, chunky soldiers rather than a few detailed ones
# (Diplomacy is Not an Option). Environment colours live here.
const MIST := Color(0.86, 0.86, 0.82) # fog, horizon, the map's edge dissolving
const GRASS_A := Color(0.43, 0.55, 0.32)
const GRASS_B := Color(0.5, 0.6, 0.36)
const FOREST_FLOOR := Color(0.33, 0.41, 0.29)
const ROAD := Color(0.68, 0.6, 0.46)
const MUD := Color(0.47, 0.41, 0.32)
const FORD := Color(0.72, 0.68, 0.55)
const CROWN_A := Color(0.33, 0.47, 0.31)
const CROWN_B := Color(0.45, 0.56, 0.36)
const PINE_A := Color(0.21, 0.35, 0.29)
const PINE_B := Color(0.28, 0.42, 0.33)
const TRUNK := Color(0.42, 0.35, 0.28)
const STONE := Color(0.74, 0.73, 0.68)
const MAX_DIST := 90.0 # farthest: the whole map

var sim # the skirmish (untyped: it preloads this script)
var cam: Camera3D
var target := Vector3.ZERO
var yaw := 0.0
var pitch := deg_to_rad(55.0)
var dist := 44.0
var tilt := 0.0 # the player's tilt on top of the zoom's own angle
var dist_goal := 44.0 # zoom and pan ease toward these
var target_goal := Vector3.ZERO
var yaw_touched := false # the player turned the camera (followers stop steering it)
var _pan_vel := Vector2.ZERO # keys ease in and out instead of starting and stopping dead
var _turn_vel := 0.0
var overlay: Control
var _orbiting := false
var _decals := ImmediateMesh.new()
var _parts := {} # part name -> MultiMesh
var _corpse_mm: MultiMesh
var _corpses: Array[Dictionary] = [] # { pos: Vector2, color: Color, face: Vector2 }
var _font: Font
var _cam_attr: CameraAttributesPractical # depth of field (Forward+ only)
var _env: Environment


func _init(skirmish) -> void:
	sim = skirmish


func _ready() -> void:
	_font = ThemeDB.fallback_font
	_build_environment()
	_build_terrain()
	_build_water()
	_build_bridge()
	_build_trees_and_stones()
	_build_grass()
	_build_soldiers()
	var mi := MeshInstance3D.new()
	mi.mesh = _decals
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	cam = Camera3D.new()
	cam.fov = 50.0
	cam.near = 0.03
	cam.far = 400.0
	cam.attributes = _cam_attr
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


## Where a screen point's ray meets the ground (on flat ground at height 0;
## rays at or above the horizon stop a fixed distance out). For the minimap.
func ground_hit(screen: Vector2) -> Vector2:
	var o := cam.project_ray_origin(screen)
	var d := cam.project_ray_normal(screen)
	var hit: Vector3
	if d.y > -0.03:
		var flat := Vector3(d.x, 0, d.z).normalized()
		hit = o + flat * 90.0
	else:
		hit = o + d * minf((0.0 - o.y) / d.y, 90.0 / maxf(Vector2(d.x, d.z).length(), 0.01))
	return Vector2(hit.x / S, hit.z / S)


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
	target_goal = target
	yaw = 0.0
	tilt = 0.0
	dist = 44.0
	dist_goal = dist
	_place_camera()


## How far up the camera looks down at a given zoom: steep from high up,
## nearly level when it's down among the men.
func _zoom_t(d: float) -> float:
	return clampf(inverse_lerp(log(3.0), log(60.0), log(d)), 0.0, 1.0)


func _place_camera() -> void:
	var zt := _zoom_t(dist)
	pitch = clampf(lerpf(deg_to_rad(8.0), deg_to_rad(60.0), zt) + tilt, deg_to_rad(2.0), deg_to_rad(85.0))
	var mp := Vector2(target.x / S, target.z / S)
	# Look at the ground there (at chest height when close)
	var aim := Vector3(target.x, height_at(mp) + lerpf(0.75, 0.0, zt), target.z)
	var pos := aim + Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * dist
	pos.y = maxf(pos.y, height_at(Vector2(pos.x / S, pos.z / S)) + 0.3) # never inside a hill
	cam.position = pos
	cam.look_at(aim, Vector3.UP)
	if _env != null:
		# The mist starts a little beyond what you're looking at
		_env.fog_depth_begin = dist * 1.4 + 18.0
		_env.fog_depth_end = _env.fog_depth_begin + 110.0
	if _cam_attr != null:
		# A touch of blur in the distance: the field looks like a table-top model
		_cam_attr.dof_blur_far_distance = maxf(dist * 1.5, 18.0)
		_cam_attr.dof_blur_far_transition = maxf(dist * 1.2, 14.0)


## Zoom by `f` (<1 = in). Zooming in heads toward the cursor.
func _zoom(f: float, screen: Vector2) -> void:
	var before := dist_goal
	dist_goal = clampf(dist_goal * f, MIN_DIST, MAX_DIST)
	if f < 1.0:
		var p := pick(screen)
		var g := Vector3(p.x * S, 0.0, p.y * S)
		if g.distance_to(target_goal) < maxf(dist_goal, 4.0) * 3.0: # not a point on the horizon
			target_goal += (g - target_goal) * (1.0 - dist_goal / before)
			_clamp_goal()


func _clamp_goal() -> void:
	target_goal.x = clampf(target_goal.x, 0.0, View.MAP_SIZE.x * S)
	target_goal.z = clampf(target_goal.z, 0.0, View.MAP_SIZE.y * S)


## Glide zoom and pan to where they're headed.
func _ease_camera(delta: float) -> void:
	var k := 1.0 - exp(-delta * 9.0)
	dist = lerpf(dist, dist_goal, k)
	target = target.lerp(target_goal, k)
	_place_camera()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_zoom(1.0 / 1.18, event.position)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_zoom(1.18, event.position)
			MOUSE_BUTTON_MIDDLE:
				_orbiting = event.pressed
	elif event is InputEventMouseMotion and _orbiting:
		yaw -= event.relative.x * 0.008
		tilt = clampf(tilt + event.relative.y * 0.005, -0.7, 0.7)
		if event.relative.x != 0.0:
			yaw_touched = true
		_place_camera()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_HOME:
		reset_camera()


func _camera_keys(delta: float) -> void:
	var move := Vector2(
		float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)),
		float(Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP)))
	var turn := float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q))
	_drive(move, turn, delta)


## Pan and turn with a little momentum. E turns right, Q left.
func _drive(move: Vector2, turn: float, delta: float) -> void:
	var k := 1.0 - exp(-delta * 10.0)
	_pan_vel = _pan_vel.lerp(move.limit_length(1.0), k)
	_turn_vel = lerpf(_turn_vel, turn * 1.9, k)
	if turn != 0.0:
		yaw_touched = true
	if absf(_turn_vel) > 0.01:
		yaw -= _turn_vel * delta
	if _pan_vel.length() > 0.01:
		_pan(_pan_vel, delta)


func _pan(move: Vector2, delta: float) -> void:
	var speed := maxf(dist, 4.0) * 0.9 * delta
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var back := Vector3(sin(yaw), 0, cos(yaw))
	var step := (right * move.x + back * move.y) * speed
	target_goal += step
	target += step
	_clamp_goal()
	target.x = clampf(target.x, 0.0, View.MAP_SIZE.x * S)
	target.z = clampf(target.z, 0.0, View.MAP_SIZE.y * S)
	_place_camera()


# --- World building -------------------------------------------------------------

## Forward+ gets the full treatment (ambient occlusion, glow, haze, soft
## shadows, depth of field). Under the Compatibility renderer (no Vulkan)
## those either don't exist or wash the colours out, so it stays plain.
func _rich() -> bool:
	return RenderingServer.get_current_rendering_method() != "gl_compatibility"


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.55, 0.67, 0.78)
	sky_mat.sky_horizon_color = MIST
	sky_mat.ground_horizon_color = MIST
	sky_mat.ground_bottom_color = MIST.darkened(0.2)
	sky_mat.sun_angle_max = 30.0
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-42.0), deg_to_rad(-35.0), 0.0)
	sun.light_color = Color(1.0, 0.93, 0.82)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 110.0
	if _rich():
		env.ambient_light_energy = 0.75 # soft shadows, nothing pitch dark
		env.tonemap_mode = Environment.TONE_MAPPER_AGX
		env.tonemap_exposure = 1.0
		env.ssao_enabled = true
		env.ssao_radius = 1.5
		env.ssao_intensity = 1.0
		env.glow_enabled = true
		env.glow_intensity = 0.3
		env.glow_bloom = 0.05
		# Mist by distance: clear where you look, the far field dissolving
		env.fog_enabled = true
		env.fog_mode = Environment.FOG_MODE_DEPTH
		env.fog_light_color = MIST
		env.fog_density = 1.0
		env.fog_depth_curve = 1.6
		env.fog_aerial_perspective = 0.3
		env.fog_sky_affect = 0.7
		env.adjustment_enabled = true
		env.adjustment_saturation = 1.1
		env.adjustment_contrast = 1.0
		sun.light_energy = 1.3
		sun.shadow_blur = 2.5
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	else:
		env.ambient_light_energy = 0.5
		env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		env.fog_enabled = true # the plain renderer gets the same mist by distance
		env.fog_mode = Environment.FOG_MODE_DEPTH
		env.fog_light_color = MIST
		env.fog_density = 1.0
		env.fog_depth_curve = 1.6
		sun.light_energy = 0.85
	_env = env
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	add_child(sun)
	if _rich():
		var ca := CameraAttributesPractical.new()
		ca.dof_blur_far_enabled = true
		ca.dof_blur_amount = 0.06
		_cam_attr = ca


func _ground_color(p: Vector2, noise: FastNoiseLite) -> Color:
	var n := noise.get_noise_2d(p.x, p.y)
	var c := GRASS_A.lerp(GRASS_B, n * 0.5 + 0.5)
	c = c.lightened(Terrain.height(p) * 0.1)
	if Terrain.in_forest(p):
		c = FOREST_FLOOR.lerp(c, 0.3)
	if Terrain.on_road(p):
		var edge := absf(p.y - Terrain.road_y(p.x)) / Terrain.ROAD_HALF_WIDTH
		c = ROAD.lerp(c, smoothstep(0.7, 1.0, edge))
	var carve := _carve(p)
	if carve > 0.0:
		c = c.lerp(FORD if _near_ford(p) else MUD, clampf(carve / 0.12, 0.0, 1.0))
	# Past the edge of the map the land fades into the mist
	var out := maxf(maxf(-p.x, p.x - View.MAP_SIZE.x), maxf(-p.y, p.y - View.MAP_SIZE.y))
	if out > 0.0:
		c = c.lerp(MIST, smoothstep(0.0, MARGIN * 0.8, out))
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
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _terrain_material()
	add_child(mi)


func _build_water() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var y := -MARGIN
	var w := Terrain.STREAM_HALF_WIDTH + 6.0
	while y <= View.MAP_SIZE.y + MARGIN:
		var x := Terrain.stream_x(y)
		for side in [-1.0, 1.0]:
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(0.5 + side * 0.5, y / 40.0))
			st.add_vertex(Vector3((x + side * w) * S, WATER_Y, y * S))
		y += 8.0
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _water_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## Ground: the vertex colours (grass, road, mud, forest floor) with a
## two-scale noise on top, so close up it's not a flat smear.
func _terrain_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
uniform sampler2D detail : filter_linear_mipmap, repeat_enable;
varying vec3 wpos;
varying vec3 base;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	base = pow(COLOR.rgb, vec3(2.2)); // our colours are sRGB
}
void fragment() {
	float n1 = texture(detail, wpos.xz * 0.11).r;
	float n2 = texture(detail, wpos.xz * 0.53).r;
	ALBEDO = base * (0.9 + 0.16 * n1) * (0.96 + 0.08 * n2); // a soft painted grain, not texture
	ROUGHNESS = 1.0;
	SPECULAR = 0.1;
}
"""
	var noise := FastNoiseLite.new()
	noise.frequency = 0.02
	noise.fractal_octaves = 4
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.seamless = true
	tex.width = 256
	tex.height = 256
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("detail", tex)
	return m


## Water: a deep-to-shallow tint, ripples running downstream, brighter
## (and more opaque) at a glancing angle.
func _water_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_always;
uniform vec3 deep : source_color = vec3(0.24, 0.4, 0.47);
uniform vec3 shallow : source_color = vec3(0.48, 0.64, 0.64);
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	float t = TIME;
	float a = sin(wpos.z * 1.7 - t * 1.6 + sin(wpos.x * 1.3 + t * 0.4) * 1.2);
	float b = sin(wpos.z * 2.9 + wpos.x * 2.3 - t * 2.1);
	NORMAL_MAP = normalize(vec3(0.5 + 0.025 * b, 0.5 + 0.035 * a, 1.0));
	float edge = abs(UV.x - 0.5) * 2.0; // 0 mid-stream, 1 at the banks
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALBEDO = mix(deep, shallow, edge * 0.7 + 0.15 * a) + vec3(0.18) * fres;
	ALPHA = mix(0.82, 0.96, fres) * mix(1.0, 0.88, edge);
	ROUGHNESS = 0.2;
	METALLIC = 0.0;
	SPECULAR = 0.45;
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	return m


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
	# The deck: planks laid across, each a slightly different shade
	var planks := 14
	var plank := BoxMesh.new()
	plank.size = Vector3(length / planks - 0.02, 0.12, width)
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	for k in planks:
		var pl := MeshInstance3D.new()
		pl.mesh = plank
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.5, 0.36, 0.22).darkened(rng.randf_range(-0.08, 0.2))
		m.roughness = 0.9
		pl.material_override = m
		pl.position = Vector3(-length / 2.0 + (k + 0.5) * length / planks, rng.randf_range(-0.01, 0.01), 0)
		holder.add_child(pl)
	# Beams under the deck
	for side in [-1.0, 1.0]:
		var beam := MeshInstance3D.new()
		var bb := BoxMesh.new()
		bb.size = Vector3(length, 0.1, 0.12)
		beam.mesh = bb
		beam.material_override = dark
		beam.position = Vector3(0, -0.1, side * width / 3.0)
		holder.add_child(beam)
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


## Several primitive meshes baked into one, each placed by its transform
## and painted with its own colour (which the instance colour then tints).
## parts: [[PrimitiveMesh, Transform3D, Color], ...]
func _compose(parts: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part in parts:
		var arr: Array = (part[0] as PrimitiveMesh).get_mesh_arrays()
		var xf: Transform3D = part[1]
		var nb := xf.basis.inverse().transposed()
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		for i in idx:
			st.set_color(part[2])
			st.set_normal((nb * norms[i]).normalized())
			st.add_vertex(xf * verts[i])
	return st.commit()


func _colored(roughness := 0.85, metallic := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true # our colours are picked by eye, in sRGB
	m.roughness = roughness
	m.metallic = metallic
	return m


## For the squads: a soft rim of light so the team colours pop off the
## muted ground (the readability rule).
func _unit_mat(roughness := 0.8, metallic := 0.0) -> StandardMaterial3D:
	var m := _colored(roughness, metallic)
	m.rim_enabled = true
	m.rim = 0.35
	m.rim_tint = 0.6
	return m


func _build_trees_and_stones() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var spots: Array[Vector2] = []
	for forest in Terrain.FORESTS:
		for c in forest:
			var center := Vector2(c[0], c[1])
			var r: float = c[2]
			for k in int(r * r / 220.0):
				spots.append(center + Vector2.RIGHT.rotated(rng.randf() * TAU) * sqrt(rng.randf()) * (r - 6.0))
	var round_spots: Array[Vector2] = []
	var pine_spots: Array[Vector2] = []
	for p in spots:
		if rng.randf() < 0.6:
			round_spots.append(p)
		else:
			pine_spots.append(p)

	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.06
	trunk.bottom_radius = 0.1
	trunk.height = 0.9
	trunk.radial_segments = 6
	var trunks := _multimesh(trunk, spots.size(), _colored())
	# Round trees: a big crown and a smaller one offset, for a lumpy outline
	var crown := SphereMesh.new()
	crown.radius = 0.62
	crown.height = 1.3
	crown.radial_segments = 12
	crown.rings = 7
	var crowns := _multimesh(crown, round_spots.size() * 2, _colored(0.9))
	# Pines: three stacked cones
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.55
	cone.height = 0.9
	cone.radial_segments = 9
	var cones := _multimesh(cone, pine_spots.size() * 3, _colored(0.9))

	var ti := 0
	for k in round_spots.size():
		var p := round_spots[k]
		var sc := rng.randf_range(0.55, 0.85)
		var base := ground(p)
		trunks.set_instance_transform(ti, Transform3D(Basis().scaled(Vector3.ONE * sc), base + Vector3(0, 0.45 * sc, 0)))
		trunks.set_instance_color(ti, TRUNK)
		ti += 1
		var green := CROWN_A.lerp(CROWN_B, rng.randf())
		crowns.set_instance_transform(k * 2, Transform3D(Basis().scaled(Vector3.ONE * sc), base + Vector3(0, 1.3 * sc, 0)))
		crowns.set_instance_color(k * 2, green)
		var off := Vector3(rng.randf_range(-0.3, 0.3), 0, rng.randf_range(-0.3, 0.3)) * sc
		crowns.set_instance_transform(k * 2 + 1, Transform3D(Basis().scaled(Vector3.ONE * sc * 0.7), base + Vector3(0, 1.75 * sc, 0) + off))
		crowns.set_instance_color(k * 2 + 1, green.lightened(0.08))
	for k in pine_spots.size():
		var p := pine_spots[k]
		var sc := rng.randf_range(0.6, 0.95)
		var base := ground(p)
		trunks.set_instance_transform(ti, Transform3D(Basis().scaled(Vector3.ONE * sc), base + Vector3(0, 0.45 * sc, 0)))
		trunks.set_instance_color(ti, TRUNK.darkened(0.1))
		ti += 1
		var green := PINE_A.lerp(PINE_B, rng.randf())
		for j in 3:
			var shrink := 1.0 - j * 0.25
			cones.set_instance_transform(k * 3 + j, Transform3D(Basis().scaled(Vector3(shrink, 1.0, shrink) * sc), base + Vector3(0, (0.85 + j * 0.45) * sc, 0)))
			cones.set_instance_color(k * 3 + j, green.lightened(j * 0.05))

	# Stones in the grass
	var stone := SphereMesh.new()
	stone.radius = 0.14
	stone.height = 0.16
	stone.radial_segments = 6
	stone.rings = 3
	var stones: Array[Vector2] = []
	while stones.size() < 110:
		var p := Vector2(rng.randf() * View.MAP_SIZE.x, rng.randf() * View.MAP_SIZE.y)
		if not (Terrain.in_stream(p) or Terrain.in_forest(p) or Terrain.on_road(p)):
			stones.append(p)
	var smm := _multimesh(stone, stones.size(), _colored(1.0))
	for i in stones.size():
		var sc := rng.randf_range(0.6, 1.8)
		smm.set_instance_transform(i, Transform3D(Basis().rotated(Vector3.UP, rng.randf() * TAU).scaled(Vector3(sc, sc * 0.7, sc)), ground(stones[i], 0.02)))
		smm.set_instance_color(i, STONE.darkened(rng.randf() * 0.15))


## Thousands of grass tufts that sway in the wind (none on the road, in
## the water or on the bridge; thin under the trees).
func _build_grass() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	# One tuft: five thin blades, each a triangle, leaning a little
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 5:
		var a := rng.randf() * TAU
		var side := Vector3(cos(a), 0, sin(a)) * 0.03
		var at := Vector3(rng.randf_range(-0.08, 0.08), 0, rng.randf_range(-0.08, 0.08))
		var lean := Vector3(rng.randf_range(-0.06, 0.06), 0, rng.randf_range(-0.06, 0.06))
		var h := rng.randf_range(0.15, 0.26)
		for v in [[at - side, 0.0], [at + side, 0.0], [at + lean + Vector3(0, h, 0), 1.0]]:
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(0.5, v[1]))
			st.add_vertex(v[0])
	var tuft := st.commit()
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, specular_disabled;
uniform vec3 root : source_color = vec3(0.4, 0.5, 0.32);
uniform vec3 tip : source_color = vec3(0.64, 0.7, 0.46);
varying vec3 tint;
void vertex() {
	tint = COLOR.rgb;
	NORMAL = vec3(0.0, 1.0, 0.0); // lit like the ground, whichever way a blade faces
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float sway = sin(TIME * 1.6 + wp.x * 0.7 + wp.z * 0.5) * 0.07 + sin(TIME * 3.3 + wp.x * 2.1) * 0.025;
	VERTEX.x += sway * UV.y;
	VERTEX.z += sway * 0.6 * UV.y;
}
void fragment() {
	// Both faces of a blade lit as if facing up (Godot flips back faces' normals)
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	ALBEDO = mix(root, tip, UV.y) * tint;
	ROUGHNESS = 0.9;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var count := 14000
	var spots: Array[Vector3] = []
	var tries := 0
	while spots.size() < count and tries < count * 3:
		tries += 1
		var p := Vector2(rng.randf_range(-60.0, View.MAP_SIZE.x + 60.0), rng.randf_range(-60.0, View.MAP_SIZE.y + 60.0))
		if Terrain.in_stream(p) or Terrain.on_road(p) or Terrain.on_bridge(p) or _carve(p) > 0.05:
			continue
		if Terrain.in_forest(p) and rng.randf() < 0.7:
			continue
		if _grass_thin(p) and rng.randf() < 0.8:
			continue
		spots.append(Vector3(p.x, p.y, rng.randf()))
	var mm := _multimesh(tuft, spots.size(), mat, false)
	for i in spots.size():
		var p := Vector2(spots[i].x, spots[i].y)
		var sc := rng.randf_range(0.7, 1.3)
		mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * sc), ground(p)))
		mm.set_instance_color(i, Color(1, 1, 1).lerp(Color(1.15, 1.05, 0.8), spots[i].z * 0.6))


## Where the grass grows sparse (the battle view thins it in the villages).
func _grass_thin(_p: Vector2) -> bool:
	return false


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
	if not Guide.is_open:
		_camera_keys(delta)
	_ease_camera(delta)
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
