@tool
extends RefCounted

## Incrementally creates a regular heightfield mesh from a TerrainData
## snapshot. A Dictionary remains accepted for format-v1 callers and creates a
## fresh TerrainData snapshot from deterministic noise.

const TerrainData := preload("res://addons/godot_ai_terrain_tools/terrain_data.gd")

const NOISE_TYPES := {
	"simplex": FastNoiseLite.TYPE_SIMPLEX,
	"simplex_smooth": FastNoiseLite.TYPE_SIMPLEX_SMOOTH,
	"perlin": FastNoiseLite.TYPE_PERLIN,
	"ridged": FastNoiseLite.TYPE_PERLIN,
	"value": FastNoiseLite.TYPE_VALUE,
}

const PHASE_BASE_HEIGHTS := 0
const PHASE_VERTICES := 1
const PHASE_NORMALS := 2
const PHASE_NORMALIZE := 3
const PHASE_COLORS := 4
const PHASE_EMIT_VERTICES := 5
const PHASE_EMIT_TRIANGLES := 6
const PHASE_COMMIT := 7
const PHASE_DONE := 8

var _data: Resource
var _params: Dictionary
var _noise := FastNoiseLite.new()
var _size: int
var _half: float
var _phase := PHASE_BASE_HEIGHTS
var _cursor := 0
var _heights := PackedFloat32Array()
var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _uvs := PackedVector2Array()
var _colors := PackedColorArray()
var _triangles := PackedVector3Array()
var _surface := SurfaceTool.new()
var _mesh: ArrayMesh = null


func _init(input: Variant) -> void:
	if input is Dictionary:
		_data = TerrainData.new()
		_data.initialize(input)
	else:
		_data = input
	_params = _data.params
	_size = int(_params.size)
	_half = (_size - 1) * float(_params.cell_size) * 0.5
	_noise.seed = int(_params.seed)
	_noise.frequency = float(_params.frequency)
	_noise.fractal_octaves = int(_params.octaves)
	_noise.noise_type = NOISE_TYPES[String(_params.noise_type)]
	if _params.noise_type == "ridged":
		_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	var count := _size * _size
	_verts.resize(count)
	_normals.resize(count)
	_uvs.resize(count)
	_colors.resize(count)
	if _data.base_heights.size() == count and _data.base_ready:
		_heights = _data.final_heights()
		_phase = PHASE_VERTICES


func step(budget_usec: int = 3000) -> bool:
	var started := Time.get_ticks_usec()
	while _phase != PHASE_DONE and Time.get_ticks_usec() - started < budget_usec:
		match _phase:
			PHASE_BASE_HEIGHTS:
				_step_base_height()
			PHASE_VERTICES:
				_step_vertex()
			PHASE_NORMALS:
				_step_normal_cell()
			PHASE_NORMALIZE:
				_step_normalize()
			PHASE_COLORS:
				_step_color()
			PHASE_EMIT_VERTICES:
				_step_emit_vertex()
			PHASE_EMIT_TRIANGLES:
				_step_emit_cell()
			PHASE_COMMIT:
				_surface.set_material(_make_material())
				_mesh = _surface.commit()
				_phase = PHASE_DONE
	return _phase == PHASE_DONE


func result() -> Dictionary:
	if _phase != PHASE_DONE:
		return {}
	var collision_heights := _heights.duplicate()
	for index in collision_heights.size():
		if _is_hole(index):
			collision_heights[index] = NAN
	return {
		"data": _data,
		"mesh": _mesh,
		"triangles": _triangles,
		"collision_heights": collision_heights,
		"vertices": _verts.size(),
		"triangle_count": _triangles.size() / 3,
	}


func _step_base_height() -> void:
	if _cursor >= _data.base_heights.size():
		_data.base_ready = true
		_heights = _data.final_heights()
		_phase = PHASE_VERTICES
		_cursor = 0
		return
	var x := _cursor % _size
	var z := int(_cursor / _size)
	_data.base_heights[_cursor] = float(_params.base_height) + _noise.get_noise_2d(x + 0.5, z + 0.5) * float(_params.height_scale)
	_cursor += 1


func _step_vertex() -> void:
	if _cursor >= _verts.size():
		_phase = PHASE_NORMALS
		_cursor = 0
		return
	var x := _cursor % _size
	var z := int(_cursor / _size)
	_verts[_cursor] = Vector3(x * float(_params.cell_size) - _half, _heights[_cursor], z * float(_params.cell_size) - _half)
	_uvs[_cursor] = Vector2(float(x) / float(_size - 1), float(z) / float(_size - 1))
	_cursor += 1


func _step_normal_cell() -> void:
	var cell_count := (_size - 1) * (_size - 1)
	if _cursor >= cell_count:
		_phase = PHASE_NORMALIZE
		_cursor = 0
		return
	var indices := _cell_indices(_cursor)
	if not _triangle_has_hole(indices[0], indices[1], indices[2]):
		_accumulate_face_normal(indices[0], indices[2], indices[1])
	if not _triangle_has_hole(indices[1], indices[3], indices[2]):
		_accumulate_face_normal(indices[1], indices[2], indices[3])
	_cursor += 1


func _step_normalize() -> void:
	if _cursor >= _normals.size():
		_phase = PHASE_COLORS
		_cursor = 0
		return
	if _normals[_cursor].length_squared() > 0.0:
		_normals[_cursor] = _normals[_cursor].normalized()
	else:
		_normals[_cursor] = Vector3.UP
	_cursor += 1


func _step_color() -> void:
	if _cursor >= _colors.size():
		_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		_phase = PHASE_EMIT_VERTICES
		_cursor = 0
		return
	_colors[_cursor] = _terrain_color(_heights[_cursor], _normals[_cursor])
	_cursor += 1


func _step_emit_vertex() -> void:
	if _cursor >= _verts.size():
		_phase = PHASE_EMIT_TRIANGLES
		_cursor = 0
		return
	_surface.set_uv(_uvs[_cursor])
	_surface.set_color(_colors[_cursor])
	_surface.set_normal(_normals[_cursor])
	_surface.add_vertex(_verts[_cursor])
	_cursor += 1


func _step_emit_cell() -> void:
	var cell_count := (_size - 1) * (_size - 1)
	if _cursor >= cell_count:
		_phase = PHASE_COMMIT
		return
	var indices := _cell_indices(_cursor)
	if not _triangle_has_hole(indices[0], indices[1], indices[2]):
		_emit_triangle(indices[0], indices[1], indices[2])
	if not _triangle_has_hole(indices[1], indices[3], indices[2]):
		_emit_triangle(indices[1], indices[3], indices[2])
	_cursor += 1


func _cell_indices(cell_index: int) -> PackedInt32Array:
	var x := cell_index % (_size - 1)
	var z := int(cell_index / (_size - 1))
	var a := z * _size + x
	var b := a + 1
	var c := (z + 1) * _size + x
	var d := c + 1
	return PackedInt32Array([a, b, c, d])


func _triangle_has_hole(a: int, b: int, c: int) -> bool:
	return _is_hole(a) or _is_hole(b) or _is_hole(c)


func _is_hole(index: int) -> bool:
	return index < _data.holes.size() and _data.holes[index] != 0


func _accumulate_face_normal(i0: int, i1: int, i2: int) -> void:
	var face := (_verts[i1] - _verts[i0]).cross(_verts[i2] - _verts[i0])
	_normals[i0] += face
	_normals[i1] += face
	_normals[i2] += face


func _emit_triangle(i0: int, i1: int, i2: int) -> void:
	_triangles.append(_verts[i0])
	_triangles.append(_verts[i1])
	_triangles.append(_verts[i2])
	_surface.add_index(i0)
	_surface.add_index(i1)
	_surface.add_index(i2)


func _terrain_color(height: float, normal: Vector3) -> Color:
	var scale := float(_params.height_scale)
	var t := clampf(inverse_lerp(-scale, scale, height - float(_params.base_height)), 0.0, 1.0)
	var palette := _palette(String(_params.get("material_preset", "natural")))
	var color: Color
	if t < 0.45:
		color = palette[0].lerp(palette[1], t / 0.45)
	else:
		color = palette[1].lerp(palette[2], (t - 0.45) / 0.55)
	var slope := clampf(1.0 - normal.y, 0.0, 1.0)
	return color.lerp(palette[3], smoothstep(0.22, 0.72, slope))


static func _palette(name: String) -> Array[Color]:
	match name:
		"desert":
			return [Color("7b4d2a"), Color("c58a45"), Color("ead29a"), Color("6b4630")]
		"snow":
			return [Color("485865"), Color("8296a3"), Color("f1f5f7"), Color("59636c")]
		"volcanic":
			return [Color("17151a"), Color("4a2620"), Color("c44c24"), Color("27242a")]
		"alien":
			return [Color("203a42"), Color("43a56f"), Color("c2e85d"), Color("60447d")]
		_:
			return [Color("9e8252"), Color("5c8c40"), Color("ebeff7"), Color("6f6a66")]


static func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.9
	return material
