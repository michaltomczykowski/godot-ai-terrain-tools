@tool
extends EditorPlugin

const SOURCE_PATH := "res://addons/godot_ai_terrain_tools/plugin.cfg"
const HANDLER_PATH := "res://addons/godot_ai_terrain_tools/terrain_handler.gd"
const TerrainHandler := preload("res://addons/godot_ai_terrain_tools/terrain_handler.gd")
const POLL_SECONDS := 0.5

var _registry: McpToolRegistry = null
var _poll_elapsed := 0.0


func _enter_tree() -> void:
	set_process(true)
	_refresh_registry()


func _exit_tree() -> void:
	TerrainHandler.reset_busy()
	if is_instance_valid(_registry):
		if _registry.registry_ready.is_connected(_on_registry_ready):
			_registry.registry_ready.disconnect(_on_registry_ready)
		_registry.unregister_source(SOURCE_PATH)
	_registry = null


func _process(delta: float) -> void:
	_poll_elapsed += delta
	if _poll_elapsed < POLL_SECONDS:
		return
	_poll_elapsed = 0.0
	_refresh_registry()


func _refresh_registry() -> void:
	var current := McpToolRegistry.get_instance()
	if current == _registry:
		return
	if is_instance_valid(_registry) and _registry.registry_ready.is_connected(_on_registry_ready):
		_registry.registry_ready.disconnect(_on_registry_ready)
	_registry = current
	if _registry == null:
		return
	if not _registry.registry_ready.is_connected(_on_registry_ready):
		_registry.registry_ready.connect(_on_registry_ready)
	if _registry.is_ready():
		_register_tools()


func _on_registry_ready() -> void:
	_register_tools()


func _register_tools() -> void:
	if _registry == null:
		return
	var specs: Array[McpCustomToolSpec] = [
		_create_spec(), _regenerate_spec(), _sculpt_spec(), _holes_spec(), _erode_spec(),
		_landform_spec(), _road_spec(), _paint_spec(), _material_spec(),
	]
	if not _registry.batch_register(specs):
		push_error("Godot AI Terrain Tools: custom tool registration failed")


func _base_spec(name: String, description: String, method: StringName, schema: Dictionary) -> McpCustomToolSpec:
	var spec := McpCustomToolSpec.new()
	spec.name = name
	spec.description = description
	spec.params_schema = schema
	spec.script_path = HANDLER_PATH
	spec.method = method
	spec.source_path = SOURCE_PATH
	spec.source = "Godot AI Terrain Tools"
	## Godot AI currently exposes at most eight promoted custom tools. Keep the
	## complete nine-operation catalog, but leave the infrequent material-only
	## switch reachable through custom_manage so sculpt is never displaced.
	spec.promoted = name != "terrain_material"
	spec.timeout_ms = 30000
	spec.deferred = true
	spec.requires_writable = true
	spec.undoable = true
	return spec


func _create_spec() -> McpCustomToolSpec:
	return _base_spec(
		"terrain_create",
		"Create deterministic editor heightmap terrain with a built-in material palette and optional matching heightfield collision. The operation is undoable.",
		&"create",
		{
			"type": "object",
			"additionalProperties": false,
			"properties": _common_properties().merged({
				"parent_path": {"type": "string", "description": "Scene path to a Node3D parent; defaults to the scene root."},
				"scene_file": {"type": "string", "description": "Optional edited-scene guard (res://...tscn)."},
				"name": {"type": "string", "default": "Terrain"},
			}),
		}
	)


func _regenerate_spec() -> McpCustomToolSpec:
	return _base_spec(
		"terrain_regenerate",
		"Regenerate managed terrain. Omitted settings and same-size sculpting, erosion, and holes are preserved unless reset_modifications is true.",
		&"regenerate",
		{
			"type": "object",
			"additionalProperties": false,
			"required": ["path"],
			"properties": _common_properties().merged({
				"path": {"type": "string", "description": "Scene path to a managed terrain Node3D."},
				"scene_file": {"type": "string", "description": "Optional edited-scene guard (res://...tscn)."},
				"reset_modifications": {"type": "boolean", "default": false, "description": "Clear sculpting, erosion, and holes before regenerating."},
			}),
		}
	)


func _sculpt_spec() -> McpCustomToolSpec:
	return _base_spec(
		"terrain_sculpt",
		"Apply up to 64 terrain-local raise, lower, smooth, flatten, or noise brush strokes and rebuild once as one undoable action.",
		&"sculpt",
		{
			"type": "object",
			"additionalProperties": false,
			"required": ["path", "strokes"],
			"properties": _target_properties().merged({
				"strokes": {
					"type": "array", "minItems": 1, "maxItems": 64,
					"items": {
						"type": "object", "additionalProperties": false,
						"required": ["center_x", "center_z", "radius", "mode", "strength"],
						"properties": {
							"center_x": {"type": "number"}, "center_z": {"type": "number"},
							"radius": {"type": "number", "exclusiveMinimum": 0},
							"mode": {"type": "string", "enum": ["raise", "lower", "smooth", "flatten", "noise"]},
							"strength": {"type": "number", "exclusiveMinimum": 0},
							"falloff": {"type": "string", "enum": ["smooth", "linear"], "default": "smooth"},
							"target_height": {"type": "number", "description": "Required only for flatten."},
							"seed": {"type": "integer", "description": "Optional only for noise."},
						},
					},
				},
			}),
		}
	)


func _holes_spec() -> McpCustomToolSpec:
	return _base_spec(
		"terrain_holes",
		"Cut or refill circular open holes in managed heightmap terrain; visual and heightfield collision holes stay aligned.",
		&"holes",
		{
			"type": "object",
			"additionalProperties": false,
			"required": ["path", "areas"],
			"properties": _target_properties().merged({
				"areas": {
					"type": "array", "minItems": 1, "maxItems": 64,
					"items": {
						"type": "object", "additionalProperties": false,
						"required": ["center_x", "center_z", "radius", "mode"],
						"properties": {
							"center_x": {"type": "number"}, "center_z": {"type": "number"},
							"radius": {"type": "number", "exclusiveMinimum": 0},
							"mode": {"type": "string", "enum": ["cut", "fill"]},
						},
					},
				},
			}),
		}
	)


func _erode_spec() -> McpCustomToolSpec:
	return _base_spec(
		"terrain_erode",
		"Apply deterministic classic or natural thermal/hydraulic erosion and bake the result into preserved edit offsets.",
		&"erode",
		{
			"type": "object",
			"additionalProperties": false,
			"required": ["path"],
			"properties": _target_properties().merged({
				"algorithm": {"type": "string", "enum": ["thermal", "hydraulic", "thermal_natural", "hydraulic_natural"], "default": "thermal"},
				"iterations": {"type": "integer", "minimum": 1, "maximum": 200, "default": 20},
				"intensity": {"type": "number", "exclusiveMinimum": 0, "maximum": 1, "default": 0.5},
				"seed": {"type": "integer", "default": 1337, "description": "Deterministic hydraulic rainfall seed."},
				"preset": {"type": "string", "enum": ["soft", "balanced", "rugged"], "default": "balanced"},
				"region": {"type": "object", "additionalProperties": false, "required": ["radius"], "description": "Optional circular center or polyline corridor region.", "properties": {"center_x": {"type": "number"}, "center_z": {"type": "number"}, "points": {"type": "array", "minItems": 2, "maxItems": 64, "items": {"type": "object", "additionalProperties": false, "required": ["x", "z"], "properties": {"x": {"type": "number"}, "z": {"type": "number"}}}}, "radius": {"type": "number", "exclusiveMinimum": 0}}},
				"rain": {"type": "number", "minimum": 0, "maximum": 1},
				"erosion": {"type": "number", "minimum": 0, "maximum": 1},
				"deposition": {"type": "number", "minimum": 0, "maximum": 1},
				"evaporation": {"type": "number", "minimum": 0, "maximum": 1},
				"talus": {"type": "number", "minimum": 0, "maximum": 1},
				"ridge_preservation": {"type": "number", "minimum": 0, "maximum": 1, "default": 0},
			}),
		}
	)


func _landform_spec() -> McpCustomToolSpec:
	return _base_spec(
		"terrain_landform",
		"Apply up to 32 circular or polyline ridges, valleys, and plateaus with deterministic profiles and roughness in one undoable action.",
		&"landform",
		{
			"type": "object", "additionalProperties": false, "required": ["path", "features"],
			"properties": _target_properties().merged({
				"features": {"type": "array", "minItems": 1, "maxItems": 32, "items": {
					"type": "object", "additionalProperties": false,
					"required": ["type", "points", "width", "falloff_width", "profile", "height"],
					"properties": {
						"type": {"type": "string", "enum": ["ridge", "valley", "plateau"]},
						"points": {"type": "array", "minItems": 1, "maxItems": 64, "items": {"type": "object", "additionalProperties": false, "required": ["x", "z"], "properties": {"x": {"type": "number"}, "z": {"type": "number"}}}},
						"width": {"type": "number", "exclusiveMinimum": 0},
						"falloff_width": {"type": "number", "minimum": 0},
						"profile": {"type": "string", "enum": ["smooth", "sharp", "terraced"]},
						"height": {"type": "number"},
						"roughness": {"type": "number", "minimum": 0, "default": 0},
						"scale": {"type": "number", "exclusiveMinimum": 0, "default": 1},
						"seed": {"type": "integer", "default": 1337},
					},
				}},
			}),
		}
	)


func _road_spec() -> McpCustomToolSpec:
	return _base_spec(
		"terrain_road",
		"Grade a smooth road along a terrain-local polyline, feather its shoulders, and optionally paint it as road in one undoable action.",
		&"road",
		{
			"type": "object", "additionalProperties": false,
			"required": ["path", "points", "width"],
			"properties": _target_properties().merged({
				"points": {
					"type": "array", "minItems": 2, "maxItems": 64,
					"items": {"type": "object", "additionalProperties": false, "required": ["x", "z"], "properties": {"x": {"type": "number"}, "z": {"type": "number"}}},
				},
				"width": {"type": "number", "exclusiveMinimum": 0, "description": "Full flat corridor width in terrain units."},
				"shoulder_width": {"type": "number", "minimum": 0, "default": 2.0},
				"elevation_mode": {"type": "string", "enum": ["follow_smooth", "linear"], "default": "follow_smooth"},
				"start_height": {"type": "number", "description": "Optional absolute start height; requires end_height."},
				"end_height": {"type": "number", "description": "Optional absolute end height; requires start_height."},
				"max_grade": {"type": "number", "exclusiveMinimum": 0, "maximum": 1, "default": 0.35},
				"smoothing_passes": {"type": "integer", "minimum": 0, "maximum": 12, "default": 4},
				"paint_road": {"type": "boolean", "default": true},
				"falloff": {"type": "string", "enum": ["smooth", "linear"], "default": "smooth"},
			}),
		}
	)


func _paint_spec() -> McpCustomToolSpec:
	return _base_spec(
		"terrain_paint",
		"Paint semantic ground, road/dirt/sand, rock, or snow layers with circular or polyline strokes; use auto to restore generated classification.",
		&"paint",
		{
			"type": "object", "additionalProperties": false,
			"required": ["path", "strokes"],
			"properties": _target_properties().merged({
				"strokes": {
					"type": "array", "minItems": 1, "maxItems": 64,
					"items": {
						"type": "object", "additionalProperties": false,
						"required": ["points", "radius", "layer", "strength"],
						"properties": {
							"points": {"type": "array", "minItems": 1, "maxItems": 64, "items": {"type": "object", "additionalProperties": false, "required": ["x", "z"], "properties": {"x": {"type": "number"}, "z": {"type": "number"}}}},
							"radius": {"type": "number", "exclusiveMinimum": 0},
							"layer": {"type": "string", "enum": ["ground", "road", "dirt", "sand", "rock", "snow", "auto"]},
							"strength": {"type": "number", "exclusiveMinimum": 0, "maximum": 1},
							"falloff": {"type": "string", "enum": ["smooth", "linear"], "default": "smooth"},
						},
					},
				},
			}),
		}
	)


func _material_spec() -> McpCustomToolSpec:
	return _base_spec(
		"terrain_material",
		"Switch terrain between procedural, bundled texture, or custom texture rendering without changing its geometry or collision.",
		&"material",
		{
			"type": "object", "additionalProperties": false, "required": ["path"],
			"properties": _target_properties().merged({
				"render_mode": {"type": "string", "enum": ["procedural", "bundled", "custom"]},
				"texture_scale": {"type": "number", "exclusiveMinimum": 0},
				"material_preset": {"type": "string", "enum": ["natural", "desert", "snow", "volcanic", "alien"]},
				"surface_profile": {"type": "string", "enum": ["mountain_valley", "forest", "arid", "legacy"]},
				"texture_variants": _texture_variants_property(),
				"custom_textures": _custom_textures_property(),
			}),
		}
	)


func _common_properties() -> Dictionary:
	return {
		"size": {"type": "integer", "minimum": 4, "maximum": 256, "default": 48},
		"cell_size": {"type": "number", "exclusiveMinimum": 0, "default": 2.0},
		"seed": {"type": "integer", "default": 1337},
		"noise_type": {"type": "string", "enum": ["simplex", "simplex_smooth", "perlin", "ridged", "value"], "default": "simplex"},
		"frequency": {"type": "number", "exclusiveMinimum": 0, "default": 0.05},
		"octaves": {"type": "integer", "minimum": 1, "maximum": 6, "default": 3},
		"height_scale": {"type": "number", "exclusiveMinimum": 0, "default": 8.0},
		"base_height": {"type": "number", "default": 0.0},
		"generate_collision": {"type": "boolean", "default": true},
		"material_preset": {"type": "string", "enum": ["natural", "desert", "snow", "volcanic", "alien"], "default": "natural"},
		"render_mode": {"type": "string", "enum": ["procedural", "bundled", "custom"], "default": "bundled"},
		"texture_scale": {"type": "number", "exclusiveMinimum": 0, "default": 0.2},
		"custom_textures": _custom_textures_property(),
		"surface_profile": {"type": "string", "enum": ["mountain_valley", "forest", "arid", "legacy"], "default": "mountain_valley"},
		"texture_variants": _texture_variants_property(),
	}


func _target_properties() -> Dictionary:
	return {
		"path": {"type": "string", "description": "Scene path to a managed terrain Node3D."},
		"scene_file": {"type": "string", "description": "Optional edited-scene guard (res://...tscn)."},
	}


func _custom_textures_property() -> Dictionary:
	var map_properties := {
		"albedo": {"type": "string", "description": "res:// path to a Texture2D resource."},
		"normal": {"type": "string", "description": "res:// path to an OpenGL normal Texture2D resource."},
		"roughness": {"type": "string", "description": "res:// path to a roughness Texture2D resource."},
	}
	var layer_property := {"type": "object", "additionalProperties": false, "properties": map_properties}
	return {
		"type": "object", "additionalProperties": false,
		"properties": {
			"ground": layer_property.duplicate(true),
			"road": layer_property.duplicate(true),
			"rock": layer_property.duplicate(true),
			"snow": layer_property.duplicate(true),
		},
	}


func _texture_variants_property() -> Dictionary:
	var variant := {"type": "integer", "minimum": 0, "maximum": 2, "default": 0}
	return {
		"type": "object", "additionalProperties": false,
		"properties": {"ground": variant.duplicate(), "dirt": variant.duplicate(), "rock": variant.duplicate()},
	}
