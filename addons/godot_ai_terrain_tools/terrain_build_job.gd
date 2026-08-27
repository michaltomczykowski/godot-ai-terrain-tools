@tool
extends RefCounted

## Incremental, deterministic heightmap builder. Each step stays within a
## caller-provided editor-frame budget; scene mutation happens only after the
## completed result is available.

const NOISE_TYPES := {
	"simplex": FastNoiseLite.TYPE_SIMPLEX,
	"simplex_smooth": FastNoiseLite.TYPE_SIMPLEX_SMOOTH,
	"perlin": FastNoiseLite.TYPE_PERLIN,
	"ridged": FastNoiseLite.TYPE_PERLIN,
	"value": FastNoiseLite.TYPE_VALUE,
}

const PHASE_VERTICES := 0
const PHASE_NORMALS := 1
const PHASE_NORMALIZE := 2
const PHASE_EMIT_VERTICES := 3
const PHASE_EMIT_TRIANGLES := 4
const PHASE_COMMIT := 5
const PHASE_DONE := 6

var _params: Dictionary
var _noise := FastNoiseLite.new()
var _size: int
var _half: float
var _phase := PHASE_VERTICES
var _cursor := 0
var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _uvs := PackedVector2Array()
var _colors := PackedColorArray()
var _triangles := PackedVector3Array()
var _surface := SurfaceTool.new()
var _mesh: ArrayMesh = null


func _init(params: Dictionary) -> void:
	_params = params.duplicate(true)
	_size = int(_params.size)
	_half = (_size - 1) * float(_params.cell_size) * 0.5
	_noise.seed = int(_params.seed)
	_noise.frequency = float(_params.frequency)
	_noise.fractal_octaves = int(_params.octaves)
	_noise.noise_type = NOISE_TYPES[String(_params.noise_type)]
	if _params.noise_type == "ridged":
		_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_verts.resize(_size * _size)
	_normals.resize(_size * _size)
	_uvs.resize(_size * _size)
	_colors.resize(_size * _size)


func step(budget_usec: int = 3000) -> bool:
	var started := Time.get_ticks_usec()
	while _phase != PHASE_DONE and Time.get_ticks_usec() - started < budget_usec:
		match _phase:
			PHASE_VERTICES:
				_step_vertex()
			PHASE_NORMALS:
				_step_normal_cell()
			PHASE_NORMALIZE:
				_step_normalize()
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
	return {
		"mesh": _mesh,
		"triangles": _triangles,
		"vertices": _verts.size(),
		"triangle_count": _triangles.size() / 3,
	}


func _step_vertex() -> void:
	if _cursor >= _verts.size():
		_phase = PHASE_NORMALS
		_cursor = 0
		return
	var x := _cursor % _size
	var z := int(_cursor / _size)
	## Half-cell offsets avoid FastNoiseLite's seed-insensitive origin sample.
	var h := float(_params.base_height) + _noise.get_noise_2d(x + 0.5, z + 0.5) * float(_params.height_scale)
	_verts[_cursor] = Vector3(x * float(_params.cell_size) - _half, h, z * float(_params.cell_size) - _half)
	_uvs[_cursor] = Vector2(float(x) / float(_size - 1), float(z) / float(_size - 1))
	_colors[_cursor] = _height_color(h)
	_cursor += 1


func _step_normal_cell() -> void:
	var cell_count := (_size - 1) * (_size - 1)
	if _cursor >= cell_count:
		_phase = PHASE_NORMALIZE
		_cursor = 0
		return
	var x := _cursor % (_size - 1)
	var z := int(_cursor / (_size - 1))
	var a := z * _size + x
	var b := a + 1
	var c := (z + 1) * _size + x
	var d := c + 1
	## Godot's clockwise front-face winding has a -Y geometric cross product;
	## normals intentionally point +Y for lighting.
	_accumulate_face_normal(a, c, b)
	_accumulate_face_normal(b, c, d)
	_cursor += 1


func _step_normalize() -> void:
	if _cursor >= _normals.size():
		_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		_phase = PHASE_EMIT_VERTICES
		_cursor = 0
		return
	_normals[_cursor] = _normals[_cursor].normalized()
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
	var x := _cursor % (_size - 1)
	var z := int(_cursor / (_size - 1))
	var a := z * _size + x
	var b := a + 1
	var c := (z + 1) * _size + x
	var d := c + 1
	## Clockwise from above: visible terrain and one-sided collision both face up.
	_emit_triangle(a, b, c)
	_emit_triangle(b, d, c)
	_cursor += 1


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


func _height_color(height: float) -> Color:
	var scale := float(_params.height_scale)
	var t := clampf(inverse_lerp(-scale, scale, height - float(_params.base_height)), 0.0, 1.0)
	if t < 0.25:
		return Color(0.62, 0.51, 0.32)
	if t < 0.55:
		return Color(0.36, 0.55, 0.25)
	if t < 0.8:
		return Color(0.45, 0.42, 0.4)
	return Color(0.92, 0.94, 0.97)


static func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.9
	return material
