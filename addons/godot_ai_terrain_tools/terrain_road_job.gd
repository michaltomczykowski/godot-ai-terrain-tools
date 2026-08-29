@tool
extends RefCounted

var _data: Resource
var _settings: Dictionary
var _size: int
var _cell: float
var _half: float
var _heights := PackedFloat32Array()
var _points: Array
var _profile: Array[float] = []
var _road_length := 0.0
var _cursor := 0
var _changed := {}
var _painted := {}
var _done := false
var _error_result := {}


func _init(data: Resource, settings: Dictionary) -> void:
	_data = data
	_settings = settings
	_size = int(data.params.size)
	_cell = float(data.params.cell_size)
	_half = (_size - 1) * _cell * 0.5
	_heights = data.final_heights()
	_points = settings.points
	_prepare_profile()


func step(budget_usec: int = 3000) -> bool:
	if not _error_result.is_empty():
		_done = true
		return true
	var started := Time.get_ticks_usec()
	while _cursor < _heights.size() and Time.get_ticks_usec() - started < budget_usec:
		var index := _cursor
		_cursor += 1
		if _data.holes[index] != 0:
			continue
		var x: int = index % _size
		var z: int = int(index / _size)
		var position := Vector2(x * _cell - _half, z * _cell - _half)
		var sample := _closest_path_sample(position)
		var half_width := float(_settings.width) * 0.5
		var shoulder := float(_settings.shoulder_width)
		if sample.distance > half_width + shoulder:
			continue
		var weight := 1.0
		if sample.distance > half_width:
			if shoulder <= 0.0:
				continue
			weight = 1.0 - (sample.distance - half_width) / shoulder
			if _settings.falloff == "smooth":
				weight = weight * weight * (3.0 - 2.0 * weight)
		var updated := lerpf(_heights[index], sample.height, weight)
		if not is_equal_approx(updated, _heights[index]):
			_data.edit_offsets[index] = updated - _data.base_heights[index]
			_changed[index] = true
		if _settings.paint_road:
			_paint_road(index, weight)
			_painted[index] = true
	if _cursor >= _heights.size():
		_done = true
		if _changed.is_empty() and _painted.is_empty():
			_error_result = _error("terrain_tools.OUTSIDE_TERRAIN", "The road corridor does not intersect any unmasked terrain samples")
	return _done


func result() -> Dictionary:
	if not _done:
		return {}
	if not _error_result.is_empty():
		return _error_result
	return {"affected_vertices": _changed.size(), "painted_vertices": _painted.size(), "road_length": _road_length}


func _prepare_profile() -> void:
	var cumulative: Array[float] = [0.0]
	for index in range(1, _points.size()):
		var point: Vector2 = _points[index]
		cumulative.append(cumulative[-1] + point.distance_to(_points[index - 1]))
	_road_length = cumulative[-1]
	var start_height := _sample_height(_points[0])
	var end_height := _sample_height(_points[-1])
	if _settings.has("start_height"):
		start_height = _settings.start_height
		end_height = _settings.end_height
	if absf(end_height - start_height) > _road_length * float(_settings.max_grade) + 0.0001:
		_error_result = _error("terrain_tools.GRADE_INFEASIBLE", "Road endpoints cannot be connected within max_grade")
		return
	for index in _points.size():
		if _settings.elevation_mode == "linear":
			_profile.append(lerpf(start_height, end_height, cumulative[index] / _road_length))
		else:
			_profile.append(_sample_height(_points[index]))
	_profile[0] = start_height
	_profile[-1] = end_height
	if _settings.elevation_mode == "follow_smooth":
		for _pass in int(_settings.smoothing_passes):
			var source := _profile.duplicate()
			for index in range(1, _profile.size() - 1):
				_profile[index] = (source[index - 1] + source[index] * 2.0 + source[index + 1]) * 0.25
		_limit_grade(cumulative, float(_settings.max_grade), start_height, end_height)


func _limit_grade(distances: Array[float], max_grade: float, start_height: float, end_height: float) -> void:
	for _pass in 8:
		_profile[0] = start_height
		for index in range(1, _profile.size()):
			var allowance := (distances[index] - distances[index - 1]) * max_grade
			_profile[index] = clampf(_profile[index], _profile[index - 1] - allowance, _profile[index - 1] + allowance)
		_profile[-1] = end_height
		for index in range(_profile.size() - 2, -1, -1):
			var allowance := (distances[index + 1] - distances[index]) * max_grade
			_profile[index] = clampf(_profile[index], _profile[index + 1] - allowance, _profile[index + 1] + allowance)
	_profile[0] = start_height
	_profile[-1] = end_height


func _closest_path_sample(position: Vector2) -> Dictionary:
	var best_distance := INF
	var best_height := _profile[0]
	for index in range(_points.size() - 1):
		var start: Vector2 = _points[index]
		var finish: Vector2 = _points[index + 1]
		var segment := finish - start
		var t := clampf((position - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
		var distance := position.distance_to(start + segment * t)
		if distance < best_distance:
			best_distance = distance
			best_height = lerpf(_profile[index], _profile[index + 1], t)
	return {"distance": best_distance, "height": best_height}


func _sample_height(point: Vector2) -> float:
	var grid_x := clampf((point.x + _half) / _cell, 0.0, _size - 1.0)
	var grid_z := clampf((point.y + _half) / _cell, 0.0, _size - 1.0)
	var x0 := int(floorf(grid_x))
	var z0 := int(floorf(grid_z))
	var x1 := mini(x0 + 1, _size - 1)
	var z1 := mini(z0 + 1, _size - 1)
	var tx := grid_x - x0
	var tz := grid_z - z0
	var top := lerpf(_heights[z0 * _size + x0], _heights[z0 * _size + x1], tx)
	var bottom := lerpf(_heights[z1 * _size + x0], _heights[z1 * _size + x1], tx)
	return lerpf(top, bottom, tz)


func _paint_road(index: int, amount: float) -> void:
	var target := Color(0.0, 1.0, 0.0, 0.0)
	var current: Color = _data.paint_weights[index]
	var total := current.r + current.g + current.b + current.a
	current = target if total <= 0.00001 else current / total
	current = current.lerp(target, clampf(amount, 0.0, 1.0))
	total = current.r + current.g + current.b + current.a
	_data.paint_weights[index] = current / total
	_data.paint_coverage[index] = lerpf(_data.paint_coverage[index], 1.0, clampf(amount, 0.0, 1.0))


static func _error(code: String, message: String) -> Dictionary:
	return {"status": "error", "error": {"code": code, "message": message}}
