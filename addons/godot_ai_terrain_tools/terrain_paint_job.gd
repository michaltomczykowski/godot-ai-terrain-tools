@tool
extends RefCounted

var _data: Resource
var _strokes: Array
var _size: int
var _cell: float
var _half: float
var _stroke_index := 0
var _x := 0
var _z := 0
var _min_x := 0
var _max_x := -1
var _min_z := 0
var _max_z := -1
var _changed := {}
var _done := false


func _init(data: Resource, strokes: Array) -> void:
	_data = data
	_strokes = strokes
	_size = int(data.params.size)
	_cell = float(data.params.cell_size)
	_half = (_size - 1) * _cell * 0.5
	_begin_stroke()


func step(budget_usec: int = 3000) -> bool:
	var started := Time.get_ticks_usec()
	while not _done and Time.get_ticks_usec() - started < budget_usec:
		if _stroke_index >= _strokes.size():
			_done = true
			break
		if _z > _max_z:
			_stroke_index += 1
			_begin_stroke()
			continue
		var stroke: Dictionary = _strokes[_stroke_index]
		var index := _z * _size + _x
		_x += 1
		if _x > _max_x:
			_x = _min_x
			_z += 1
		if _data.holes[index] != 0:
			continue
		var x: int = index % _size
		var z: int = int(index / _size)
		var position := Vector2(x * _cell - _half, z * _cell - _half)
		var distance := _distance_to_polyline(stroke.points, position)
		if distance > stroke.radius:
			continue
		var weight: float = 1.0 - distance / float(stroke.radius)
		if stroke.falloff == "smooth":
			weight = weight * weight * (3.0 - 2.0 * weight)
		var amount: float = float(stroke.strength) * weight
		if amount > 0.0:
			_paint_sample(index, stroke.layer, amount)
			_changed[index] = true
	return _done


func _begin_stroke() -> void:
	if _stroke_index >= _strokes.size():
		return
	var stroke: Dictionary = _strokes[_stroke_index]
	var radius: float = float(stroke.radius)
	var min_world := Vector2(INF, INF)
	var max_world := Vector2(-INF, -INF)
	for point_value in stroke.points:
		var point: Vector2 = point_value
		min_world.x = minf(min_world.x, point.x)
		min_world.y = minf(min_world.y, point.y)
		max_world.x = maxf(max_world.x, point.x)
		max_world.y = maxf(max_world.y, point.y)
	_min_x = clampi(int(floor((min_world.x - radius + _half) / _cell)), 0, _size - 1)
	_max_x = clampi(int(ceil((max_world.x + radius + _half) / _cell)), 0, _size - 1)
	_min_z = clampi(int(floor((min_world.y - radius + _half) / _cell)), 0, _size - 1)
	_max_z = clampi(int(ceil((max_world.y + radius + _half) / _cell)), 0, _size - 1)
	_x = _min_x
	_z = _min_z


func result() -> Dictionary:
	return {"affected_vertices": _changed.size()} if _done else {}


func _paint_sample(index: int, layer: String, amount: float) -> void:
	amount = clampf(amount, 0.0, 1.0)
	if layer == "auto":
		_data.paint_coverage[index] = maxf(0.0, _data.paint_coverage[index] - amount)
		if is_zero_approx(_data.paint_coverage[index]):
			_data.paint_weights[index] = Color(0.0, 0.0, 0.0, 0.0)
		return
	var target := _layer_weights(layer)
	var current: Color = _data.paint_weights[index]
	if current.r + current.g + current.b + current.a <= 0.00001:
		current = target
	else:
		current = _normalized_weights(current).lerp(target, amount)
	_data.paint_weights[index] = _normalized_weights(current)
	_data.paint_coverage[index] = lerpf(_data.paint_coverage[index], 1.0, amount)


static func _layer_weights(layer: String) -> Color:
	match layer:
		"road": return Color(0.0, 1.0, 0.0, 0.0)
		"rock": return Color(0.0, 0.0, 1.0, 0.0)
		"snow": return Color(0.0, 0.0, 0.0, 1.0)
		_: return Color(1.0, 0.0, 0.0, 0.0)


static func _normalized_weights(value: Color) -> Color:
	var total := value.r + value.g + value.b + value.a
	return value / total if total > 0.00001 else Color(1.0, 0.0, 0.0, 0.0)


static func _distance_to_polyline(points: Array, position: Vector2) -> float:
	if points.size() == 1:
		return position.distance_to(points[0])
	var best := INF
	for index in range(points.size() - 1):
		var start: Vector2 = points[index]
		var finish: Vector2 = points[index + 1]
		var segment := finish - start
		var t := clampf((position - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
		best = minf(best, position.distance_to(start + segment * t))
	return best
