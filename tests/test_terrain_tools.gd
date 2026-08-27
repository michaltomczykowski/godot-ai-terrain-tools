@tool
extends McpTestSuite

## Synchronous coverage for the standalone terrain addon.
##
## McpTestSuite bodies cannot await deferred custom-tool replies.  The tests in
## this file therefore exercise the handler's synchronous validation and scene
## helpers, and drive TerrainBuildJob directly to completion.  Live deferred
## create/regenerate calls are covered by the integration/smoke harness.

const TerrainHandler := preload("res://addons/godot_ai_terrain_tools/terrain_handler.gd")
const TerrainBuildJob := preload("res://addons/godot_ai_terrain_tools/terrain_build_job.gd")
const TerrainPlugin := preload("res://addons/godot_ai_terrain_tools/plugin.gd")

const META_KEY := &"godot_ai_terrain_tools"
const FORMAT_VERSION := 1

var _handler: TerrainHandler
var _undo_redo: EditorUndoRedoManager
var _saved_registry_instance: McpToolRegistry
var _registry_test_registry: McpToolRegistry
var _registry_test_connection: McpConnection


func suite_name() -> String:
	return "terrain_tools"


func suite_setup(ctx: Dictionary) -> void:
	_handler = TerrainHandler.new()
	_undo_redo = ctx.get("undo_redo")
	## The registration test temporarily installs a private registry singleton.
	## Keep the live Godot AI registry isolated even if an assertion or script
	## error interrupts that test before its final cleanup lines.
	_saved_registry_instance = McpToolRegistry.get_instance()


func suite_teardown() -> void:
	if _registry_test_registry != null and is_instance_valid(_registry_test_registry):
		_registry_test_registry.clear()
	McpToolRegistry._instance = _saved_registry_instance
	if _registry_test_connection != null and is_instance_valid(_registry_test_connection):
		_registry_test_connection.free()


func teardown() -> void:
	## The direct undo/redo test creates a real editor action.  Do not leave it
	## ahead of another suite's history.
	if _undo_redo != null:
		_undo_redo.clear_history()


func _normalized(params: Dictionary = {}) -> Dictionary:
	return _handler._normalized_params(params)


func _build(params: Dictionary = {}) -> Dictionary:
	var checked := _normalized(params)
	if checked.has("error"):
		return checked
	var job := TerrainBuildJob.new(checked.params)
	while not job.step(1000000):
		pass
	return job.result()


func _mesh_arrays(built: Dictionary) -> Array:
	return (built.mesh as Mesh).surface_get_arrays(0)


func _new_container(container_name: String = "_McpTestTerrainContainer") -> Node3D:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	var container := Node3D.new()
	container.name = container_name
	root.add_child(container)
	container.owner = root
	return container


func _child(parent: Node, child_name: String) -> Node:
	for child in parent.get_children():
		if child.name == child_name:
			return child
	return null


func _assert_finite_color(color: Color) -> void:
	assert_true(is_finite(color.r))
	assert_true(is_finite(color.g))
	assert_true(is_finite(color.b))
	assert_true(is_finite(color.a))


## ----- builder output and numerical regressions -----

func test_builder_defaults_and_counts() -> void:
	var checked := _normalized()
	assert_has_key(checked, "params")
	assert_eq(checked.params.size, 48)
	assert_eq(checked.params.cell_size, 2.0)
	assert_eq(checked.params.seed, 1337)
	assert_eq(checked.params.noise_type, "simplex")
	assert_eq(checked.params.frequency, 0.05)
	assert_eq(checked.params.octaves, 3)
	assert_eq(checked.params.height_scale, 8.0)
	assert_eq(checked.params.base_height, 0.0)
	assert_true(checked.params.generate_collision)

	var built := _build({"size": 6})
	assert_has_key(built, "mesh")
	assert_eq(built.vertices, 36)
	assert_eq(built.triangle_count, 2 * 5 * 5)
	assert_eq((built.triangles as PackedVector3Array).size(), 3 * 2 * 5 * 5)


func test_builder_is_deterministic_for_same_seed_and_settings() -> void:
	var first := _build({"size": 8, "seed": 42})
	var second := _build({"size": 8, "seed": 42})
	var first_arrays := _mesh_arrays(first)
	var second_arrays := _mesh_arrays(second)
	assert_eq(first_arrays[Mesh.ARRAY_VERTEX], second_arrays[Mesh.ARRAY_VERTEX])
	assert_eq(first_arrays[Mesh.ARRAY_NORMAL], second_arrays[Mesh.ARRAY_NORMAL])
	assert_eq(first_arrays[Mesh.ARRAY_COLOR], second_arrays[Mesh.ARRAY_COLOR])
	assert_eq(first_arrays[Mesh.ARRAY_INDEX], second_arrays[Mesh.ARRAY_INDEX])


func test_builder_supports_every_published_noise_type() -> void:
	for noise_type in ["simplex", "simplex_smooth", "perlin", "ridged", "value"]:
		var built := _build({"size": 4, "noise_type": noise_type})
		assert_has_key(built, "mesh", "noise type must build: %s" % noise_type)
		assert_eq(built.vertices, 16, "noise type must preserve grid vertices: %s" % noise_type)
		assert_eq(built.triangle_count, 18, "noise type must preserve triangles: %s" % noise_type)


func test_builder_seed_changes_half_offset_origin_sample() -> void:
	var first := _mesh_arrays(_build({"size": 4, "seed": 1}))
	var second := _mesh_arrays(_build({"size": 4, "seed": 2}))
	var first_vertices: PackedVector3Array = first[Mesh.ARRAY_VERTEX]
	var second_vertices: PackedVector3Array = second[Mesh.ARRAY_VERTEX]
	assert_ne(first_vertices[0].y, second_vertices[0].y,
		"the half-cell origin sample must retain seed sensitivity")


func test_builder_applies_frequency_once() -> void:
	var params: Dictionary = _normalized({
		"size": 4, "seed": 91, "frequency": 0.17, "height_scale": 6.0,
	}).params
	var built := _build(params)
	var arrays := _mesh_arrays(built)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var noise := FastNoiseLite.new()
	noise.seed = params.seed
	noise.frequency = params.frequency
	noise.fractal_octaves = params.octaves
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	var expected: float = params.base_height + noise.get_noise_2d(0.5, 0.5) * params.height_scale
	assert_true(is_equal_approx(vertices[0].y, expected),
		"FastNoiseLite frequency must not also scale the sample coordinates")


func test_builder_emits_up_facing_godot_winding_and_lighting_normals() -> void:
	var arrays := _mesh_arrays(_build({"size": 6, "seed": 19}))
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	assert_eq(indices[0], 0)
	assert_eq(indices[1], 1)
	assert_eq(indices[2], 6)
	var face_normal := (vertices[indices[1]] - vertices[indices[0]]).cross(
		vertices[indices[2]] - vertices[indices[0]])
	assert_true(face_normal.y < 0.0,
		"Godot's clockwise front face must have a negative-Y geometric cross product")
	assert_gt(normals[indices[0]].y, 0.0,
		"lighting normals must point upward even though Godot uses clockwise front faces")


func test_builder_vertex_colors_are_finite() -> void:
	var colors: PackedColorArray = _mesh_arrays(_build({"size": 8}))[Mesh.ARRAY_COLOR]
	assert_eq(colors.size(), 64)
	for color in colors:
		_assert_finite_color(color)


## ----- validation and all-or-nothing guards -----

func test_normalized_params_reject_invalid_values_and_types() -> void:
	for invalid in [
		{"size": 3}, {"size": 129}, {"size": 4.5}, {"size": "48"},
		{"cell_size": 0.0}, {"cell_size": -INF}, {"cell_size": INF}, {"cell_size": NAN},
		{"cell_size": "2.0"},
		{"frequency": 0.0}, {"frequency": -0.1}, {"frequency": -INF},
		{"frequency": INF}, {"frequency": NAN},
		{"frequency": "0.05"},
		{"height_scale": 0.0}, {"height_scale": -1.0}, {"height_scale": -INF},
		{"height_scale": INF}, {"height_scale": NAN},
		{"height_scale": "8.0"},
		{"base_height": INF}, {"base_height": -INF}, {"base_height": NAN},
		{"base_height": "0.0"},
		{"seed": "not-an-integer"}, {"seed": true}, {"seed": 1.5}, {"seed": INF}, {"seed": NAN},
		{"octaves": 0}, {"octaves": 7}, {"octaves": "3"},
		{"octaves": 1.5}, {"noise_type": "billow"},
		{"noise_type": 7}, {"generate_collision": "yes"}, {"generate_collision": 1},
	]:
		assert_is_error(_normalized(invalid))


func test_create_validates_before_mutation_for_invalid_options_and_paths() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No edited scene")
		return
	var before := root.get_child_count()
	var bad_options := _handler.create({"size": 129}, null)
	assert_is_error(bad_options)
	assert_eq(root.get_child_count(), before)
	var bad_path := _handler.create({"parent_path": "/%s/does_not_exist" % root.name}, null)
	assert_is_error(bad_path)
	assert_eq(root.get_child_count(), before)
	var bad_parent_type := _handler.create({"parent_path": 42}, null)
	assert_is_error(bad_parent_type, "INVALID_PARAMS")
	assert_eq(root.get_child_count(), before)
	var bad_scene_type := _handler.create({"scene_file": 42}, null)
	assert_is_error(bad_scene_type, "INVALID_PARAMS")
	assert_eq(root.get_child_count(), before)
	var unknown_option := _handler.create({"unexpected": true}, null)
	assert_is_error(unknown_option, "INVALID_PARAMS")
	assert_eq(root.get_child_count(), before)
	var bad_name_type := _handler.create({"name": 42}, null)
	assert_is_error(bad_name_type, "INVALID_PARAMS")
	assert_eq(root.get_child_count(), before)
	var bad_name := _handler.create({"name": "bad/name"}, null)
	assert_is_error(bad_name)
	assert_eq(root.get_child_count(), before)
	var empty_name := _handler.create({"name": ""}, null)
	assert_is_error(empty_name, "INVALID_PARAMS")
	assert_eq(root.get_child_count(), before)


func test_create_rejects_wrong_parent_type_and_scene_guard() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No edited scene")
		return
	var node_2d := Node2D.new()
	node_2d.name = "_McpTestTerrainNode2D"
	root.add_child(node_2d)
	node_2d.owner = root
	var wrong_type := _handler.create({"parent_path": "/%s/%s" % [root.name, node_2d.name]}, null)
	assert_is_error(wrong_type, "WRONG_TYPE")
	var mismatch := _handler.create({"scene_file": "res://not_the_edited_scene.tscn"}, null)
	assert_is_error(mismatch, "EDITED_SCENE_MISMATCH")


func test_busy_rejection_is_retryable_for_both_operations() -> void:
	_handler._busy = true
	var create_result := _handler.create({}, null)
	assert_is_error(create_result, "terrain_tools.BUSY")
	var create_data: Dictionary = create_result.error.get("data", {})
	assert_true(create_data.get("retryable", false))
	var regenerate_result := _handler.regenerate({}, null)
	assert_is_error(regenerate_result, "terrain_tools.BUSY")
	var regenerate_data: Dictionary = regenerate_result.error.get("data", {})
	assert_true(regenerate_data.get("retryable", false))
	_handler._busy = false


func test_regenerate_rejects_missing_wrong_type_and_unmanaged_nodes() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No edited scene")
		return
	assert_is_error(_handler.regenerate({}, null), "INVALID_PARAMS")
	assert_is_error(_handler.regenerate({"path": ""}, null), "INVALID_PARAMS")
	assert_is_error(_handler.regenerate({"path": 42}, null), "INVALID_PARAMS")
	assert_is_error(_handler.regenerate({"path": "/%s" % root.name, "scene_file": 42}, null), "INVALID_PARAMS")
	assert_is_error(_handler.regenerate({"path": "/%s/does_not_exist" % root.name}, null), "NODE_NOT_FOUND")
	var node_2d := Node2D.new()
	node_2d.name = "_McpTestTerrainRegenerate2D"
	root.add_child(node_2d)
	node_2d.owner = root
	assert_is_error(_handler.regenerate({"path": "/%s/%s" % [root.name, node_2d.name]}, null), "WRONG_TYPE")
	var unmanaged := Node3D.new()
	unmanaged.name = "_McpTestTerrainUnmanaged"
	root.add_child(unmanaged)
	unmanaged.owner = root
	assert_is_error(_handler.regenerate({"path": "/%s/%s" % [root.name, unmanaged.name]}, null))


## ----- managed structure, metadata, collision and ownership helpers -----

func test_make_children_controls_collision_and_assigns_owners() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No edited scene")
		return
	var built := _build({"size": 5})
	var no_collision_container := _new_container("_McpTestTerrainNoCollision")
	var without_collision: Array = _handler._make_children(built, false)
	assert_eq(without_collision.size(), 1)
	no_collision_container.add_child(without_collision[0])
	_handler._assign_owners(no_collision_container, root)
	assert_true(without_collision[0] is MeshInstance3D)
	assert_eq(no_collision_container.owner, root)
	assert_eq(without_collision[0].owner, root)

	var collision_container := _new_container("_McpTestTerrainWithCollision")
	var with_collision: Array = _handler._make_children(built, true)
	assert_eq(with_collision.size(), 2)
	collision_container.add_child(with_collision[0])
	collision_container.add_child(with_collision[1])
	_handler._assign_owners(collision_container, root)
	assert_eq(collision_container.owner, root)
	assert_true(with_collision[1] is StaticBody3D)
	assert_eq(with_collision[1].owner, root)
	var collision_shape := with_collision[1].get_child(0) as CollisionShape3D
	assert_true(collision_shape.shape is ConcavePolygonShape3D)
	assert_eq(collision_shape.owner, root)


func test_metadata_and_managed_structure_are_round_trippable() -> void:
	var container := Node3D.new()
	track(container)
	var built := _build({"size": 5, "seed": 88})
	var checked := _normalized({"size": 5, "seed": 88})
	var children: Array = _handler._make_children(built, true)
	for child in children:
		container.add_child(child)
	container.set_meta(META_KEY, _handler._metadata(checked.params))
	var metadata := _handler._managed_metadata(container)
	assert_has_key(metadata, "metadata")
	assert_eq(metadata.metadata.format_version, FORMAT_VERSION)
	assert_eq(metadata.metadata.params, checked.params)
	var captured := _handler._capture_managed_nodes(container)
	assert_has_key(captured, "nodes")
	assert_eq(captured.nodes.size(), 2)
	assert_eq(captured.nodes[0].name, "TerrainMesh")
	assert_eq(captured.nodes[1].name, "TerrainCollision")


func test_response_carries_effective_params_and_build_counts() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No edited scene")
		return
	var container := _new_container("_McpTestTerrainResponse")
	var checked := _normalized({
		"size": 6,
		"cell_size": 1.25,
		"seed": 123,
		"noise_type": "perlin",
		"frequency": 0.11,
		"octaves": 4,
		"height_scale": 5.0,
		"base_height": -2.0,
		"generate_collision": false,
	})
	var built := _build(checked.params)
	var response := _handler._response(container, root, checked.params, built)
	assert_eq(response.path, "/%s/%s" % [root.name, container.name])
	assert_eq(response.name, container.name)
	assert_eq(response.params, checked.params)
	assert_eq(response.vertices, 36)
	assert_eq(response.triangles, 50)
	assert_false(response.generate_collision)
	assert_true(response.undoable)


func test_managed_metadata_rejects_unmanaged_and_unsupported_formats() -> void:
	var container := Node3D.new()
	track(container)
	assert_is_error(_handler._managed_metadata(container))
	container.set_meta(META_KEY, {"format_version": FORMAT_VERSION + 1, "params": {}})
	assert_is_error(_handler._managed_metadata(container))
	container.set_meta(META_KEY, {"format_version": FORMAT_VERSION})
	assert_is_error(_handler._managed_metadata(container))


func test_capture_rejects_collision_shape_without_concave_shape() -> void:
	var container := Node3D.new()
	track(container)
	var mesh_children: Array = _handler._make_children(_build({"size": 4}), false)
	container.add_child(mesh_children[0])
	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "CollisionShape3D"
	body.add_child(collision_shape)
	container.add_child(body)
	assert_is_error(_handler._capture_managed_nodes(container), "terrain_tools.INVALID_STRUCTURE")


func test_replace_managed_nodes_preserves_unmanaged_children() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No edited scene")
		return
	var container := _new_container()
	var marker := Node3D.new()
	marker.name = "KeepMe"
	container.add_child(marker)
	marker.owner = root
	var old_children: Array = _handler._make_children(_build({"size": 5, "seed": 1}), true)
	for child in old_children:
		track(child)
		container.add_child(child)
	_handler._assign_owners(container, root)
	var replacement: Array = _handler._make_children(_build({"size": 5, "seed": 2}), false)
	for child in replacement:
		track(child)
	_handler._replace_managed_nodes(container, old_children, replacement, root)
	for child in old_children:
		assert_eq(child.get_parent(), null, "the captured managed node must be detached")
	assert_eq(_child(container, "KeepMe"), marker)
	assert_true(_child(container, "TerrainMesh") != null)
	assert_true(_child(container, "TerrainCollision") == null)
	assert_eq(_child(container, "TerrainMesh").owner, root)


func test_managed_replacement_can_be_undone_and_redone_as_one_action() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No edited scene")
		return
	var container := _new_container()
	var previous_params: Dictionary = _normalized({"size": 5, "seed": 3}).params
	var previous_built := _build(previous_params)
	var previous: Array = _handler._make_children(previous_built, true)
	for child in previous:
		track(child)
		container.add_child(child)
	_handler._assign_owners(container, root)
	var old_meta := _handler._metadata(previous_params)
	container.set_meta(META_KEY, old_meta)
	var replacement_params: Dictionary = _normalized({"size": 5, "seed": 4}).params
	var replacement_built := _build(replacement_params)
	var replacement: Array = _handler._make_children(replacement_built, false)
	for child in replacement:
		track(child)
	var new_meta := _handler._metadata(replacement_params)
	var previous_vertices: PackedVector3Array = _mesh_arrays(previous_built)[Mesh.ARRAY_VERTEX]
	var replacement_vertices: PackedVector3Array = _mesh_arrays(replacement_built)[Mesh.ARRAY_VERTEX]
	_undo_redo.create_action("_McpTestTerrain replacement")
	## Route the action to the edited scene's history before adding references,
	## using the same metadata write as the real regeneration action.
	_undo_redo.add_do_method(container, "set_meta", META_KEY, new_meta)
	_undo_redo.add_do_method(_handler, "_replace_managed_nodes", container, previous, replacement, root)
	_undo_redo.add_undo_method(_handler, "_replace_managed_nodes", container, replacement, previous, root)
	_undo_redo.add_undo_method(container, "set_meta", META_KEY, old_meta)
	for node in replacement:
		_undo_redo.add_do_reference(node)
	for node in previous:
		_undo_redo.add_undo_reference(node)
	_undo_redo.commit_action()
	assert_true(_child(container, "TerrainCollision") == null)
	for node in previous:
		assert_eq(node.get_parent(), null, "do must remove exactly the captured previous nodes")
	assert_eq(container.get_meta(META_KEY), new_meta)
	assert_ne(_child(container, "TerrainMesh").mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], previous_vertices)
	assert_true(editor_undo(_undo_redo))
	assert_true(_child(container, "TerrainCollision") is StaticBody3D)
	for node in replacement:
		assert_eq(node.get_parent(), null, "undo must detach exactly the generated replacement nodes")
	assert_eq(container.get_meta(META_KEY), old_meta)
	assert_eq(_child(container, "TerrainMesh").mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], previous_vertices)
	assert_true(editor_redo(_undo_redo))
	assert_true(_child(container, "TerrainCollision") == null)
	assert_eq(container.get_meta(META_KEY), new_meta)
	assert_eq(_child(container, "TerrainMesh").mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], replacement_vertices)


## ----- promoted custom-tool registration contract -----

func test_promoted_specs_expose_the_published_custom_tool_contract() -> void:
	var plugin := track(TerrainPlugin.new())
	var create_spec: McpCustomToolSpec = plugin._create_spec()
	var regenerate_spec: McpCustomToolSpec = plugin._regenerate_spec()
	assert_eq(create_spec.name, "terrain_create")
	assert_eq(regenerate_spec.name, "terrain_regenerate")
	assert_true(create_spec.promoted)
	assert_true(regenerate_spec.promoted)
	assert_true(create_spec.requires_writable)
	assert_true(create_spec.undoable)
	assert_true(create_spec.deferred)
	assert_eq(create_spec.timeout_ms, 30000)
	assert_true(regenerate_spec.params_schema.required.has("path"))
	assert_eq(create_spec.method, &"create")
	assert_eq(regenerate_spec.method, &"regenerate")
	assert_eq(create_spec.validate().size(), 0)
	assert_eq(regenerate_spec.validate().size(), 0)


func test_registration_batch_adds_both_specs_and_source_cleanup_removes_them() -> void:
	var dispatcher := McpDispatcher.new(McpLogBuffer.new())
	_registry_test_connection = McpConnection.new()
	var locator := McpServiceLocator.new()
	locator.setup(_registry_test_connection, McpLogBuffer.new())
	_registry_test_registry = McpToolRegistry.new()
	_registry_test_registry.setup(dispatcher, locator)
	var plugin := track(TerrainPlugin.new())
	plugin._registry = _registry_test_registry
	var valid_spec: McpCustomToolSpec = plugin._create_spec()
	var invalid_spec: McpCustomToolSpec = plugin._regenerate_spec()
	invalid_spec.name = "not a valid tool name"
	assert_false(_registry_test_registry.batch_register([valid_spec, invalid_spec]))
	assert_true(_registry_test_registry.get_spec("terrain_create") == null)
	assert_false(dispatcher.has_command("custom_tool:terrain_create"))
	plugin._register_tools()
	assert_true(_registry_test_registry.get_spec("terrain_create") != null)
	assert_true(_registry_test_registry.get_spec("terrain_regenerate") != null)
	assert_true(dispatcher.has_command("custom_tool:terrain_create"))
	assert_true(dispatcher.has_command("custom_tool:terrain_regenerate"))
	assert_eq(_registry_test_registry.unregister_source(plugin.SOURCE_PATH), 2)
	assert_true(_registry_test_registry.get_spec("terrain_create") == null)
	assert_false(dispatcher.has_command("custom_tool:terrain_regenerate"))
