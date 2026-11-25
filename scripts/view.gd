class_name View
extends RefCounted
## The 2.5D look. The game itself is played on a flat map (MAP_SIZE); the
## camera squashes it vertically by TILT so the field looks seen at an angle.
## Anything that should stand upright (soldiers, banners, trees, text) is
## drawn with the squash undone, so it keeps its height on screen.

const TILT := 0.62 # 1.0 = straight down; smaller = flatter angle
const MAP_SIZE := Vector2(1280, 1160) # 1160 * 0.62 ~ 720 px of screen

## Scale to pass to draw_set_transform so drawing comes out upright on screen.
static func upright_scale() -> Vector2:
	return Vector2(1.0, 1.0 / TILT)


## A world-space offset as it will appear on screen (y squashed).
static func to_screen(v: Vector2) -> Vector2:
	return Vector2(v.x, v.y * TILT)
