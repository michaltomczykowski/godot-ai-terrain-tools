@tool
extends RefCounted

## Deterministic, bounded erosion over a TerrainData snapshot. The algorithms
## intentionally favor predictable map-authoring results over physical detail.

var _data: Resource
var _algorithm: String
var _iterations: int
var _intensity: float
var _seed: int
var _size: int
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


func _init(data: Resource, algorithm: String, iterations: int, intensity: float, seed: int) -> void:
	_data = data
	_algorithm = algorithm
	_iterations = iterations
	_intensity = intensity
	_seed = seed
	_size = int(data.params.size)
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
			else:
				_step_hydraulic(_cursor)
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


func _store_offsets() -> void:
	for index in _heights.size():
		_data.edit_offsets[index] = _heights[index] - _data.base_heights[index]


static func _hash_unit(index: int, iteration: int, seed: int) -> float:
	var value := index * 374761393 + iteration * 668265263 + seed * 69069
	value = (value ^ (value >> 13)) * 1274126177
	value = value ^ (value >> 16)
	return float(value & 0xffff) / 65535.0
