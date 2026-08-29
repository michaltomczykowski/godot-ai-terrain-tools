@tool
extends RefCounted

## Incremental, deterministic rasterizer for intentional terrain-local forms.
## Features are applied in request order and write only TerrainData.edit_offsets.

var _data: Resource
var _features: Array
var _size: int
var _cell: float
var _half: float
var _feature_index := 0
var _x := 0
var _z := 0
var _min_x := 0
var _max_x := -1
var _min_z := 0
var _max_z := -1
var _source := PackedFloat32Array()
var _affected := {}


func _init(data: Resource, features: Array) -> void:
	_data = data
	_features = features
	_size = int(data.params.size)
	_cell = float(data.params.cell_size)
	_half = (_size - 1) * _cell * 0.5
	_begin_feature()


func step(budget_usec: int = 3000) -> bool:
	var started := Time.get_ticks_usec()
	while _feature_index < _features.size() and Time.get_ticks_usec() - started < budget_usec:
		if _z > _max_z:
			_feature_index += 1
			_begin_feature()
			continue
		_apply_sample(_x, _z)
		_x += 1
		if _x > _max_x:
			_x = _min_x
			_z += 1
	return _feature_index >= _features.size()


func result() -> Dictionary:
	if _feature_index < _features.size():
		return {}
	return {"data": _data, "affected_vertices": _affected.size()}


func _begin_feature() -> void:
	if _feature_index >= _features.size():
		return
	_source = _data.final_heights()
	var feature: Dictionary = _features[_feature_index]
	var reach: float = float(feature.width) + float(feature.falloff_width)
	var min_world := Vector2(INF, INF)
	var max_world := Vector2(-INF, -INF)
	for point_value in feature.points:
		var point: Vector2 = point_value
		min_world.x = minf(min_world.x, point.x)
		min_world.y = minf(min_world.y, point.y)
		max_world.x = maxf(max_world.x, point.x)
		max_world.y = maxf(max_world.y, point.y)
	_min_x = clampi(int(floor((min_world.x - reach + _half) / _cell)), 0, _size - 1)
	_max_x = clampi(int(ceil((max_world.x + reach + _half) / _cell)), 0, _size - 1)
	_min_z = clampi(int(floor((min_world.y - reach + _half) / _cell)), 0, _size - 1)
	_max_z = clampi(int(ceil((max_world.y + reach + _half) / _cell)), 0, _size - 1)
	_x = _min_x
	_z = _min_z


func _apply_sample(x: int, z: int) -> void:
	var feature: Dictionary = _features[_feature_index]
	var position := Vector2(x * _cell - _half, z * _cell - _half)
	var distance := _distance_to_polyline(feature.points, position)
	var width: float = float(feature.width)
	var falloff_width: float = float(feature.falloff_width)
	if distance > width + falloff_width:
		return
	var weight := 1.0
	if distance > width:
		if falloff_width <= 0.0:
			return
		weight = 1.0 - (distance - width) / falloff_width
	weight = _profile_weight(weight, String(feature.profile))
	var index := z * _size + x
	if _data.holes[index] != 0:
		return
	var current: float = _source[index]
	var roughness: float = float(feature.roughness)
	var rough := 0.0
	if roughness > 0.0:
		rough = (_hash_unit(x, z, int(feature.seed)) * 2.0 - 1.0) * roughness * float(feature.scale)
	var updated := current
	match String(feature.type):
		"ridge":
			updated += (float(feature.height) + rough) * weight
		"valley":
			updated += (float(feature.height) - absf(rough)) * weight
		"plateau":
			updated = lerpf(current, float(feature.height) + rough, weight)
	if not is_equal_approx(updated, current):
		_data.edit_offsets[index] = updated - _data.base_heights[index]
		_affected[index] = true


static func _profile_weight(weight: float, profile: String) -> float:
	weight = clampf(weight, 0.0, 1.0)
	match profile:
		"sharp":
			return weight * weight
		"terraced":
			var smooth := weight * weight * (3.0 - 2.0 * weight)
			return floor(smooth * 5.0 + 0.5) / 5.0
		_:
			return weight * weight * (3.0 - 2.0 * weight)


static func _distance_to_polyline(points: Array, position: Vector2) -> float:
	if points.size() == 1:
		return position.distance_to(points[0])
	var closest := INF
	for index in range(points.size() - 1):
		var a: Vector2 = points[index]
		var b: Vector2 = points[index + 1]
		var segment := b - a
		var length_squared := segment.length_squared()
		var t := 0.0 if length_squared <= 0.000001 else clampf((position - a).dot(segment) / length_squared, 0.0, 1.0)
		closest = minf(closest, position.distance_to(a + segment * t))
	return closest


static func _hash_unit(x: int, z: int, seed: int) -> float:
	var value := x * 374761393 + z * 668265263 + seed * 69069
	value = (value ^ (value >> 13)) * 1274126177
	value = value ^ (value >> 16)
	return float(value & 0xffff) / 65535.0
