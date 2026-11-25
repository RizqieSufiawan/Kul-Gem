class_name Battlefield
extends Node2D
## The ground: a grassy field with a dirt road, tufts and stones, drawn once.
## Also keeps the marks left where soldiers fell (drawn on a separate layer
## so the field itself never has to be redrawn).

const SIZE := View.MAP_SIZE
const GRASS := Color(0.34, 0.43, 0.26)
const ROAD := Color(0.50, 0.42, 0.30)
const MAX_FALLEN := 500

var _fallen: Array = [] # [position, color, angle]
var _fallen_layer: Node2D


func _ready() -> void:
	z_index = -20
	_fallen_layer = Node2D.new()
	_fallen_layer.z_index = 1 # above the ground, still below every squad
	_fallen_layer.draw.connect(_draw_fallen)
	add_child(_fallen_layer)
	queue_redraw()


## A soldier fell here: leave a small mark on the ground.
func add_fallen(pos: Vector2, color: Color) -> void:
	var jitter := Vector2(randf_range(-4.0, 4.0), randf_range(-4.0, 4.0))
	_fallen.append([pos + jitter, color, randf() * TAU])
	if _fallen.size() > MAX_FALLEN:
		_fallen.pop_front()
	_fallen_layer.queue_redraw()


func _draw() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337 # same field every battle

	draw_rect(Rect2(Vector2.ZERO, SIZE), GRASS)

	# Large soft patches of lighter and darker grass
	# (several stacked circles per patch so the edges fade instead of showing a rim)
	for i in 90:
		var p := Vector2(rng.randf() * SIZE.x, rng.randf() * SIZE.y)
		var r := rng.randf_range(50.0, 150.0)
		var shade := rng.randf_range(-0.07, 0.07)
		var c := GRASS.lightened(shade) if shade > 0.0 else GRASS.darkened(-shade)
		c.a = 0.07
		for k in 4:
			draw_circle(p, r * (1.0 - k * 0.2), c)

	_draw_hills()

	# A dirt road winding across the field
	var road := PackedVector2Array()
	var x := 0.0
	while x <= SIZE.x:
		road.append(Vector2(x, Terrain.road_y(x)))
		x += 20.0
	draw_polyline(road, Color(ROAD.darkened(0.25), 0.45), 50.0, true)
	draw_polyline(road, Color(ROAD, 0.70), 40.0, true)
	draw_polyline(road, Color(ROAD.lightened(0.12), 0.35), 18.0, true)

	_draw_stream()
	_draw_fords()
	_draw_bridge()
	_draw_forest_floor()

	# Grass tufts
	for i in 1600:
		var p := Vector2(rng.randf() * SIZE.x, rng.randf() * SIZE.y)
		var c := GRASS.darkened(rng.randf_range(0.15, 0.35)) if rng.randf() < 0.6 else GRASS.lightened(rng.randf_range(0.10, 0.25))
		c.a = 0.75
		var h := rng.randf_range(2.5, 5.0)
		draw_set_transform(p, 0.0, View.upright_scale()) # blades stand up
		draw_line(Vector2.ZERO, Vector2(-1.2, -h), c, 1.0)
		draw_line(Vector2.ZERO, Vector2(1.3, -h * 0.9), c, 1.0)
		draw_set_transform(Vector2.ZERO, 0.0)

	# Stones
	for i in 26:
		var p := Vector2(rng.randf() * SIZE.x, rng.randf() * SIZE.y)
		if Terrain.in_water(p) or Terrain.in_forest(p) or Terrain.on_road(p) or Terrain.on_bridge(p):
			continue
		var r := rng.randf_range(2.5, 6.0)
		draw_circle(p + Vector2(1.5, 1.5), r, Color(0, 0, 0, 0.25))
		draw_circle(p, r, Color(0.58, 0.57, 0.52))
		draw_circle(p - Vector2(r * 0.3, r * 0.3), r * 0.45, Color(0.70, 0.69, 0.64))

	_draw_trees(rng)

	# Vignette: a smooth fade to darker at the edges
	var edge := Color(0, 0, 0, 0.38)
	var clear := Color(0, 0, 0, 0.0)
	var d := 170.0
	var o := [Vector2.ZERO, Vector2(SIZE.x, 0), SIZE, Vector2(0, SIZE.y)]
	var i_ := [Vector2(d, d), Vector2(SIZE.x - d, d), SIZE - Vector2(d, d), Vector2(d, SIZE.y - d)]
	for k in 4:
		var n := (k + 1) % 4
		draw_polygon(PackedVector2Array([o[k], o[n], i_[n], i_[k]]),
			PackedColorArray([edge, edge, clear, clear]))


# --- Terrain ---------------------------------------------------------------

## Hills: stacked lighter discs (the camera turns them into a mound seen at an
## angle), a shadow on the far side, and contour rings.
func _draw_hills() -> void:
	for hill in Terrain.HILLS:
		var c := Vector2(hill[0], hill[1])
		var r: float = hill[2]
		draw_circle(c + Vector2(18, 26), r, Color(0, 0, 0, 0.10)) # shade on the lee side
		for k in 8:
			var t := k / 8.0
			var col := GRASS.lightened(0.03 + t * 0.16)
			col.a = 0.55
			draw_circle(c - Vector2(6, 10) * t, r * (1.0 - t * 0.85), col)
		for k in range(1, 4):
			draw_arc(c - Vector2(6, 10) * (k / 4.0), r * (1.0 - k * 0.22), 0.0, TAU, 72,
				Color(GRASS.darkened(0.25), 0.35), 1.2)


func _draw_stream() -> void:
	var bank := PackedVector2Array()
	var water := PackedVector2Array()
	var y := -10.0
	while y <= SIZE.y + 10.0:
		water.append(Vector2(Terrain.stream_x(y), y))
		y += 12.0
	var w := Terrain.STREAM_HALF_WIDTH * 2.0
	draw_polyline(water, Color(0.30, 0.27, 0.18, 0.8), w + 10.0, true) # muddy banks
	draw_polyline(water, Color(0.22, 0.42, 0.55), w, true)
	draw_polyline(water, Color(0.32, 0.55, 0.68, 0.8), w * 0.55, true)
	# glints on the water
	for i in range(0, water.size(), 3):
		var p := water[i] + Vector2(-6 + (i * 7) % 13, 0)
		draw_line(p, p + Vector2(7, 0), Color(0.75, 0.88, 0.95, 0.6), 1.2)


## Shallow, sandy crossings with stepping stones.
func _draw_fords() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for fy in Terrain.FORDS:
		var x := Terrain.stream_x(fy)
		var hw := Terrain.STREAM_HALF_WIDTH + 6.0
		var hl := Terrain.FORD_HALF_LENGTH
		draw_rect(Rect2(x - hw, fy - hl, hw * 2.0, hl * 2.0), Color(0.62, 0.58, 0.42, 0.85))
		draw_rect(Rect2(x - hw + 4, fy - hl + 4, hw * 2.0 - 8, hl * 2.0 - 8), Color(0.45, 0.62, 0.66, 0.55))
		for k in 9:
			var p := Vector2(x + rng.randf_range(-hw + 6, hw - 6), fy + rng.randf_range(-hl + 6, hl - 6))
			draw_circle(p + Vector2(1, 1.5), 3.5, Color(0, 0, 0, 0.25))
			draw_circle(p, 3.5, Color(0.6, 0.58, 0.52))


func _draw_bridge() -> void:
	var b := Terrain.bridge_point()
	var along := Vector2(1.0, Terrain.road_y(b.x + 1.0) - Terrain.road_y(b.x - 1.0)).normalized()
	var across := along.orthogonal()
	var half_len := Terrain.STREAM_HALF_WIDTH + 14.0
	var half_w := Terrain.BRIDGE_HALF_LENGTH
	var corners := PackedVector2Array([
		b - along * half_len - across * half_w, b + along * half_len - across * half_w,
		b + along * half_len + across * half_w, b - along * half_len + across * half_w])
	draw_colored_polygon(PackedVector2Array([corners[0] + Vector2(3, 5), corners[1] + Vector2(3, 5), corners[2] + Vector2(3, 5), corners[3] + Vector2(3, 5)]), Color(0, 0, 0, 0.3))
	draw_colored_polygon(corners, Color(0.55, 0.40, 0.25))
	# planks
	var n := 10
	for k in n + 1:
		var t := -half_len + k * (2.0 * half_len / n)
		draw_line(b + along * t - across * half_w, b + along * t + across * half_w, Color(0.38, 0.27, 0.16), 1.2)
	# rails
	draw_line(corners[0], corners[1], Color(0.33, 0.23, 0.13), 3.0)
	draw_line(corners[3], corners[2], Color(0.33, 0.23, 0.13), 3.0)


func _draw_forest_floor() -> void:
	for forest in Terrain.FORESTS:
		for c in forest:
			var col := GRASS.darkened(0.3)
			col.a = 0.5
			draw_circle(Vector2(c[0], c[1]), c[2] + 6.0, col)


## Trees stand upright; drawn back to front.
func _draw_trees(rng: RandomNumberGenerator) -> void:
	var trees: Array[Vector2] = []
	for forest in Terrain.FORESTS:
		for c in forest:
			var center := Vector2(c[0], c[1])
			var r: float = c[2]
			var count := int(r * r / 260.0)
			for k in count:
				var p := center + Vector2.RIGHT.rotated(rng.randf() * TAU) * sqrt(rng.randf()) * (r - 6.0)
				trees.append(p)
	trees.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.y < b.y)
	var up := View.upright_scale()
	for p in trees:
		var size := rng.randf_range(0.85, 1.25)
		var dark := Color(0.16, 0.30, 0.14).lerp(Color(0.12, 0.24, 0.12), rng.randf())
		var light := dark.lightened(0.25)
		draw_circle(p + Vector2(4, 2), 9.0 * size, Color(0, 0, 0, 0.25)) # shadow on the ground
		draw_set_transform(p, 0.0, up)
		draw_line(Vector2.ZERO, Vector2(0, -8 * size), Color(0.35, 0.25, 0.15), 2.5)
		draw_circle(Vector2(0, -16) * size, 9.0 * size, dark.darkened(0.2))
		draw_circle(Vector2(-3, -19) * size, 7.0 * size, dark)
		draw_circle(Vector2(2, -22) * size, 5.5 * size, light)
		draw_set_transform(Vector2.ZERO, 0.0)


func _draw_fallen() -> void:
	for m in _fallen:
		var pos: Vector2 = m[0]
		var c: Color = m[1]
		var a: float = m[2]
		var body := c.darkened(0.5).lerp(Color(0.3, 0.3, 0.28), 0.4)
		# a body lying on its side: a short smudge, plus a dropped spear
		var along := Vector2.RIGHT.rotated(a)
		_fallen_layer.draw_line(pos - along * 2.5, pos + along * 2.5, Color(body, 0.6), 4.0)
		_fallen_layer.draw_line(pos - along.orthogonal() * 4.0 - along * 3.0, pos + along.orthogonal() * 4.0 + along * 5.0,
			Color(0.42, 0.34, 0.24, 0.55), 1.0)
