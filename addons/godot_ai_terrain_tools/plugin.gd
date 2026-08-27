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
	spec.promoted = true
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
		"Apply deterministic thermal or hydraulic erosion to managed terrain and bake the result into preserved edit offsets.",
		&"erode",
		{
			"type": "object",
			"additionalProperties": false,
			"required": ["path"],
			"properties": _target_properties().merged({
				"algorithm": {"type": "string", "enum": ["thermal", "hydraulic"], "default": "thermal"},
				"iterations": {"type": "integer", "minimum": 1, "maximum": 200, "default": 20},
				"intensity": {"type": "number", "exclusiveMinimum": 0, "maximum": 1, "default": 0.5},
				"seed": {"type": "integer", "default": 1337, "description": "Deterministic hydraulic rainfall seed."},
			}),
		}
	)


func _common_properties() -> Dictionary:
	return {
		"size": {"type": "integer", "minimum": 4, "maximum": 128, "default": 48},
		"cell_size": {"type": "number", "exclusiveMinimum": 0, "default": 2.0},
		"seed": {"type": "integer", "default": 1337},
		"noise_type": {"type": "string", "enum": ["simplex", "simplex_smooth", "perlin", "ridged", "value"], "default": "simplex"},
		"frequency": {"type": "number", "exclusiveMinimum": 0, "default": 0.05},
		"octaves": {"type": "integer", "minimum": 1, "maximum": 6, "default": 3},
		"height_scale": {"type": "number", "exclusiveMinimum": 0, "default": 8.0},
		"base_height": {"type": "number", "default": 0.0},
		"generate_collision": {"type": "boolean", "default": true},
		"material_preset": {"type": "string", "enum": ["natural", "desert", "snow", "volcanic", "alien"], "default": "natural"},
	}


func _target_properties() -> Dictionary:
	return {
		"path": {"type": "string", "description": "Scene path to a managed terrain Node3D."},
		"scene_file": {"type": "string", "description": "Optional edited-scene guard (res://...tscn)."},
	}
