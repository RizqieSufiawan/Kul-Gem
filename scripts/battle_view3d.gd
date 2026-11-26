extends "res://scripts/proto/view3d.gd"
## The real battle drawn in 3D. The battle is still simulated on the flat 2D
## map; this reads it every frame and draws it: terrain, soldiers, banners,
## the village places, trigger zones, planned orders, messengers and labels.
##
## Camera: arrow keys pan, wheel zoom (map overview down to eye level),
## middle-drag turn / tilt, F follow the selected squads, Home reset.

const MAX_MEN := 480
const MAX_SQUADS := 24
const MAX_RIDERS := 16

var _poles: MultiMesh
var _flags: MultiMesh
var _riders: MultiMesh
var _houses: Array = [] # per objective: { houses, villagers, fields, flag, glow }
var _house_mats := {}
var _last_pos := {} # Man -> where he stood last frame, to tell who's walking
var _gait := {} # Man -> walk cycle phase
var _crests: MultiMesh
var _ghost := {} # part name -> MultiMesh, for men hidden in a forest
const MAX_GHOSTS := 200
const FAR_DETAIL := 40.0 # camera distance past which the small parts aren't drawn
const GHOST_ALPHA := 0.35
var _horse_legs: MultiMesh
var following := false # camera rides with the selected squads
var _fit := 1.0 # how loosely several followed squads are framed

const SKIN := [Color(0.93, 0.78, 0.64), Color(0.82, 0.64, 0.48), Color(0.66, 0.48, 0.34)]


func _init(the_battle) -> void:
	super(the_battle)


# --- Building ------------------------------------------------------------------

func _build_soldiers() -> void:
	# Each part is baked from a few primitives; the instance colour tints it
	# (team colour for cloth, grey for iron, white where the colours are baked).
	_parts.leg_l = _multimesh(_leg_mesh(), MAX_MEN, _unit_mat(0.85))
	_parts.leg_r = _multimesh(_leg_mesh(), MAX_MEN, _unit_mat(0.85))
	_parts.torso = _multimesh(_torso_mesh(), MAX_MEN, _unit_mat(0.8))
	_parts.arm_l = _multimesh(_arm_mesh(), MAX_MEN, _unit_mat(0.8))
	_parts.arm_r = _multimesh(_arm_mesh(), MAX_MEN, _unit_mat(0.8))
	var head := SphereMesh.new()
	head.radius = 0.1
	head.height = 0.21
	head.radial_segments = 10
	head.rings = 5
	_parts.head = _multimesh(head, MAX_MEN, _colored(0.7))
	_parts.helmet = _multimesh(_helmet_mesh(), MAX_MEN, _unit_mat(0.4, 0.6))
	_parts.shield = _multimesh(_shield_mesh(), MAX_MEN, _unit_mat(0.75))
	var boss := SphereMesh.new()
	boss.radius = 0.05
	boss.height = 0.05
	boss.radial_segments = 8
	boss.rings = 3
	_parts.boss = _multimesh(boss, MAX_MEN, _colored(0.3, 0.8))
	_parts.spear = _multimesh(_spear_mesh(), MAX_MEN, _colored(0.6, 0.25))
	for p in _parts.values():
		p.visible_instance_count = 0
	# Men hidden in a forest are drawn see-through (same parts, glassy)
	var ghost_mat := StandardMaterial3D.new()
	ghost_mat.vertex_color_use_as_albedo = true
	ghost_mat.vertex_color_is_srgb = true
	ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_mat.roughness = 0.8
	for k in _parts:
		_ghost[k] = _multimesh(_parts[k].mesh, MAX_GHOSTS, ghost_mat, false)
		_ghost[k].visible_instance_count = 0
	# The Commander's guard: a crest on the helmet
	var crest := BoxMesh.new()
	crest.size = Vector3(0.03, 0.07, 0.2)
	_crests = _multimesh(crest, 64, _colored(0.9))
	_crests.visible_instance_count = 0
	_corpse_mm = _multimesh(_corpse_mesh(), MAX_CORPSES, _colored(0.9), false)
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

	# Messengers: a rider on a horse, galloping out from the Commander
	_riders = _multimesh(_horse_mesh(), MAX_RIDERS, _colored(0.8))
	_riders.visible_instance_count = 0
	var hleg := CapsuleMesh.new()
	hleg.radius = 0.04
	hleg.height = 0.52
	hleg.radial_segments = 6
	hleg.rings = 1
	_horse_legs = _multimesh(_compose([[hleg, Transform3D(Basis(), Vector3(0, -0.26, 0)), Color(0.4, 0.27, 0.17)]]), MAX_RIDERS * 4, _colored(0.8))
	_horse_legs.visible_instance_count = 0

	_build_houses()


## A leg hanging from the hip (the origin): trouser, boot and foot.
func _leg_mesh() -> ArrayMesh:
	var leg := CapsuleMesh.new()
	leg.radius = 0.055
	leg.height = 0.34
	leg.radial_segments = 6
	leg.rings = 1
	var boot := CylinderMesh.new()
	boot.top_radius = 0.062
	boot.bottom_radius = 0.07
	boot.height = 0.12
	boot.radial_segments = 6
	var foot := BoxMesh.new()
	foot.size = Vector3(0.09, 0.05, 0.16)
	return _compose([
		[leg, Transform3D(Basis(), Vector3(0, -0.17, 0)), Color(1, 1, 1)],
		[boot, Transform3D(Basis(), Vector3(0, -0.29, 0)), Color(0.5, 0.45, 0.4)],
		[foot, Transform3D(Basis(), Vector3(0, -0.335, -0.04)), Color(0.5, 0.45, 0.4)]])


## Tunic: chest, a flared skirt and a dark belt.
func _torso_mesh() -> ArrayMesh:
	var chest := CapsuleMesh.new()
	chest.radius = 0.14
	chest.height = 0.44
	chest.radial_segments = 10
	chest.rings = 3
	var skirt := CylinderMesh.new()
	skirt.top_radius = 0.142
	skirt.bottom_radius = 0.19
	skirt.height = 0.2
	skirt.radial_segments = 10
	var belt := CylinderMesh.new()
	belt.top_radius = 0.15
	belt.bottom_radius = 0.15
	belt.height = 0.045
	belt.radial_segments = 10
	var collar := CylinderMesh.new()
	collar.top_radius = 0.06
	collar.bottom_radius = 0.09
	collar.height = 0.05
	collar.radial_segments = 8
	return _compose([
		[chest, Transform3D(Basis().scaled(Vector3(1.0, 1.0, 0.8)), Vector3(0, 0.56, 0)), Color(1, 1, 1)],
		[skirt, Transform3D(Basis().scaled(Vector3(1.0, 1.0, 0.85)), Vector3(0, 0.37, 0)), Color(0.88, 0.88, 0.88)],
		[belt, Transform3D(Basis().scaled(Vector3(1.0, 1.0, 0.82)), Vector3(0, 0.46, 0)), Color(0.32, 0.26, 0.2)],
		[collar, Transform3D(Basis(), Vector3(0, 0.77, 0)), Color(0.7, 0.7, 0.7)]])


## An arm from the shoulder (origin) along +Y, 0.3 long, ending in a glove.
func _arm_mesh() -> ArrayMesh:
	var arm := CapsuleMesh.new()
	arm.radius = 0.042
	arm.height = 0.3
	arm.radial_segments = 6
	arm.rings = 1
	var glove := SphereMesh.new()
	glove.radius = 0.045
	glove.height = 0.09
	glove.radial_segments = 6
	glove.rings = 3
	return _compose([
		[arm, Transform3D(Basis(), Vector3(0, 0.15, 0)), Color(1, 1, 1)],
		[glove, Transform3D(Basis(), Vector3(0, 0.3, 0)), Color(0.45, 0.38, 0.32)]])


## A conical iron helmet with a rim and a nose guard.
func _helmet_mesh() -> ArrayMesh:
	var cone := CylinderMesh.new()
	cone.top_radius = 0.03
	cone.bottom_radius = 0.118
	cone.height = 0.13
	cone.radial_segments = 10
	var rim := CylinderMesh.new()
	rim.top_radius = 0.126
	rim.bottom_radius = 0.126
	rim.height = 0.025
	rim.radial_segments = 10
	var nasal := BoxMesh.new()
	nasal.size = Vector3(0.022, 0.08, 0.02)
	var coif := CylinderMesh.new() # mail hanging over the neck and the back of the head
	coif.top_radius = 0.095
	coif.bottom_radius = 0.11
	coif.height = 0.12
	coif.radial_segments = 10
	return _compose([
		[coif, Transform3D(Basis().scaled(Vector3(1.0, 1.0, 0.7)), Vector3(0, 0.81, 0.06)), Color(0.55, 0.55, 0.57)],
		[cone, Transform3D(Basis(), Vector3(0, 0.93, 0)), Color(1, 1, 1)],
		[rim, Transform3D(Basis(), Vector3(0, 0.875, 0)), Color(0.8, 0.8, 0.8)],
		[nasal, Transform3D(Basis(), Vector3(0, 0.84, -0.1)), Color(0.85, 0.85, 0.85)]])


## A round shield lying along +Y (turned to face forward when placed):
## painted face, a lighter stripe and a dark rim.
func _shield_mesh() -> ArrayMesh:
	var face := CylinderMesh.new()
	face.top_radius = 0.23
	face.bottom_radius = 0.23
	face.height = 0.04
	face.radial_segments = 14
	var rim := CylinderMesh.new()
	rim.top_radius = 0.25
	rim.bottom_radius = 0.25
	rim.height = 0.03
	rim.radial_segments = 14
	var stripe := BoxMesh.new()
	stripe.size = Vector3(0.08, 0.044, 0.44)
	return _compose([
		[face, Transform3D(), Color(0.72, 0.72, 0.72)],
		[rim, Transform3D(), Color(0.35, 0.3, 0.26)],
		[stripe, Transform3D(), Color(1, 1, 1)]])


## A spear held at the origin (the hand): ash shaft, iron head.
func _spear_mesh() -> ArrayMesh:
	var shaft := CylinderMesh.new()
	shaft.top_radius = 0.013
	shaft.bottom_radius = 0.017
	shaft.height = 1.45
	shaft.radial_segments = 5
	var tip := CylinderMesh.new()
	tip.top_radius = 0.0
	tip.bottom_radius = 0.032
	tip.height = 0.16
	tip.radial_segments = 4
	return _compose([
		[shaft, Transform3D(Basis(), Vector3(0, 0.2, 0)), Color(0.52, 0.38, 0.24)],
		[tip, Transform3D(Basis(), Vector3(0, 1.0, 0)), Color(0.78, 0.79, 0.82)]])


## A fallen man lying on his back, his shield and spear by him.
func _corpse_mesh() -> ArrayMesh:
	var body := CapsuleMesh.new()
	body.radius = 0.13
	body.height = 0.5
	body.radial_segments = 8
	body.rings = 2
	var head := SphereMesh.new()
	head.radius = 0.09
	head.height = 0.18
	head.radial_segments = 8
	head.rings = 4
	var leg := CapsuleMesh.new()
	leg.radius = 0.05
	leg.height = 0.36
	leg.radial_segments = 6
	leg.rings = 1
	var shield := CylinderMesh.new()
	shield.top_radius = 0.2
	shield.bottom_radius = 0.2
	shield.height = 0.035
	shield.radial_segments = 12
	var shaft := CylinderMesh.new()
	shaft.top_radius = 0.014
	shaft.bottom_radius = 0.014
	shaft.height = 1.3
	shaft.radial_segments = 4
	var flat := Basis(Vector3.FORWARD, PI / 2.0) # lying along X
	return _compose([
		[body, Transform3D(flat, Vector3(0, 0.12, 0)), Color(1, 1, 1)],
		[head, Transform3D(Basis(), Vector3(0.34, 0.1, 0)), Color(0.9, 0.78, 0.66)],
		[leg, Transform3D(flat.rotated(Vector3.UP, 0.15), Vector3(-0.4, 0.06, 0.08)), Color(0.55, 0.55, 0.55)],
		[leg, Transform3D(flat.rotated(Vector3.UP, -0.2), Vector3(-0.4, 0.06, -0.08)), Color(0.55, 0.55, 0.55)],
		[shield, Transform3D(Basis(Vector3.RIGHT, 0.15), Vector3(0.05, 0.05, 0.3)), Color(0.7, 0.7, 0.7)],
		[shaft, Transform3D(flat.rotated(Vector3.UP, 0.25), Vector3(0.0, 0.03, -0.3)), Color(0.6, 0.5, 0.4)]])


## A horse with its rider (no legs: those gallop on their own). Faces -Z.
func _horse_mesh() -> ArrayMesh:
	var body := CapsuleMesh.new()
	body.radius = 0.17
	body.height = 0.78
	body.radial_segments = 10
	body.rings = 3
	var neck := CapsuleMesh.new()
	neck.radius = 0.08
	neck.height = 0.42
	neck.radial_segments = 8
	neck.rings = 1
	var head := BoxMesh.new()
	head.size = Vector3(0.11, 0.13, 0.3)
	var tail := CapsuleMesh.new()
	tail.radius = 0.035
	tail.height = 0.32
	tail.radial_segments = 5
	tail.rings = 1
	var torso := CapsuleMesh.new()
	torso.radius = 0.1
	torso.height = 0.4
	torso.radial_segments = 8
	torso.rings = 2
	var rhead := SphereMesh.new()
	rhead.radius = 0.08
	rhead.height = 0.16
	rhead.radial_segments = 8
	rhead.rings = 4
	var thigh := BoxMesh.new()
	thigh.size = Vector3(0.07, 0.07, 0.24)
	var brown := Color(0.48, 0.32, 0.2)
	var dark := Color(0.22, 0.16, 0.12)
	var coat := Color(0.95, 0.8, 0.3)
	var lying := Basis(Vector3.RIGHT, PI / 2.0) # along Z
	return _compose([
		[body, Transform3D(lying, Vector3(0, 0.66, 0)), brown],
		[neck, Transform3D(Basis(Vector3.RIGHT, -0.7), Vector3(0, 0.86, -0.36)), brown],
		[head, Transform3D(Basis(Vector3.RIGHT, 0.5), Vector3(0, 1.0, -0.55)), brown],
		[tail, Transform3D(Basis(Vector3.RIGHT, 0.7), Vector3(0, 0.62, 0.45)), dark],
		[torso, Transform3D(Basis(), Vector3(0, 1.0, 0.02)), coat],
		[rhead, Transform3D(Basis(), Vector3(0, 1.28, 0.02)), Color(0.9, 0.74, 0.58)],
		[thigh, Transform3D(Basis(), Vector3(-0.15, 0.82, -0.08)), dark],
		[thigh, Transform3D(Basis(), Vector3(0.15, 0.82, -0.08)), dark]])


## A limb's transform: the mesh's +Y axis stretched from `a` to `b` (its
## modelled length `len`).
func _limb(a: Vector3, b: Vector3, length: float) -> Transform3D:
	var d := b - a
	var y := d.normalized()
	var x := y.cross(Vector3.FORWARD)
	if x.length() < 0.01:
		x = Vector3.RIGHT
	x = x.normalized()
	var z := x.cross(y)
	return Transform3D(Basis(x, y * (d.length() / length), z), a)


## Each village place is a small hamlet: houses round a well and the village
## banner, a fence, fields outside, and villagers who run when raiders come.
## While it burns, the houses catch one by one and smoke rises (seen from
## far away); once burned it's ash.
func _build_houses() -> void:
	var walls := [Color(0.9, 0.87, 0.8), Color(0.85, 0.8, 0.7), Color(0.78, 0.72, 0.62)]
	var roofs := [Color(0.7, 0.36, 0.26), Color(0.38, 0.4, 0.44), Color(0.8, 0.68, 0.42)]
	_house_mats = {
		"ash": _plain(Color(0.17, 0.15, 0.13)),
		"ash_roof": _plain(Color(0.1, 0.09, 0.08)),
		"wood": _plain(Color(0.45, 0.32, 0.2)),
		"stone": _plain(Color(0.55, 0.54, 0.5)),
		"soil": _plain(Color(0.4, 0.3, 0.2)),
		"burnt_field": _plain(Color(0.16, 0.13, 0.1)),
		"flag": _plain(sim.OBJ_COLOR),
		"flag_lost": _plain(Color(0.15, 0.14, 0.13)),
	}
	var fire := StandardMaterial3D.new()
	fire.albedo_color = Color(1.0, 0.55, 0.15)
	fire.emission_enabled = true
	fire.emission = Color(1.0, 0.45, 0.1)
	fire.emission_energy_multiplier = 1.5
	fire.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var flame_mesh := CylinderMesh.new()
	flame_mesh.top_radius = 0.0
	flame_mesh.bottom_radius = 0.18
	flame_mesh.height = 0.55
	flame_mesh.radial_segments = 6

	for k in sim.objectives.size():
		var o: Dictionary = sim.objectives[k]
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(o.name)
		var place := { "houses": [], "villagers": [], "fields": [] }

		# Houses in a ring round the middle, facing in
		var n := 6
		for j in n:
			var a := TAU * j / n + rng.randf_range(-0.25, 0.25)
			var off := Vector2.from_angle(a) * rng.randf_range(24.0, 38.0)
			var at: Vector3 = ground(o.pos + off)
			var holder := Node3D.new()
			holder.position = at
			holder.rotation.y = -a + PI / 2.0 + rng.randf_range(-0.3, 0.3)
			add_child(holder)
			var w := rng.randf_range(0.55, 0.85)
			var d := rng.randf_range(0.45, 0.6)
			var h := rng.randf_range(0.38, 0.5)
			var body := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(w, h, d)
			body.mesh = bm
			var wall_mat := _plain(walls[rng.randi() % walls.size()])
			body.material_override = wall_mat
			body.position.y = h / 2.0
			holder.add_child(body)
			var roof := MeshInstance3D.new()
			var rm := PrismMesh.new()
			rm.size = Vector3(w + 0.14, h * 0.75, d + 0.1)
			roof.mesh = rm
			var roof_mat := _plain(roofs[rng.randi() % roofs.size()])
			roof.material_override = roof_mat
			roof.position.y = h + h * 0.375
			holder.add_child(roof)
			var door := MeshInstance3D.new()
			var dm := BoxMesh.new()
			dm.size = Vector3(0.12, 0.22, 0.02)
			door.mesh = dm
			door.material_override = _house_mats.wood
			door.position = Vector3(0, 0.11, -d / 2.0 - 0.005)
			holder.add_child(door)
			var flame := MeshInstance3D.new()
			flame.mesh = flame_mesh
			flame.material_override = fire
			flame.position.y = h * 1.75 + 0.2
			flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			flame.visible = false
			holder.add_child(flame)
			var smoke := _smoke()
			smoke.position.y = h * 1.75 + 0.4
			holder.add_child(smoke)
			place.houses.append({ "holder": holder, "body": body, "roof": roof, "wall_mat": wall_mat,
				"roof_mat": roof_mat, "flame": flame, "smoke": smoke, "h": h,
				"catch": (j + 1.0) / (n + 1.0) })

		# The well in the middle, and the village banner beside it
		var well := MeshInstance3D.new()
		var wm := CylinderMesh.new()
		wm.top_radius = 0.18
		wm.bottom_radius = 0.2
		wm.height = 0.24
		wm.radial_segments = 10
		well.mesh = wm
		well.material_override = _house_mats.stone
		well.position = ground(o.pos) + Vector3(0, 0.12, 0)
		add_child(well)
		var pole := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = 0.03
		pm.bottom_radius = 0.04
		pm.height = 2.6
		pm.radial_segments = 6
		pole.mesh = pm
		pole.material_override = _house_mats.wood
		var base := ground(o.pos + Vector2(10, 0))
		pole.position = base + Vector3(0, 1.3, 0)
		add_child(pole)
		var flag := MeshInstance3D.new()
		var fm := BoxMesh.new()
		fm.size = Vector3(0.7, 0.42, 0.03)
		flag.mesh = fm
		flag.material_override = _house_mats.flag
		flag.position = base + Vector3(0.36, 2.35, 0)
		add_child(flag)
		place.flag = flag
		place.flag_base = base
		var glow := OmniLight3D.new()
		glow.light_color = Color(1.0, 0.55, 0.2)
		glow.omni_range = 5.0
		glow.light_energy = 0.0
		glow.position = ground(o.pos) + Vector3(0, 1.4, 0)
		glow.shadow_enabled = false
		add_child(glow)
		place.glow = glow

		# Fence round it, with a gate on the west (our side) and the east
		var posts := []
		var steps := 30
		for j in steps:
			var a := TAU * j / steps
			if absf(angle_difference(a, PI)) < 0.25 or absf(angle_difference(a, 0.0)) < 0.25:
				continue
			posts.append(a)
		var post := CylinderMesh.new()
		post.top_radius = 0.025
		post.bottom_radius = 0.03
		post.height = 0.32
		post.radial_segments = 4
		var rail := BoxMesh.new()
		rail.size = Vector3(1.0, 0.03, 0.025)
		var pmm := _multimesh(post, posts.size(), _colored(0.9))
		var rmm := _multimesh(rail, posts.size() * 2, _colored(0.9))
		var r_fence: float = sim.OBJ_RADIUS - 4.0
		var ri := 0
		for j in posts.size():
			var a: float = posts[j]
			var p := ground(o.pos + Vector2.from_angle(a) * r_fence)
			pmm.set_instance_transform(j, Transform3D(Basis(), p + Vector3(0, 0.16, 0)))
			pmm.set_instance_color(j, Color(0.42, 0.3, 0.19))
			var nxt: float = a + TAU / steps
			if absf(angle_difference(posts[(j + 1) % posts.size()], nxt)) < 0.01: # no gate in between
				var q := ground(o.pos + Vector2.from_angle(nxt) * r_fence)
				var mid := (p + q) / 2.0
				var dir := q - p
				var yaw_r := atan2(-dir.z, dir.x)
				for lvl in [0.11, 0.24]:
					var b := Basis(Vector3.UP, yaw_r).scaled(Vector3(dir.length(), 1, 1))
					rmm.set_instance_transform(ri, Transform3D(b, mid + Vector3(0, lvl, 0)))
					rmm.set_instance_color(ri, Color(0.5, 0.37, 0.24))
					ri += 1
		rmm.visible_instance_count = ri

		# Fields outside the fence
		var crops := [Color(0.85, 0.72, 0.35), Color(0.45, 0.62, 0.28), Color(0.72, 0.68, 0.32)]
		for j in 3:
			var a := TAU * (j + 0.5) / 3.0 + rng.randf_range(-0.4, 0.4)
			var c: Vector2 = o.pos + Vector2.from_angle(a) * rng.randf_range(80.0, 96.0)
			if Terrain.in_stream(c) or Terrain.on_road(c) or Terrain.in_forest(c) or _carve(c) > 0.0:
				continue
			var field := Node3D.new()
			field.position = ground(c)
			field.rotation.y = rng.randf() * PI
			add_child(field)
			var soil := MeshInstance3D.new()
			var sm := BoxMesh.new()
			sm.size = Vector3(1.6, 0.04, 1.0)
			soil.mesh = sm
			soil.material_override = _house_mats.soil
			soil.position.y = 0.0
			field.add_child(soil)
			var crop_mat := _plain(crops[j % crops.size()])
			var cm := PrismMesh.new() # a ridge of crops
			cm.size = Vector3(0.07, 0.09, 1.5)
			for row in 8:
				var cr := MeshInstance3D.new()
				cr.mesh = cm
				cr.material_override = crop_mat
				cr.rotation.y = PI / 2.0
				cr.position = Vector3(0, 0.065, -0.42 + row * 0.12)
				field.add_child(cr)
			place.fields.append({ "soil": soil, "crop_mat": crop_mat, "node": field })

		# Villagers going about their day
		for j in 5:
			var tint: Color = [Color(0.62, 0.45, 0.3), Color(0.55, 0.55, 0.42), Color(0.7, 0.62, 0.48), Color(0.45, 0.38, 0.5)][j % 4]
			var v := MeshInstance3D.new()
			v.mesh = _villager_mesh(tint)
			var vm := StandardMaterial3D.new()
			vm.vertex_color_use_as_albedo = true
			vm.vertex_color_is_srgb = true
			vm.roughness = 0.9
			v.material_override = vm
			add_child(v)
			var home: Vector2 = o.pos + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(8.0, 34.0)
			place.villagers.append({ "node": v, "pos": home, "goal": home, "home": home, "wait": rng.randf_range(0.0, 3.0) })
		_houses.append(place)


## No thick grass between the houses.
func _grass_thin(p: Vector2) -> bool:
	for o in sim.objectives:
		if p.distance_to(o.pos) < sim.OBJ_RADIUS - 8.0:
			return true
	return false


func _plain(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	return m


## A villager: a plain tunic of colour `tunic`, legs and a head.
func _villager_mesh(tunic: Color) -> ArrayMesh:
	var body := CapsuleMesh.new()
	body.radius = 0.09
	body.height = 0.42
	body.radial_segments = 8
	body.rings = 2
	var head := SphereMesh.new()
	head.radius = 0.075
	head.height = 0.15
	head.radial_segments = 8
	head.rings = 4
	var leg := CapsuleMesh.new()
	leg.radius = 0.04
	leg.height = 0.24
	leg.radial_segments = 5
	leg.rings = 1
	return _compose([
		[leg, Transform3D(Basis(), Vector3(-0.045, 0.12, 0)), Color(0.35, 0.3, 0.26)],
		[leg, Transform3D(Basis(), Vector3(0.045, 0.12, 0)), Color(0.35, 0.3, 0.26)],
		[body, Transform3D(Basis(), Vector3(0, 0.42, 0)), tunic],
		[head, Transform3D(Basis(), Vector3(0, 0.7, 0)), Color(0.9, 0.75, 0.6)]])


## A column of smoke over a burning house (seen from across the field).
func _smoke() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 22
	p.lifetime = 6.0
	p.emitting = false
	p.local_coords = false
	p.direction = Vector3.UP
	p.spread = 12.0
	p.gravity = Vector3(0.12, 0.2, 0.0) # drifts a little with the wind
	p.initial_velocity_min = 0.5
	p.initial_velocity_max = 0.8
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.1
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.6))
	grow.add_point(Vector2(1, 3.2))
	p.scale_amount_curve = grow
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.3, 0.28, 0.26, 0.55))
	ramp.set_color(1, Color(0.62, 0.62, 0.62, 0.0))
	p.color_ramp = ramp
	var puff := SphereMesh.new()
	puff.radius = 0.22
	puff.height = 0.44
	puff.radial_segments = 6
	puff.rings = 3
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff.material = m
	p.mesh = puff
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


## Every frame: fire spreads with the burn, villagers run from raiders.
func _update_village(dt: float) -> void:
	var t_now := Time.get_ticks_msec() / 1000.0
	for k in _houses.size():
		if k >= sim.objectives.size():
			break
		var o: Dictionary = sim.objectives[k]
		var place: Dictionary = _houses[k]
		var lost: bool = o.lost
		var fires := 0
		for j in place.houses.size():
			var hs: Dictionary = place.houses[j]
			var burnt: bool = lost or o.progress >= hs.catch + 0.12
			var on_fire: bool = (not lost and o.progress >= hs.catch) or (lost and j % 3 == 0)
			hs.body.material_override = _house_mats.ash if burnt else hs.wall_mat
			hs.roof.material_override = _house_mats.ash_roof if burnt else hs.roof_mat
			hs.roof.scale = Vector3(1.0, 0.35, 1.0) if burnt else Vector3.ONE # the roof falls in
			hs.flame.visible = on_fire
			hs.smoke.emitting = on_fire or (lost and j % 2 == 0)
			if on_fire:
				fires += 1
				hs.flame.scale = Vector3(1.0, 1.0 + sin(t_now * 9.0 + j * 2.0) * 0.3, 1.0)
		place.glow.light_energy = (1.2 + sin(t_now * 13.0 + k) * 0.35) * minf(fires, 3) / 2.0 if fires > 0 else 0.0
		for f in place.fields:
			f.node.visible = true
			for c in f.node.get_children():
				c.material_override = _house_mats.burnt_field if lost else (_house_mats.soil if c == f.soil else f.crop_mat)
		# The banner: gold while it stands, waving harder under threat, black once burned
		var threat: bool = o.get("threat", false) or (o.progress > 0.0 and not lost)
		place.flag.material_override = _house_mats.flag_lost if lost else _house_mats.flag
		var wave := sin(t_now * (6.0 if threat else 2.0) + k) * (0.35 if threat else 0.15)
		var fb := Basis(Vector3.UP, wave)
		place.flag.transform = Transform3D(fb, place.flag_base + Vector3(0, 2.35, 0) + fb * Vector3(0.36, 0, 0))
		_update_villagers(o, place, dt)


func _update_villagers(o: Dictionary, place: Dictionary, dt: float) -> void:
	if get_tree().paused:
		dt = 0.0 # planning or paused: everyone holds still
	# Danger: an enemy close, or the place already burning
	var danger := Vector2.INF
	var best := 260.0
	for s in sim.squads:
		if is_instance_valid(s) and s.team == 1 and not s.routing:
			var d: float = s.center().distance_to(o.pos)
			if d < best:
				best = d
				danger = s.center()
	if o.progress > 0.0 and danger == Vector2.INF:
		danger = o.pos + Vector2(60, 0)
	for v in place.villagers:
		var node: MeshInstance3D = v.node
		var speed := 14.0
		if o.lost:
			node.visible = false
			continue
		if danger != Vector2.INF:
			# Run: away from the raiders, toward our lines (west)
			var away: Vector2 = (v.pos - danger).normalized() + Vector2.LEFT * 0.8
			v.goal = v.pos + away.normalized() * 40.0
			speed = 55.0
		else:
			v.wait -= dt
			if v.pos.distance_to(v.goal) < 2.0 and v.wait <= 0.0:
				v.goal = v.home + Vector2.from_angle(randf() * TAU) * randf_range(0.0, 22.0)
				v.wait = randf_range(1.5, 4.0)
			if v.pos.distance_to(o.pos) > 60.0:
				v.goal = v.home # coming back home
				speed = 30.0
		var step: Vector2 = (v.goal - v.pos).limit_length(speed * dt)
		v.pos += step
		node.visible = v.pos.distance_to(o.pos) < 230.0 # far enough: gone to safety
		var dir := Vector3(step.x, 0, step.y)
		var basis := Basis.looking_at(dir.normalized(), Vector3.UP) if dir.length() > 0.001 else node.basis
		var hop := absf(sin(Time.get_ticks_msec() / (90.0 if speed > 40.0 else 160.0))) * 0.05 if step.length() > 0.01 else 0.0
		node.transform = Transform3D(basis, ground(v.pos, hop))


# --- Camera ------------------------------------------------------------------------

## WASD / arrows pan, Q / E turn. With Shift (or Ctrl) held those letters
## are battle keys instead (Shift+A attack zone, Shift+Q/E rotate squads...).
## Panning by hand lets go of whatever the camera was following.
func _camera_keys(delta: float) -> void:
	var move := Vector2.ZERO
	var turn := 0.0
	var mod := Input.is_key_pressed(KEY_SHIFT) or Input.is_key_pressed(KEY_CTRL)
	move = Vector2(
		float(Input.is_key_pressed(KEY_RIGHT) or (Input.is_key_pressed(KEY_D) and not mod)) - float(Input.is_key_pressed(KEY_LEFT) or (Input.is_key_pressed(KEY_A) and not mod)),
		float(Input.is_key_pressed(KEY_DOWN) or (Input.is_key_pressed(KEY_S) and not mod)) - float(Input.is_key_pressed(KEY_UP) or (Input.is_key_pressed(KEY_W) and not mod)))
	if not mod:
		turn = float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q))
	if move != Vector2.ZERO:
		following = false
	_drive(move, turn, delta)


## Hold-right-drag panning: the ground point under the mouse at the press
## stays under the mouse while it moves.
var _grab := Vector3.ZERO
var _grab_y := 0.0


func begin_grab(screen: Vector2) -> void:
	_grab_y = height_at(Vector2(target.x, target.z) / S)
	_grab = _plane_hit(screen, _grab_y)


func drag_grab(screen: Vector2) -> void:
	following = false
	var d := _grab - _plane_hit(screen, _grab_y)
	d.y = 0.0
	target_goal = target + d
	_clamp_goal()
	target = target_goal
	_place_camera()


func _plane_hit(screen: Vector2, y: float) -> Vector3:
	var o := cam.project_ray_origin(screen)
	var dir := cam.project_ray_normal(screen)
	if dir.y > -0.02:
		dir.y = -0.02 # toward the horizon: stop a long way out
	return o + dir * ((y - o.y) / dir.y)


func focus(p: Vector2) -> void:
	target_goal = Vector3(p.x * S, 0.0, p.y * S)
	dist_goal = minf(dist_goal, 18.0)


## Follow the selected squads (F): one squad = ride along behind it; several
## = keep them all in view. Follows whatever is selected while it's on.
func follow_selected(on: bool) -> void:
	following = on
	yaw_touched = false
	_fit = 1.0
	if on and _followed().size() == 1 and dist_goal > 22.0:
		dist_goal = 12.0


func _followed() -> Array:
	var list := []
	for s in sim.selected:
		if is_instance_valid(s) and not s._m.is_empty():
			list.append(s)
	return list


func _update_follow(delta: float) -> void:
	if not following:
		return
	var list := _followed()
	if list.is_empty():
		return
	var c := Vector2.ZERO
	for s in list:
		c += s.center()
	c /= list.size()
	target_goal = Vector3(c.x * S, 0.0, c.y * S)
	if list.size() == 1:
		if not yaw_touched:
			# Swing round behind it, the way it faces
			var r: float = list[0].rotation
			yaw = lerp_angle(yaw, atan2(-cos(r), -sin(r)), 1.0 - exp(-delta * 2.0))
	else:
		var reach := 0.0
		for s in list:
			reach = maxf(reach, c.distance_to(s.center()) + s.half_size().length())
		dist_goal = clampf((reach * S * 2.3 + 5.0) * _fit, MIN_DIST, MAX_DIST)


## While following several squads the wheel widens or tightens the framing.
func _zoom(f: float, screen: Vector2) -> void:
	if following and _followed().size() > 1:
		_fit = clampf(_fit * f, 0.4, 3.0)
		return
	if following:
		dist_goal = clampf(dist_goal * f, MIN_DIST, MAX_DIST) # stay on it, don't drift to the cursor
		return
	super(f, screen)


func _process(delta: float) -> void:
	_update_follow(delta)
	super(delta)


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
	var g := 0
	var crests := 0
	var banners := 0
	var dt := get_process_delta_time()
	var seen := {}
	var paused := get_tree().paused
	for s in sim.squads:
		if not is_instance_valid(s) or s.concealed:
			continue
		var squad_face := Vector2.RIGHT.rotated(s.rotation)
		var base_c: Color = s.color
		if s.routing:
			base_c = base_c.darkened(0.3)
		var t_now := Time.get_ticks_msec() / 1000.0
		var engaged: bool = (s.in_contact or s._fighting > 0) and not s.routing
		var ghost: bool = s.team == 0 and s.is_hidden() # unseen by the enemy: see-through
		var A := GHOST_ALPHA if ghost else 1.0
		for m in s._m:
			var P: Dictionary = _ghost if ghost else _parts
			var idx := g if ghost else i
			if idx >= (MAX_GHOSTS if ghost else MAX_MEN):
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
			var walking := speed > 8.0 and not paused
			if walking:
				phase += dt * clampf(speed * 0.16, 6.0, 14.0)
			_gait[m] = phase
			var stride := sin(phase) * (0.55 if walking else 0.0)
			var bob := absf(sin(phase)) * 0.04 if walking else 0.0
			var t := Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), ground(m.pos, bob))
			var flash: bool = m.flash > 0.0
			var c := base_c.lerp(Color.WHITE, 0.75) if flash else base_c
			var fighting: bool = m.target != null
			var support: bool = fighting and m.support
			var ready := engaged and not fighting # waiting his turn behind the front
			var jitter := float(m.get_instance_id() % 97) # each man's own rhythm
			var thrust: float = sin(m.swing / Squad.SWING_ANIM * PI) * 0.34 if m.swing > 0.0 else 0.0
			var feint := sin(t_now * 5.0 + jitter) * 0.04 if fighting and m.swing <= 0.0 else 0.0
			var sway := sin(t_now * 2.6 + jitter) * 0.035 if ready else 0.0

			P.leg_l.set_instance_transform(idx, t * Transform3D(Basis(Vector3.RIGHT, stride), Vector3(-0.075, 0.36, 0)))
			P.leg_r.set_instance_transform(idx, t * Transform3D(Basis(Vector3.RIGHT, -stride), Vector3(0.075, 0.36, 0)))
			var trousers := c.darkened(0.5)
			P.leg_l.set_instance_color(idx, Color(trousers, A))
			P.leg_r.set_instance_color(idx, Color(trousers, A))
			var lean_a := -0.05 if walking else 0.0
			if fighting:
				lean_a = -0.12 - thrust * 0.5
			elif ready:
				lean_a = -0.1 + sway
			var lean := Basis(Vector3.RIGHT, lean_a)
			P.torso.set_instance_transform(idx, t * Transform3D(lean, Vector3.ZERO))
			P.torso.set_instance_color(idx, Color(c, A))
			P.head.set_instance_transform(idx, t * Transform3D(lean, lean * Vector3(0, 0.85, 0)))
			P.head.set_instance_color(idx, Color(Color.WHITE if flash else SKIN[m.get_instance_id() % SKIN.size()], A))
			P.helmet.set_instance_transform(idx, t * Transform3D(lean, Vector3.ZERO))
			P.helmet.set_instance_color(idx, Color(Color.WHITE if flash else Color(0.62, 0.63, 0.66), A))
			if s.is_commander and crests < 64 and not ghost:
				_crests.set_instance_transform(crests, t * Transform3D(lean, lean * Vector3(0, 0.995, 0.02)))
				_crests.set_instance_color(crests, Color(0.95, 0.75, 0.25))
				crests += 1

			# Spear in the right hand: leveled to fight, upright to march, trailing in a rout
			var swing_arm := sin(phase) * 0.05 if walking else 0.0
			var hand_r := Vector3(0.2, 0.47, -0.1 + swing_arm)
			var level := -0.12
			if support:
				# Overhand, over the front rank's shoulders
				hand_r = Vector3(0.19, 0.8, -0.12 - thrust * 1.2 - feint)
				level = -1.62
			elif fighting:
				hand_r = Vector3(0.2, 0.6, -0.2 - thrust - feint)
				level = -1.35
			elif ready:
				hand_r = Vector3(0.2, 0.62, -0.16 + sway)
				level = -0.95 # lowered toward the enemy, waiting
			if s.routing:
				level = 0.5
				hand_r = Vector3(0.2, 0.45, 0.05)
			var spear_b := Basis(Vector3.RIGHT, level)
			P.spear.set_instance_transform(idx, t * Transform3D(spear_b, hand_r))
			P.spear.set_instance_color(idx, Color(Color.WHITE, A))
			P.arm_r.set_instance_transform(idx, t * _limb(lean * Vector3(0.17, 0.7, 0), hand_r, 0.3))
			# Shield on the left arm: up in front to fight, at the side to march
			var guard := fighting or ready
			var hand_l := Vector3(-0.16, 0.6, -0.22 + sway) if guard else Vector3(-0.2, 0.5, -0.1 - swing_arm)
			var shield_b := Basis(Vector3.RIGHT, PI / 2.0) if guard else Basis(Vector3.UP, 0.9) * Basis(Vector3.RIGHT, PI / 2.0)
			if m.block > 0.0:
				# Catching a blow: shield jerks up and out
				var k := sin(m.block / 0.25 * PI)
				hand_l += Vector3(0.03, 0.06, -0.08) * k
				shield_b = Basis(Vector3.RIGHT, PI / 2.0 - 0.35 * k)
			var shield_at := hand_l + (Vector3(0, 0, -0.05) if guard else Vector3(-0.05, 0, 0))
			P.shield.set_instance_transform(idx, t * Transform3D(shield_b, shield_at))
			P.shield.set_instance_color(idx, Color(c, A)) # the shield carries the team colour
			P.boss.set_instance_transform(idx, t * Transform3D(shield_b, shield_at + shield_b * Vector3(0, 0.025, 0)))
			P.boss.set_instance_color(idx, Color(Color(0.7, 0.68, 0.6), A))
			P.arm_l.set_instance_transform(idx, t * _limb(lean * Vector3(-0.17, 0.7, 0), hand_l, 0.3))
			var sleeve := c.darkened(0.15)
			P.arm_l.set_instance_color(idx, Color(sleeve, A))
			P.arm_r.set_instance_color(idx, Color(sleeve, A))
			if ghost:
				g += 1
			else:
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
	for p in _ghost.values():
		p.visible_instance_count = g
	# From far up, arms and shield bosses are a pixel: skip them
	var far := dist > FAR_DETAIL
	for k in ["arm_l", "arm_r", "boss"]:
		if far:
			_parts[k].visible_instance_count = 0
			_ghost[k].visible_instance_count = 0
	_crests.visible_instance_count = crests
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
		_corpse_mm.set_instance_transform(k, Transform3D(Basis(Vector3.UP, atan2(-f.y, f.x)), ground(cp.pos)))
		_corpse_mm.set_instance_color(k, Color(cp.color).darkened(0.35))
	_corpse_mm.visible_instance_count = n

	# Messengers galloping out
	var r := 0
	var now := Time.get_ticks_msec() / 1000.0
	for o in sim.pending:
		if r >= MAX_RIDERS or not is_instance_valid(o.squad):
			continue
		var from: Vector2 = sim.commander.center() if is_instance_valid(sim.commander) else o.squad.center()
		var progress := 1.0 - float(o.left) / float(o.total)
		var at: Vector2 = from.lerp(o.squad.center(), progress)
		var dir: Vector2 = o.squad.center() - from
		var fw := Vector3(dir.x, 0, dir.y)
		if fw.length() < 0.01:
			fw = Vector3.FORWARD
		var gallop := now * 11.0 + r
		var bt := Transform3D(Basis.looking_at(fw.normalized(), Vector3.UP), ground(at, absf(sin(gallop)) * 0.08))
		_riders.set_instance_transform(r, bt)
		_riders.set_instance_color(r, Color.WHITE)
		var hips := [Vector3(-0.1, 0.6, -0.28), Vector3(0.1, 0.6, -0.28), Vector3(-0.1, 0.6, 0.3), Vector3(0.1, 0.6, 0.3)]
		for k in 4:
			var kick := sin(gallop + (0.0 if k < 2 else PI) + (0.5 if k % 2 == 1 else 0.0)) * 0.7
			_horse_legs.set_instance_transform(r * 4 + k, bt * Transform3D(Basis(Vector3.RIGHT, kick), hips[k]))
			_horse_legs.set_instance_color(r * 4 + k, Color.WHITE)
		r += 1
	_riders.visible_instance_count = r
	_horse_legs.visible_instance_count = r * 4

	_update_village(get_process_delta_time())


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
		if not o.lost and (o.get("threat", false) or o.progress > 0.0):
			# Danger: a pulsing red ring, and the raiders' path to it
			var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 160.0)
			var rr: float = b.OBJ_RADIUS + 9.0 + pulse * 6.0
			_arc(tris, o.pos, rr, rr + 3.0, 0.0, TAU, Color(1.0, 0.3, 0.2, 0.35 + 0.5 * pulse))
			var raider = o.get("raider")
			if raider != null and is_instance_valid(raider):
				var from: Vector2 = raider.center()
				var to: Vector2 = o.pos + (from - o.pos).normalized() * b.OBJ_RADIUS
				if from.distance_to(o.pos) > b.OBJ_RADIUS:
					_dashed(lines, from, to, Color(1.0, 0.35, 0.25, 0.9), 10.0, 8.0)
					var dd := (to - from).normalized()
					_tri(tris, to, to - dd.rotated(0.45) * 14.0, to - dd.rotated(-0.45) * 14.0, Color(1.0, 0.35, 0.25, 0.9))

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

## A village place in danger: a pulsing "!" over it when it's on screen,
## otherwise a red arrow on the edge of the screen pointing the way.
func _danger_marker(ci: Control, o: Dictionary) -> void:
	var vp := get_viewport().get_visible_rect().size
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 160.0)
	var red := Color(1.0, 0.32, 0.22)
	var what: String = ("%s  burning %d%%" % [o.name, roundi(o.progress * 100.0)]) if o.progress > 0.0 else ("%s  raiders coming" % o.name)
	var world := ground(o.pos, 2.8)
	var behind := cam.is_position_behind(world)
	var sp := cam.unproject_position(world)
	var inner := Rect2(Vector2(30, 60), vp - Vector2(60, 60 + 130)) # clear of the top bar and the cards
	if not behind and inner.has_point(sp):
		ci.draw_circle(sp, 13.0 + pulse * 3.0, Color(red, 0.85))
		_label(ci, sp + Vector2(0, 7), "!", 20, Color.WHITE, 30.0)
		_label(ci, sp + Vector2(0, -20), what, 13, Color(1.0, 0.75, 0.65), 260.0)
		return
	# Off screen: which way is it?
	var mid := vp / 2.0
	var dir := (sp - mid)
	if behind:
		dir = -dir
	if dir.length() < 1.0:
		dir = Vector2.DOWN
	dir = dir.normalized()
	# Where that direction leaves the inner rectangle
	var half := inner.size / 2.0
	var c := inner.get_center()
	var t := minf(absf(half.x / dir.x) if dir.x != 0.0 else INF, absf(half.y / dir.y) if dir.y != 0.0 else INF)
	var at := c + dir * t
	var tip := at + dir * 12.0
	var side := dir.orthogonal() * 11.0
	ci.draw_colored_polygon(PackedVector2Array([tip, at - dir * 8.0 + side, at - dir * 8.0 - side]), Color(red, 0.7 + 0.3 * pulse))
	var lab_at := at - dir * 34.0
	_label(ci, lab_at + Vector2(0, 5), what, 13, Color(1.0, 0.75, 0.65), 240.0)

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
		if not o.lost and (o.get("threat", false) or o.progress > 0.0):
			_danger_marker(ci, o)

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
			if sp.get("block", false):
				# Parried: a small bright clink
				for k in 3:
					var d := Vector2.from_angle(k * TAU / 3.0 + 0.3)
					ci.draw_line(q + d * 1.5, q + d * 4.5, Color(0.85, 0.92, 1.0, a), 1.2)
				continue
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

	if following and not _followed().is_empty():
		var vw := get_viewport().get_visible_rect().size.x
		_label(ci, Vector2(vw / 2.0, 62), "FOLLOWING  (F or arrows to stop)", 13, Color(1.0, 0.9, 0.45, 0.95), 360.0)

	# Selection box (on the screen)
	if b._dragging and not b._zone_mode and b._drag_screen_start.distance_to(screen_mouse) > 6.0:
		var r := Rect2(b._drag_screen_start, screen_mouse - b._drag_screen_start).abs()
		ci.draw_rect(r, Color(b.BOX_COLOR, 0.12), true)
		ci.draw_rect(r, Color(b.BOX_COLOR, 0.9), false, 1.5)
