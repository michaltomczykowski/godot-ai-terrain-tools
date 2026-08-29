@tool
extends RefCounted

## Deterministic, bounded erosion over a TerrainData snapshot. The algorithms
## intentionally favor predictable map-authoring results over physical detail.

var _data: Resource
var _algorithm: String
var _iterations: int
var _intensity: float
var _seed: int
var _settings: Dictionary
var _size: int
var _cell: float
var _half: float
var _iteration := 0
var _cursor := 0
var _heights := PackedFloat32Array()
var _source := PackedFloat32Array()
var _next := PackedFloat32Array()
var _water := PackedFloat32Array()
var _sediment := PackedFloat32Array()
var _source_water := PackedFloat32Array()
var _source_sediment := PackedFloat32Array()
var _next_water := PackedFloat32Array()
var _next_sediment := PackedFloat32Array()
var _affected := {}


func _init(data: Resource, algorithm: String, iterations: int, intensity: float, seed: int, settings: Dictionary = {}) -> void:
	_data = data
	_algorithm = algorithm
	_iterations = iterations
	_intensity = intensity
	_seed = seed
	_settings = settings.duplicate(true)
	_size = int(data.params.size)
	_cell = float(data.params.cell_size)
	_half = (_size - 1) * _cell * 0.5
	_heights = data.final_heights()
	_water.resize(_heights.size())
	_sediment.resize(_heights.size())
	_begin_iteration()


func step(budget_usec: int = 3000) -> bool:
	var started := Time.get_ticks_usec()
	while _iteration < _iterations and Time.get_ticks_usec() - started < budget_usec:
		if _cursor >= _heights.size():
			_finish_iteration()
			continue
		if _data.holes[_cursor] == 0:
			if _algorithm == "thermal":
				_step_thermal(_cursor)
			elif _algorithm == "hydraulic":
				_step_hydraulic(_cursor)
			elif _algorithm == "thermal_natural":
				_step_thermal_natural(_cursor)
			else:
				_step_hydraulic_natural(_cursor)
		_cursor += 1
	if _iteration >= _iterations:
		_store_offsets()
		return true
	return false


func result() -> Dictionary:
	if _iteration < _iterations:
		return {}
	return {"data": _data, "affected_vertices": _affected.size()}


func _begin_iteration() -> void:
	_source = _heights.duplicate()
	_next = _heights.duplicate()
	_source_water = _water.duplicate()
	_source_sediment = _sediment.duplicate()
	_next_water = _water.duplicate()
	_next_sediment = _sediment.duplicate()
	_cursor = 0


func _finish_iteration() -> void:
	_heights = _next
	_water = _next_water
	_sediment = _next_sediment
	_iteration += 1
	if _iteration < _iterations:
		_begin_iteration()


func _step_thermal(index: int) -> void:
	var lowest := _lowest_neighbor(index, _source)
	if lowest < 0:
		return
	var difference := _source[index] - _source[lowest]
	var talus := maxf(0.01, float(_data.params.height_scale) * 0.02)
	if difference <= talus:
		return
	var amount := minf((difference - talus) * 0.25 * _intensity, difference * 0.45)
	_next[index] -= amount
	_next[lowest] += amount
	_affected[index] = true
	_affected[lowest] = true


func _step_hydraulic(index: int) -> void:
	## Fixed algorithm-v1 constants. Intensity scales rainfall, transport and
	## erosion while evaporation remains stable for comparable iteration counts.
	var rain := 0.0125 * _intensity * (0.75 + 0.5 * _hash_unit(index, _iteration, _seed))
	_next_water[index] += rain
	var local_water := _source_water[index] + rain
	var lowest := _lowest_surface_neighbor(index)
	if lowest < 0:
		_next_water[index] *= 0.92
		return
	var surface_difference := (_source[index] + local_water) - (_source[lowest] + _source_water[lowest])
	if surface_difference <= 0.0:
		_next_water[index] *= 0.92
		return
	var flow := minf(local_water, surface_difference * 0.25 * _intensity)
	var carried := minf(_source_sediment[index], flow * 0.5)
	_next_water[index] -= flow
	_next_water[lowest] += flow
	_next_sediment[index] -= carried
	_next_sediment[lowest] += carried
	var capacity := flow * surface_difference * 3.0
	if _source_sediment[index] > capacity:
		var deposit := minf((_source_sediment[index] - capacity) * 0.15, _source_sediment[index])
		_next[index] += deposit
		_next_sediment[index] -= deposit
		if deposit > 0.0:
			_affected[index] = true
	else:
		var eroded := minf((capacity - _source_sediment[index]) * 0.08 * _intensity, 0.05 * _intensity)
		_next[index] -= eroded
		_next_sediment[index] += eroded
		if eroded > 0.0:
			_affected[index] = true
	_next_water[index] = maxf(0.0, _next_water[index] * 0.92)
	_next_sediment[index] = maxf(0.0, _next_sediment[index])


func _step_thermal_natural(index: int) -> void:
	if not _inside_region(index):
		return
	var talus := float(_settings.get("talus", 0.15)) * maxf(_cell, 0.01)
	var candidates: Array[Vector2] = []
	var total_excess := 0.0
	for neighbor in _neighbors8(index):
		if _data.holes[neighbor] != 0 or not _inside_region(neighbor):
			continue
		var distance := _neighbor_distance(index, neighbor)
		var excess := (_source[index] - _source[neighbor]) / distance - talus
		if excess > 0.0:
			candidates.append(Vector2(neighbor, excess))
			total_excess += excess
	if total_excess <= 0.0:
		return
	var preserve := _ridge_factor(index)
	var total_move := minf(total_excess * 0.08 * _intensity * preserve, maxf(0.0, _source[index] - _minimum_neighbor_height(index)) * 0.35)
	if total_move <= 0.0:
		return
	for candidate in candidates:
		var amount := total_move * candidate.y / total_excess
		_next[index] -= amount
		_next[int(candidate.x)] += amount
		_affected[int(candidate.x)] = true
	_affected[index] = true


func _step_hydraulic_natural(index: int) -> void:
	if not _inside_region(index):
		return
	var candidates: Array[Vector2] = []
	var total_drop := 0.0
	var rain := float(_settings.get("rain", 0.8)) * (0.75 + 0.5 * _hash_unit(index, _iteration, _seed))
	for neighbor in _neighbors8(index):
		if _data.holes[neighbor] != 0 or not _inside_region(neighbor):
			continue
		var distance := _neighbor_distance(index, neighbor)
		var drop := (_source[index] - _source[neighbor]) / distance
		if drop > 0.0:
			candidates.append(Vector2(neighbor, drop))
			total_drop += drop
	if total_drop <= 0.0:
		return
	var erosion_rate := float(_settings.get("erosion", 0.4))
	var deposition := float(_settings.get("deposition", 0.3))
	var evaporation := float(_settings.get("evaporation", 0.08))
	var transport := rain * erosion_rate * (1.0 - evaporation) * (1.0 - deposition * 0.35)
	var total_move := minf(total_drop * 0.018 * _intensity * transport * _ridge_factor(index), maxf(0.0, _source[index] - _minimum_neighbor_height(index)) * 0.28)
	if total_move <= 0.0:
		return
	for candidate in candidates:
		var amount := total_move * candidate.y / total_drop
		_next[index] -= amount
		_next[int(candidate.x)] += amount
		_affected[int(candidate.x)] = true
	_affected[index] = true


func _lowest_neighbor(index: int, values: PackedFloat32Array) -> int:
	var result := -1
	var lowest := values[index]
	for neighbor in _neighbors(index):
		if _data.holes[neighbor] == 0 and values[neighbor] < lowest:
			lowest = values[neighbor]
			result = neighbor
	return result


func _lowest_surface_neighbor(index: int) -> int:
	var result := -1
	var lowest := _source[index] + _source_water[index]
	for neighbor in _neighbors(index):
		if _data.holes[neighbor] != 0:
			continue
		var surface := _source[neighbor] + _source_water[neighbor]
		if surface < lowest:
			lowest = surface
			result = neighbor
	return result


func _neighbors(index: int) -> PackedInt32Array:
	var x := index % _size
	var z := int(index / _size)
	var result := PackedInt32Array()
	if x > 0:
		result.append(index - 1)
	if x + 1 < _size:
		result.append(index + 1)
	if z > 0:
		result.append(index - _size)
	if z + 1 < _size:
		result.append(index + _size)
	return result


func _neighbors8(index: int) -> PackedInt32Array:
	var x: int = index % _size
	var z := int(index / _size)
	var result := PackedInt32Array()
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			var nx := x + dx
			var nz := z + dz
			if nx >= 0 and nx < _size and nz >= 0 and nz < _size:
				result.append(nz * _size + nx)
	return result


func _inside_region(index: int) -> bool:
	if not _settings.has("region"):
		return true
	var region: Dictionary = _settings.region
	var x: int = index % _size
	var z := int(index / _size)
	var position := Vector2(x * _cell - _half, z * _cell - _half)
	if region.has("points"):
		var points: Array = region.points
		var closest := INF
		for point_index in range(points.size() - 1):
			var start: Vector2 = points[point_index]
			var finish: Vector2 = points[point_index + 1]
			var segment := finish - start
			var length_squared := segment.length_squared()
			var t := 0.0 if length_squared <= 0.000001 else clampf((position - start).dot(segment) / length_squared, 0.0, 1.0)
			closest = minf(closest, position.distance_to(start + segment * t))
		return closest <= float(region.radius)
	return position.distance_to(Vector2(float(region.center_x), float(region.center_z))) <= float(region.radius)


func _neighbor_distance(index: int, neighbor: int) -> float:
	var x0: int = index % _size
	var z0 := int(index / _size)
	var x1: int = neighbor % _size
	var z1 := int(neighbor / _size)
	return Vector2(x1 - x0, z1 - z0).length() * _cell


func _minimum_neighbor_height(index: int) -> float:
	var result := _source[index]
	for neighbor in _neighbors8(index):
		if _data.holes[neighbor] == 0 and _inside_region(neighbor):
			result = minf(result, _source[neighbor])
	return result


func _ridge_factor(index: int) -> float:
	var preservation := float(_settings.get("ridge_preservation", 0.0))
	if preservation <= 0.0:
		return 1.0
	var average := 0.0
	var count := 0
	for neighbor in _neighbors8(index):
		if _data.holes[neighbor] == 0:
			average += _source[neighbor]
			count += 1
	if count == 0 or _source[index] <= average / count:
		return 1.0
	return 1.0 - preservation


func _store_offsets() -> void:
	for index in _heights.size():
		_data.edit_offsets[index] = _heights[index] - _data.base_heights[index]


static func _hash_unit(index: int, iteration: int, seed: int) -> float:
	var value := index * 374761393 + iteration * 668265263 + seed * 69069
	value = (value ^ (value >> 13)) * 1274126177
	value = value ^ (value >> 16)
	return float(value & 0xffff) / 65535.0
