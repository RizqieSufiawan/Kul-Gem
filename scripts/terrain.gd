class_name Terrain
extends RefCounted
## The battlefield's terrain: one place for both the rules (speed, combat,
## hiding) and the shapes the Battlefield draws. All positions are map
## coordinates (View.MAP_SIZE).

# --- Shapes ------------------------------------------------------------------

## Forests: each a few overlapping circles [x, y, radius]
const FORESTS := [
	[[520, 250, 72], [585, 305, 60], [468, 315, 55], [545, 365, 45]], # between the armies, our side: ambush cover
	[[1010, 905, 80], [948, 965, 60], [1078, 965, 58]], # enemy side, south
	[[228, 1035, 58], [300, 1072, 50], [170, 1090, 40]], # behind our south flank
]
## Hills: [x, y, radius]; height 1 at the top, 0 at the foot
const HILLS := [
	[905, 335, 190], # enemy side, north: they look down on the middle
	[395, 905, 150], # our side, south
]
const STREAM_HALF_WIDTH := 22.0
## Shallow fords (y of their middle): the only crossings besides the bridge.
## Slow, bad footing, but they keep the bridge from being the whole battle.
const FORDS := [190.0, 935.0]
const FORD_HALF_LENGTH := 30.0
const ROAD_HALF_WIDTH := 22.0
const BRIDGE_HALF_LENGTH := 34.0 # along the stream

# --- Effects -----------------------------------------------------------------

const FOREST_SPEED := 0.65
const STREAM_SPEED := 0.5
const ROAD_SPEED := 1.15
const FOREST_DAMAGE_TAKEN := 0.8 # cover
const HEIGHT_DAMAGE := 0.4 # x(1 + 0.4 * height difference), difference capped at 0.5
const WATER_DAMAGE_DEALT := 0.75
const WATER_DAMAGE_TAKEN := 1.15
const FOREST_HIDE_RADIUS := 150.0 # enemies closer than this see you in the forest


static func road_y(x: float) -> float:
	return 600.0 + sin(x * 0.0055) * 130.0 + sin(x * 0.017 + 1.3) * 28.0


static func stream_x(y: float) -> float:
	return 720.0 + sin(y * 0.005) * 45.0 + sin(y * 0.013 + 0.7) * 12.0


static var _bridge := Vector2.INF


## Where the road crosses the stream (computed once, then remembered).
static func bridge_point() -> Vector2:
	if _bridge != Vector2.INF:
		return _bridge
	var best := Vector2.ZERO
	var best_err := INF
	var y := 0.0
	while y <= View.MAP_SIZE.y:
		var x := stream_x(y)
		var err := absf(road_y(x) - y)
		if err < best_err:
			best_err = err
			best = Vector2(x, y)
		y += 1.0
	_bridge = best
	return best


static func in_forest(p: Vector2) -> bool:
	for forest in FORESTS:
		for c in forest:
			if p.distance_to(Vector2(c[0], c[1])) < c[2]:
				return true
	return false


static func height(p: Vector2) -> float:
	var h := 0.0
	for hill in HILLS:
		var d := p.distance_to(Vector2(hill[0], hill[1])) / float(hill[2])
		if d < 1.0:
			h = maxf(h, smoothstep(0.0, 1.0, 1.0 - d))
	return h


## Deep water: nobody can stand here.
static func in_water(p: Vector2) -> bool:
	return in_stream(p) and not on_ford(p)


## Anywhere in the stream but the bridge (fords included): slow, bad footing.
static func in_stream(p: Vector2) -> bool:
	return absf(p.x - stream_x(p.y)) < STREAM_HALF_WIDTH and not on_bridge(p)


static func on_ford(p: Vector2) -> bool:
	if absf(p.x - stream_x(p.y)) >= STREAM_HALF_WIDTH + 6.0:
		return false
	for fy in FORDS:
		if absf(p.y - fy) < FORD_HALF_LENGTH:
			return true
	return false


static func on_crossing(p: Vector2) -> bool:
	return on_bridge(p) or on_ford(p)


## Every way across: [middle point, half its length along the stream].
static func crossings() -> Array:
	var out := [[bridge_point(), BRIDGE_HALF_LENGTH]]
	for fy in FORDS:
		out.append([Vector2(stream_x(fy), fy), FORD_HALF_LENGTH])
	return out


static func on_bridge(p: Vector2) -> bool:
	var b := bridge_point()
	return absf(p.x - stream_x(p.y)) < STREAM_HALF_WIDTH + 6.0 and absf(p.y - b.y) < BRIDGE_HALF_LENGTH


## Which bank of the stream `p` is on: -1 west (ours), +1 east.
static func bank_side(p: Vector2) -> int:
	return -1 if p.x < stream_x(p.y) else 1


## A dry point on `side`'s bank, level with `p`.
static func bank_point(p: Vector2, side: int, margin := 18.0) -> Vector2:
	return Vector2(stream_x(p.y) + side * (STREAM_HALF_WIDTH + margin), p.y)


## The stream can only be crossed at the bridge or a ford. Where to head
## next on the way from `from` to `to`: straight there on the same bank,
## otherwise the near end of the crossing that makes the shortest trip,
## then across it.
static func waypoint(from: Vector2, to: Vector2) -> Vector2:
	var sf := bank_side(from)
	var st := bank_side(to)
	for cr in crossings():
		var c: Vector2 = cr[0]
		var half: float = cr[1]
		var at := absf(from.y - c.y) < half - 8.0 and absf(from.x - stream_x(from.y)) < STREAM_HALF_WIDTH + 34.0
		if at:
			if sf == st:
				return to
			return Vector2(stream_x(c.y) + st * (STREAM_HALF_WIDTH + 40.0), c.y) # across
	if sf == st:
		return to
	var best := Vector2.ZERO
	var best_len := INF
	for cr in crossings():
		var c: Vector2 = cr[0]
		var trip := from.distance_to(c) + c.distance_to(to)
		if trip < best_len:
			best_len = trip
			best = c
	return Vector2(stream_x(best.y) + sf * (STREAM_HALF_WIDTH + 30.0), best.y)


static func on_road(p: Vector2) -> bool:
	return absf(p.y - road_y(p.x)) < ROAD_HALF_WIDTH


static func speed_mult(p: Vector2) -> float:
	if in_stream(p):
		return STREAM_SPEED
	if in_forest(p):
		return FOREST_SPEED
	if on_road(p) or on_bridge(p):
		return ROAD_SPEED
	return 1.0


## Damage multiplier for an attacker standing at `from` hitting a defender at `at`.
static func damage_mult(from: Vector2, at: Vector2) -> float:
	var m := 1.0 + HEIGHT_DAMAGE * clampf(height(from) - height(at), -0.5, 0.5)
	if in_forest(at):
		m *= FOREST_DAMAGE_TAKEN
	if in_stream(from):
		m *= WATER_DAMAGE_DEALT
	if in_stream(at):
		m *= WATER_DAMAGE_TAKEN
	return m


## Short name of the ground at `p`, for tooltips and cards.
static func describe(p: Vector2) -> String:
	if on_bridge(p):
		return "bridge"
	if on_ford(p):
		return "ford"
	if in_water(p):
		return "stream"
	if in_forest(p):
		return "forest"
	if height(p) > 0.35:
		return "hill"
	if on_road(p):
		return "road"
	return "field"
