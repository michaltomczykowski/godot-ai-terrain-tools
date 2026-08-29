@tool
extends RefCounted

## Incrementally creates a regular heightfield mesh from a TerrainData
## snapshot. A Dictionary remains accepted for format-v1 callers and creates a
## fresh TerrainData snapshot from deterministic noise.

const TerrainData := preload("res://addons/godot_ai_terrain_tools/terrain_data.gd")
const TERRAIN_SHADER := preload("res://addons/godot_ai_terrain_tools/terrain_material.gdshader")

const TEXTURE_ROOT := "res://addons/godot_ai_terrain_tools/assets/textures/"
const BUNDLED_TEXTURES := {
	"ground": {"albedo": "ground/albedo.jpg", "normal": "ground/normal_opengl.jpg", "roughness": "ground/roughness.jpg"},
	"road": {"albedo": "road/albedo.jpg", "normal": "road/normal_opengl.jpg", "roughness": "road/roughness.jpg"},
	"rock": {"albedo": "rock/albedo.jpg", "normal": "rock/normal_opengl.jpg", "roughness": "rock/roughness.jpg"},
	"snow": {"albedo": "snow/albedo.jpg", "normal": "snow/normal_opengl.jpg", "roughness": "snow/roughness.jpg"},
}
const GENERATED_ROOT := "res://addons/godot_ai_terrain_tools/assets/generated/"
const GENERATED_VARIANTS := {
	"ground": ["meadow_grass", "mossy_forest_floor", "dry_mountain_grass"],
	"dirt": ["compact_earth", "pale_sand", "gravelly_loam"],
	"rock": ["stratified_dark_rock", "weathered_granite", "rugged_limestone"],
}
const PROFILE_VARIANTS := {
	"mountain_valley": {"ground": 0, "dirt": 0, "rock": 0},
	"forest": {"ground": 1, "dirt": 2, "rock": 1},
	"arid": {"ground": 2, "dirt": 1, "rock": 2},
}

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
				_surface.set_material(_make_material(_data))
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
	_colors[_cursor] = _terrain_weights(_cursor, _heights[_cursor], _normals[_cursor])
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


func _terrain_weights(index: int, height: float, normal: Vector3) -> Color:
	var scale := float(_params.height_scale)
	var t := clampf(inverse_lerp(-scale, scale, height - float(_params.base_height)), 0.0, 1.0)
	var slope := clampf(1.0 - normal.y, 0.0, 1.0)
	var profile := String(_params.get("surface_profile", "mountain_valley"))
	if profile != "legacy":
		var x: int = index % _size
		var z := int(index / _size)
		var neighbor_sum := 0.0
		var neighbor_count := 0
		for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var nx: int = x + offset.x
			var nz: int = z + offset.y
			if nx >= 0 and nx < _size and nz >= 0 and nz < _size:
				neighbor_sum += _heights[nz * _size + nx]
				neighbor_count += 1
		var curvature := 0.0 if neighbor_count == 0 else height - neighbor_sum / neighbor_count
		var rock_threshold := 0.14 if profile == "mountain_valley" else (0.2 if profile == "forest" else 0.18)
		var rock := maxf(smoothstep(rock_threshold, 0.62, slope), smoothstep(0.3, 1.3, curvature / maxf(float(_params.cell_size), 0.001)))
		var snow_start := 0.72 if profile == "mountain_valley" else (0.82 if profile == "forest" else 0.96)
		var snow := smoothstep(snow_start, minf(1.0, snow_start + 0.18), t) * (1.0 - rock)
		var deposition := smoothstep(0.08, 0.65, -curvature / maxf(float(_params.cell_size), 0.001)) * (1.0 - slope)
		var lowland := (1.0 - smoothstep(0.28, 0.55, t)) * (1.0 - slope)
		var dirt_bias := 0.78 if profile == "arid" else (0.22 if profile == "forest" else 0.45)
		var dirt := clampf(maxf(deposition * 0.75, lowland * dirt_bias) * (1.0 - rock - snow), 0.0, 1.0)
		var ground := maxf(0.0, 1.0 - rock - snow - dirt)
		var automatic := _normalized_weights(Color(ground, dirt, rock, snow))
		if index >= _data.paint_coverage.size() or index >= _data.paint_weights.size():
			return automatic
		var coverage := clampf(_data.paint_coverage[index], 0.0, 1.0)
		if coverage <= 0.0:
			return automatic
		return _normalized_weights(automatic.lerp(_normalized_weights(_data.paint_weights[index]), coverage))
	var rock := smoothstep(0.22, 0.72, slope)
	var snow := smoothstep(0.68, 0.92, t) * (1.0 - rock)
	var automatic := Color(maxf(0.0, 1.0 - rock - snow), 0.0, rock, snow)
	if index >= _data.paint_coverage.size() or index >= _data.paint_weights.size():
		return automatic
	var coverage := clampf(_data.paint_coverage[index], 0.0, 1.0)
	if coverage <= 0.0:
		return automatic
	var painted: Color = _normalized_weights(_data.paint_weights[index])
	return _normalized_weights(automatic.lerp(painted, coverage))


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


static func _normalized_weights(value: Color) -> Color:
	var total := value.r + value.g + value.b + value.a
	if total <= 0.00001:
		return Color(1.0, 0.0, 0.0, 0.0)
	return value / total


static func _make_material(data: Resource) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = TERRAIN_SHADER
	var params: Dictionary = data.params
	var mode := String(params.get("render_mode", "bundled"))
	material.set_shader_parameter("material_mode", 0 if mode == "procedural" else 1)
	material.set_shader_parameter("texture_scale", float(params.get("texture_scale", 0.2)))
	# Keep the triplanar detail restrained so steep terrain gains texture relief
	# without allowing normal maps to overpower the heightfield's true normals.
	material.set_shader_parameter("normal_strength", 0.08)
	var palette := _palette(String(params.get("material_preset", "natural")))
	material.set_shader_parameter("ground_color", palette[1])
	material.set_shader_parameter("road_color", palette[0].darkened(0.16))
	material.set_shader_parameter("rock_color", palette[3])
	material.set_shader_parameter("snow_color", palette[2])
	if mode != "procedural":
		var overrides: Dictionary = params.get("custom_textures", {})
		for layer in BUNDLED_TEXTURES:
			var layer_overrides: Dictionary = overrides.get(layer, {}) if mode == "custom" else {}
			for texture_kind in BUNDLED_TEXTURES[layer]:
				var fallback := _selected_texture_path(params, layer, texture_kind)
				var texture_path := String(layer_overrides.get(texture_kind, fallback))
				var texture := load(texture_path)
				if texture is Texture2D:
					material.set_shader_parameter("%s_%s" % [layer, texture_kind], texture)
	return material


static func _selected_texture_path(params: Dictionary, layer: String, texture_kind: String) -> String:
	var profile := String(params.get("surface_profile", "mountain_valley"))
	if profile == "legacy" or layer == "snow":
		return TEXTURE_ROOT + String(BUNDLED_TEXTURES[layer][texture_kind])
	var family := "dirt" if layer == "road" else layer
	var defaults: Dictionary = PROFILE_VARIANTS.get(profile, PROFILE_VARIANTS.mountain_valley)
	var selected: Dictionary = params.get("texture_variants", {})
	var variant_index := clampi(int(selected.get(family, defaults.get(family, 0))), 0, 2)
	var variant_name := String(GENERATED_VARIANTS[family][variant_index])
	var file_name := "normal_opengl" if texture_kind == "normal" else texture_kind
	return "%s%s/%s/%s.png" % [GENERATED_ROOT, family, variant_name, file_name]
