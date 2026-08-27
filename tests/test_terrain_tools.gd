@tool
extends McpTestSuite

## Synchronous coverage for the standalone terrain addon.
##
## McpTestSuite bodies cannot await deferred custom-tool replies.  The tests in
## this file therefore exercise the handler's synchronous validation and scene
## helpers, and drive TerrainBuildJob directly to completion.  Live deferred
## create/regenerate calls are covered by the integration/smoke harness.

const TerrainHandler := preload("res://addons/godot_ai_terrain_tools/terrain_handler.gd")
const TerrainData := preload("res://addons/godot_ai_terrain_tools/terrain_data.gd")
const TerrainBuildJob := preload("res://addons/godot_ai_terrain_tools/terrain_build_job.gd")
const TerrainErosionJob := preload("res://addons/godot_ai_terrain_tools/terrain_erosion_job.gd")
const TerrainPlugin := preload("res://addons/godot_ai_terrain_tools/plugin.gd")

const META_KEY := &"godot_ai_terrain_tools"
const FORMAT_VERSION := 2

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
	var data := _new_data(checked.params)
	var job := TerrainBuildJob.new(data)
	while not job.step(1000000):
		pass
	return job.result()


func _new_data(params: Dictionary) -> TerrainData:
	var data := TerrainData.new()
	data.initialize(params)
	return data


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
	assert_true(checked.params.has("material_preset"))
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
		{"base_height": 10000000.0}, {"height_scale": 10000000.0},
		{"base_height": "0.0"},
		{"seed": "not-an-integer"}, {"seed": true}, {"seed": 1.5}, {"seed": INF}, {"seed": NAN},
		{"seed": 2147483648}, {"seed": -2147483649},
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
	var create_only_reset := _handler.create({"reset_modifications": true}, null)
	assert_is_error(create_only_reset, "INVALID_PARAMS")
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
	for operation in ["sculpt", "holes", "erode"]:
		var result: Dictionary = _handler.call(operation, {}, null)
		assert_is_error(result, "terrain_tools.BUSY")
	var other_handler := TerrainHandler.new()
	assert_is_error(other_handler.sculpt({}, null), "terrain_tools.BUSY",
		"BUSY must serialize separate promoted-tool handler instances")
	_handler._busy = false


func test_regenerate_rejects_missing_wrong_type_and_unmanaged_nodes() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No edited scene")
		return
	assert_is_error(_handler.regenerate({}, null), "INVALID_PARAMS")
	assert_is_error(_handler.regenerate({"path": ""}, null), "INVALID_PARAMS")
	assert_is_error(_handler.regenerate({"path": 42}, null), "INVALID_PARAMS")
	assert_is_error(_handler.regenerate({"path": "/%s" % root.name, "reset_modifications": "yes"}, null), "INVALID_PARAMS")
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
	assert_true(collision_shape.shape is HeightMapShape3D)
	assert_eq(collision_shape.owner, root)


func test_metadata_and_managed_structure_are_round_trippable() -> void:
	var container := Node3D.new()
	track(container)
	var built := _build({"size": 5, "seed": 88})
	var checked := _normalized({"size": 5, "seed": 88})
	var children: Array = _handler._make_children(built, true)
	for child in children:
		container.add_child(child)
	container.set_meta(META_KEY, _handler._metadata(built.data))
	var metadata := _handler._managed_metadata(container)
	assert_has_key(metadata, "metadata")
	assert_eq(metadata.metadata.format_version, FORMAT_VERSION)
	assert_eq(metadata.metadata.params, checked.params)
	assert_true(metadata.metadata.data is TerrainData)
	assert_true(metadata.state.data is TerrainData)
	var captured := _handler._capture_managed_nodes(container)
	assert_has_key(captured, "nodes")
	assert_eq(captured.nodes.size(), 2)
	assert_eq(captured.nodes[0].name, "TerrainMesh")
	assert_eq(captured.nodes[1].name, "TerrainCollision")


func test_v2_metadata_rejects_corrupt_height_and_hole_arrays() -> void:
	var data := _new_data(_normalized({"size": 5, "seed": 89}).params)
	_build_data(data)
	var container := Node3D.new()
	track(container)
	container.set_meta(META_KEY, _handler._metadata(data))
	data.edit_offsets[0] = NAN
	assert_is_error(_handler._managed_state(container), "terrain_tools.UNSUPPORTED_FORMAT")
	data.edit_offsets[0] = 0.0
	data.holes[0] = 2
	assert_is_error(_handler._managed_state(container), "terrain_tools.UNSUPPORTED_FORMAT")


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
	var response := _handler._response(container, root, built.data, built)
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


func test_capture_rejects_collision_shape_without_heightmap_shape() -> void:
	var container := Node3D.new()
	track(container)
	var mesh_children: Array = _handler._make_children(_build({"size": 4}), false)
	container.add_child(mesh_children[0])
	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "CollisionShape3D"
	collision_shape.shape = ConcavePolygonShape3D.new()
	body.add_child(collision_shape)
	container.add_child(body)
	assert_is_error(_handler._capture_managed_nodes(container), "terrain_tools.INVALID_STRUCTURE")
	var legacy_capture := _handler._capture_managed_nodes(container, true)
	assert_has_key(legacy_capture, "nodes",
		"legacy ConcavePolygon collision must be capturable only for migration")
	assert_eq(legacy_capture.nodes.size(), 2)


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


func test_target_guard_rejects_managed_child_replacement_and_reparent() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No edited scene")
		return
	var replacement_container := _new_container("_McpTestTargetReplacement")
	var replacement_built := _build({"size": 4, "seed": 61})
	var managed_children: Array = _handler._make_children(replacement_built, false)
	for child in managed_children:
		track(child)
		replacement_container.add_child(child)
	_handler._assign_owners(replacement_container, root)
	replacement_container.set_meta(META_KEY, _handler._metadata(replacement_built.data))
	var replacement_target := _handler._managed_target({
		"path": "/%s/%s" % [root.name, replacement_container.name],
	})
	assert_has_key(replacement_target, "container")
	assert_true(_handler._target_still_valid(replacement_target))
	var original_mesh := _child(replacement_container, "TerrainMesh")
	var replacement_mesh := MeshInstance3D.new()
	replacement_mesh.name = "TerrainMesh"
	replacement_mesh.mesh = replacement_built.mesh
	track(replacement_mesh)
	replacement_container.remove_child(original_mesh)
	replacement_container.add_child(replacement_mesh)
	_handler._assign_owners(replacement_mesh, root)
	assert_false(_handler._target_still_valid(replacement_target),
		"a replaced managed child must invalidate a deferred target")

	var reparent_container := _new_container("_McpTestTargetReparent")
	var reparent_built := _build({"size": 4, "seed": 62})
	var reparent_mesh := _handler._make_children(reparent_built, false)[0]
	track(reparent_mesh)
	reparent_container.add_child(reparent_mesh)
	_handler._assign_owners(reparent_container, root)
	reparent_container.set_meta(META_KEY, _handler._metadata(reparent_built.data))
	var reparent_target := _handler._managed_target({
		"path": "/%s/%s" % [root.name, reparent_container.name],
	})
	assert_has_key(reparent_target, "container")
	var detached_parent := Node3D.new()
	detached_parent.name = "_McpTestTargetDetachedParent"
	root.add_child(detached_parent)
	detached_parent.owner = root
	track(detached_parent)
	reparent_container.remove_child(reparent_mesh)
	detached_parent.add_child(reparent_mesh)
	assert_false(_handler._target_still_valid(reparent_target),
		"a reparented managed child must invalidate a deferred target")


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
	previous_built.data.edit_offsets[4] = 1.25
	previous_built.data.holes[6] = 1
	var old_meta := _handler._metadata(previous_built.data)
	container.set_meta(META_KEY, old_meta)
	var replacement_params: Dictionary = _normalized({"size": 5, "seed": 4}).params
	var replacement_built := _build(replacement_params)
	replacement_built.data.edit_offsets[4] = -2.5
	replacement_built.data.holes[6] = 0
	var replacement: Array = _handler._make_children(replacement_built, false)
	for child in replacement:
		track(child)
	var new_meta := _handler._metadata(replacement_built.data)
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
	assert_eq((container.get_meta(META_KEY).data as TerrainData).edit_offsets,
		replacement_built.data.edit_offsets)
	assert_eq((container.get_meta(META_KEY).data as TerrainData).holes,
		replacement_built.data.holes)
	assert_ne(_child(container, "TerrainMesh").mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], previous_vertices)
	assert_true(editor_undo(_undo_redo))
	assert_true(_child(container, "TerrainCollision") is StaticBody3D)
	for node in replacement:
		assert_eq(node.get_parent(), null, "undo must detach exactly the generated replacement nodes")
	assert_eq(container.get_meta(META_KEY), old_meta)
	assert_eq((container.get_meta(META_KEY).data as TerrainData).edit_offsets,
		previous_built.data.edit_offsets)
	assert_eq((container.get_meta(META_KEY).data as TerrainData).holes,
		previous_built.data.holes)
	assert_eq(_child(container, "TerrainMesh").mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], previous_vertices)
	assert_true(editor_redo(_undo_redo))
	assert_true(_child(container, "TerrainCollision") == null)
	assert_eq(container.get_meta(META_KEY), new_meta)
	assert_eq((container.get_meta(META_KEY).data as TerrainData).edit_offsets,
		replacement_built.data.edit_offsets)
	assert_eq((container.get_meta(META_KEY).data as TerrainData).holes,
		replacement_built.data.holes)
	assert_eq(_child(container, "TerrainMesh").mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], replacement_vertices)


## ----- promoted custom-tool registration contract -----

func test_promoted_specs_expose_the_published_custom_tool_contract() -> void:
	var plugin := track(TerrainPlugin.new())
	var create_spec: McpCustomToolSpec = plugin._create_spec()
	var regenerate_spec: McpCustomToolSpec = plugin._regenerate_spec()
	var sculpt_spec: McpCustomToolSpec = plugin._sculpt_spec()
	var holes_spec: McpCustomToolSpec = plugin._holes_spec()
	var erode_spec: McpCustomToolSpec = plugin._erode_spec()
	assert_eq(create_spec.name, "terrain_create")
	assert_eq(regenerate_spec.name, "terrain_regenerate")
	assert_eq(sculpt_spec.name, "terrain_sculpt")
	assert_eq(holes_spec.name, "terrain_holes")
	assert_eq(erode_spec.name, "terrain_erode")
	assert_true(create_spec.promoted)
	assert_true(regenerate_spec.promoted)
	assert_true(sculpt_spec.promoted)
	assert_true(holes_spec.promoted)
	assert_true(erode_spec.promoted)
	assert_true(create_spec.requires_writable)
	assert_true(create_spec.undoable)
	assert_true(create_spec.deferred)
	assert_eq(create_spec.timeout_ms, 30000)
	assert_true(regenerate_spec.params_schema.required.has("path"))
	assert_true(sculpt_spec.params_schema.required.has("path"))
	assert_true(holes_spec.params_schema.required.has("path"))
	assert_true(erode_spec.params_schema.required.has("path"))
	assert_has_key(create_spec.params_schema.properties, "material_preset")
	assert_has_key(regenerate_spec.params_schema.properties, "material_preset")
	assert_has_key(regenerate_spec.params_schema.properties, "reset_modifications")
	assert_eq(create_spec.method, &"create")
	assert_eq(regenerate_spec.method, &"regenerate")
	assert_eq(sculpt_spec.method, &"sculpt")
	assert_eq(holes_spec.method, &"holes")
	assert_eq(erode_spec.method, &"erode")
	assert_eq(create_spec.validate().size(), 0)
	assert_eq(regenerate_spec.validate().size(), 0)
	assert_eq(sculpt_spec.validate().size(), 0)
	assert_eq(holes_spec.validate().size(), 0)
	assert_eq(erode_spec.validate().size(), 0)


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
	assert_true(_registry_test_registry.get_spec("terrain_sculpt") != null)
	assert_true(_registry_test_registry.get_spec("terrain_holes") != null)
	assert_true(_registry_test_registry.get_spec("terrain_erode") != null)
	assert_true(dispatcher.has_command("custom_tool:terrain_create"))
	assert_true(dispatcher.has_command("custom_tool:terrain_regenerate"))
	assert_true(dispatcher.has_command("custom_tool:terrain_sculpt"))
	assert_true(dispatcher.has_command("custom_tool:terrain_holes"))
	assert_true(dispatcher.has_command("custom_tool:terrain_erode"))
	assert_eq(_registry_test_registry.unregister_source(plugin.SOURCE_PATH), 5)
	assert_true(_registry_test_registry.get_spec("terrain_create") == null)
	assert_false(dispatcher.has_command("custom_tool:terrain_regenerate"))
	assert_false(dispatcher.has_command("custom_tool:terrain_sculpt"))
	assert_false(dispatcher.has_command("custom_tool:terrain_holes"))
	assert_false(dispatcher.has_command("custom_tool:terrain_erode"))


## ----- persistent authoring data, palettes, and editor operations -----

func _has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false


func _first_property(object: Object, names: Array, default_value: Variant = null) -> Variant:
	for property_name in names:
		if _has_property(object, String(property_name)):
			return object.get(String(property_name))
	return default_value


func _set_first_property(object: Object, names: Array, value: Variant) -> bool:
	for property_name in names:
		var name := String(property_name)
		if _has_property(object, name):
			object.set(name, value)
			return true
	return false


func _data_heights(data: Object) -> PackedFloat32Array:
	if data.has_method("final_heights"):
		var final_values: Variant = data.call("final_heights")
		if final_values is PackedFloat32Array:
			return final_values
	var value: Variant = _first_property(data, ["heights", "final_heights", "base_heights", "height_data", "height_map"], PackedFloat32Array())
	return value if value is PackedFloat32Array else PackedFloat32Array()


func _data_holes(data: Object) -> PackedByteArray:
	var value: Variant = _first_property(data, ["holes", "hole_mask", "holes_mask"], PackedByteArray())
	return value if value is PackedByteArray else PackedByteArray()


func _set_hole(data: Object, x: int, z: int, value: bool) -> bool:
	for method_name in ["set_hole", "set_hole_at", "set_hole_mask"]:
		if data.has_method(method_name):
			data.call(method_name, x, z, value)
			return true
	var holes := _data_holes(data)
	var params_value: Variant = data.get("params")
	var size := int(params_value.get("size", 0)) if params_value is Dictionary else 0
	if size > 0 and holes.size() == size * size:
		holes[z * size + x] = 1 if value else 0
		return _set_first_property(data, ["holes", "hole_mask", "holes_mask"], holes)
	return false


func _build_data(data: Object) -> Dictionary:
	var job := TerrainBuildJob.new(data)
	while not job.step(1000000):
		pass
	return job.result()


func _mesh_colors(built: Dictionary) -> PackedColorArray:
	var mesh := built.get("mesh") as Mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return PackedColorArray()
	var arrays: Array = mesh.surface_get_arrays(0)
	return arrays[Mesh.ARRAY_COLOR] if arrays.size() > Mesh.ARRAY_COLOR and arrays[Mesh.ARRAY_COLOR] is PackedColorArray else PackedColorArray()


func _schema_property(spec: McpCustomToolSpec, property_name: String) -> Dictionary:
	var properties: Dictionary = spec.params_schema.get("properties", {})
	var value: Variant = properties.get(property_name, {})
	return value if value is Dictionary else {}


func test_terrain_data_persists_heights_holes_and_authoring_state() -> void:
	var params: Dictionary = _normalized({"size": 8, "seed": 71}).params
	var data := _new_data(params)
	_build_data(data)
	assert_true(data.is_valid())
	assert_eq(int(data.params.get("size", 0)), 8)
	assert_eq(data.size, 8)
	assert_eq(data.material_preset, "natural")
	var heights := _data_heights(data)
	assert_eq(heights.size(), 64)
	var holes := _data_holes(data)
	assert_eq(holes.size(), 64)
	assert_true(_set_hole(data, 3, 4, true), "TerrainData must expose a persistent hole mask")
	heights[3 + 4 * 8] += 2.5
	assert_true(_set_first_property(data, ["base_heights", "heights", "height_data", "height_map"], heights))
	var copy: TerrainData = data.duplicate(true) as TerrainData
	assert_eq(copy.params, data.params)
	assert_eq(copy.size, data.size)
	assert_eq(copy.material_preset, data.material_preset)
	assert_eq(_data_heights(copy), _data_heights(data))
	assert_eq(_data_holes(copy), _data_holes(data))
	for property_name in ["material_preset", "palette", "palette_name"]:
		if _has_property(data, property_name):
			assert_eq(copy.get(property_name), data.get(property_name))


func test_terrain_data_survives_packed_scene_save_and_load() -> void:
	var scene_root := Node3D.new()
	scene_root.name = "TerrainDataPersistenceRoot"
	var container := Node3D.new()
	container.name = "Terrain"
	scene_root.add_child(container)
	container.owner = scene_root
	var data := _new_data(_normalized({
		"size": 6, "seed": 97, "material_preset": "volcanic",
	}).params)
	_build_data(data)
	data.edit_offsets[7] = 1.75
	data.holes[14] = 1
	container.set_meta(META_KEY, _handler._metadata(data))
	var packed := PackedScene.new()
	assert_eq(packed.pack(scene_root), OK)
	var path := "user://terrain_tools_data_persistence_test.tscn"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	assert_eq(ResourceSaver.save(packed, path), OK)
	var loaded := ResourceLoader.load(path) as PackedScene
	assert_true(loaded != null)
	var loaded_root := loaded.instantiate()
	track(loaded_root)
	var loaded_container := loaded_root.get_node("Terrain")
	var loaded_metadata: Variant = loaded_container.get_meta(META_KEY)
	assert_true(loaded_metadata is Dictionary)
	var loaded_metadata_dict: Dictionary = loaded_metadata as Dictionary
	var loaded_data: Variant = loaded_metadata_dict.get("data")
	assert_true(loaded_data is TerrainData)
	assert_true((loaded_data as TerrainData).is_valid())
	assert_eq((loaded_data as TerrainData).params, data.params)
	assert_eq((loaded_data as TerrainData).base_heights, data.base_heights)
	assert_eq((loaded_data as TerrainData).edit_offsets, data.edit_offsets)
	assert_eq((loaded_data as TerrainData).holes, data.holes)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	scene_root.free()


func test_regeneration_preserves_or_resets_modifications_explicitly() -> void:
	var original := _new_data(_normalized({"size": 8, "seed": 71}).params)
	_build_data(original)
	original.edit_offsets[12] = 2.5
	original.holes[18] = 1
	var changed_params: Dictionary = original.params.duplicate(true)
	changed_params.material_preset = "snow"
	var preserved := _handler._regenerated_data(changed_params, original, false) as TerrainData
	assert_eq(preserved.edit_offsets, original.edit_offsets)
	assert_eq(preserved.holes, original.holes)
	assert_false(preserved.base_ready)
	var reset := _handler._regenerated_data(changed_params, original, true) as TerrainData
	assert_false(reset.has_modifications())
	assert_false(reset.base_ready)


func test_builder_consumes_terrain_data_and_reports_mesh_counts() -> void:
	var data := _new_data(_normalized({"size": 7, "seed": 9}).params)
	var built := _build_data(data)
	assert_has_key(built, "mesh")
	assert_eq(built.vertices, 49)
	assert_eq(built.triangle_count, 72)
	assert_eq((built.triangles as PackedVector3Array).size(), 216)
	assert_eq(_mesh_colors(built).size(), 49)


func test_material_palette_presets_are_published_and_change_finite_vertex_colors() -> void:
	var plugin := track(TerrainPlugin.new())
	var spec: McpCustomToolSpec = plugin._create_spec()
	var material_property := _schema_property(spec, "material_preset")
	assert_has_key(spec.params_schema.properties, "material_preset")
	assert_has_key(material_property, "enum")
	var presets: Array = material_property.enum
	assert_gt(presets.size(), 1, "the authoring upgrade must publish multiple material palettes")
	var first_colors := PackedColorArray()
	for index in presets.size():
		var built := _build({"size": 8, "seed": 23, "material_preset": presets[index]})
		var colors := _mesh_colors(built)
		assert_eq(colors.size(), 64)
		for color in colors:
			_assert_finite_color(color)
		if index == 0:
			first_colors = colors
		else:
			assert_ne(colors, first_colors, "palette presets must affect vertex colors")


func test_sculpt_validation_rejects_bad_paths_brushes_and_modes_without_mutation() -> void:
	var invalid_requests := [
		{}, {"path": 42}, {"path": ""}, {"path": "/does_not_exist"},
		{"path": "/TerrainDemo", "radius": 0.0},
		{"path": "/TerrainDemo", "radius": -1.0},
		{"path": "/TerrainDemo", "strength": NAN},
		{"path": "/TerrainDemo", "strength": INF},
		{"path": "/TerrainDemo", "mode": "paint"},
		{"path": "/TerrainDemo", "center": {"x": "bad", "z": 2.0}},
	]
	for request in invalid_requests:
		assert_is_error(_handler.sculpt(request, null))
	for mode in ["raise", "lower", "smooth", "noise"]:
		var stroke := {"center_x": 0.0, "center_z": 0.0, "radius": 2.0, "mode": mode, "strength": 0.5}
		if mode == "noise":
			stroke.seed = 99
		var normalized := _handler._normalized_strokes([stroke])
		assert_has_key(normalized, "items")
		assert_eq(normalized.items[0].mode, mode)
	var flatten := _handler._normalized_strokes([{
		"center_x": 0.0, "center_z": 0.0, "radius": 2.0,
		"mode": "flatten", "strength": 0.5, "target_height": 1.25,
	}])
	assert_has_key(flatten, "items")
	assert_eq(flatten.items[0].target_height, 1.25)
	var plugin := track(TerrainPlugin.new())
	var spec: McpCustomToolSpec = plugin._sculpt_spec()
	var strokes_property := _schema_property(spec, "strokes")
	var strokes_item: Dictionary = strokes_property.get("items", {})
	var stroke_properties: Dictionary = strokes_item.get("properties", {})
	var mode_property: Dictionary = stroke_properties.get("mode", {})
	assert_has_key(mode_property, "enum")
	assert_gt((mode_property.enum as Array).size(), 1,
		"sculpt must expose more than one authoring mode")


func test_holes_mask_grid_topology_and_preserve_unmasked_triangles() -> void:
	for request in [
		{}, {"path": 42}, {"path": "/TerrainDemo", "areas": []},
		{"path": "/TerrainDemo", "areas": [{"center_x": 0.0, "center_z": 0.0, "radius": 0.0, "mode": "cut"}]},
		{"path": "/TerrainDemo", "areas": [{"center_x": 0.0, "center_z": 0.0, "radius": 2.0, "mode": "remove"}]},
	]:
		assert_is_error(_handler.holes(request, null))
	var data := _new_data(_normalized({"size": 8, "seed": 5}).params)
	var full := _build_data(data)
	assert_true(_set_hole(data, 3, 3, true))
	assert_true(_set_hole(data, 4, 3, true))
	var masked := _build_data(data)
	assert_true(masked.triangle_count < full.triangle_count)
	assert_gt(masked.triangle_count, 0)
	var triangles: PackedVector3Array = masked.triangles
	for vertex in triangles:
		assert_true(is_finite(vertex.x) and is_finite(vertex.y) and is_finite(vertex.z))


func test_collision_uses_heightmap_shape_and_nan_samples_for_holes() -> void:
	var data := _new_data(_normalized({"size": 8, "seed": 6}).params)
	assert_true(_set_hole(data, 3, 3, true))
	var built := _build_data(data)
	var children: Array = _handler._make_children(built, true)
	assert_eq(children.size(), 2)
	var body := children[1] as StaticBody3D
	var collision_shape := body.get_child(0) as CollisionShape3D
	assert_true(collision_shape.shape is HeightMapShape3D)
	var shape := collision_shape.shape as HeightMapShape3D
	assert_eq(shape.map_width, 8)
	assert_eq(shape.map_depth, 8)
	assert_eq(collision_shape.scale, Vector3(2.0, 1.0, 2.0))
	var map_data: PackedFloat32Array = shape.map_data
	assert_eq(map_data.size(), 64)
	var vertices: PackedVector3Array = _mesh_arrays(built)[Mesh.ARRAY_VERTEX]
	var nan_count := 0
	for index in map_data.size():
		var sample: float = map_data[index]
		if is_nan(sample):
			nan_count += 1
		else:
			assert_true(is_equal_approx(sample, vertices[index].y),
				"heightfield collision samples must match visible vertex heights")
	assert_true(nan_count > 0, "hole samples must be masked with NAN in collision data")


func test_thermal_and_hydraulic_erosion_are_deterministic() -> void:
	for request in [
		{}, {"path": 42}, {"path": "/TerrainDemo", "algorithm": "wind"},
		{"path": "/TerrainDemo", "algorithm": "thermal", "iterations": 0},
		{"path": "/TerrainDemo", "algorithm": "hydraulic", "intensity": 1.5},
	]:
		assert_is_error(_handler.erode(request, null))
	var params: Dictionary = _normalized({"size": 12, "seed": 17}).params
	for mode in ["thermal", "hydraulic"]:
		var first := _new_data(params)
		var second := _new_data(params)
		var baseline := _new_data(params)
		_build_data(first)
		_build_data(second)
		_build_data(baseline)
		var hole_height := _data_heights(first)[0]
		first.holes[0] = 1
		second.holes[0] = 1
		var first_job := TerrainErosionJob.new(first, mode, 8, 0.35, 101)
		var second_job := TerrainErosionJob.new(second, mode, 8, 0.35, 101)
		while not first_job.step(1000000):
			pass
		while not second_job.step(1000000):
			pass
		assert_eq(_data_heights(first), _data_heights(second),
			"%s erosion must be deterministic for the same seed" % mode)
		assert_ne(_data_heights(first), _data_heights(baseline),
			"%s erosion must change heights" % mode)
		var final_heights := _data_heights(first)
		assert_true(is_equal_approx(final_heights[0], hole_height),
			"%s erosion must not modify masked vertices" % mode)
		for height in final_heights:
			assert_true(is_finite(height))
			assert_true(absf(height) <= 1000000000.0)


func test_v1_metadata_is_accepted_and_normalized_for_edit_migration() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No edited scene")
		return
	var container := Node3D.new()
	track(container)
	var legacy_params: Dictionary = _normalized({"size": 5, "seed": 51}).params
	legacy_params.erase("material_preset")
	container.set_meta(META_KEY, {"format_version": 1, "params": legacy_params})
	var migrated := _handler._managed_metadata(container)
	assert_has_key(migrated, "metadata")
	assert_eq(migrated.metadata.format_version, 1)
	assert_eq(migrated.state.format_version, 1)
	assert_eq(migrated.state.data, null)
	assert_eq(migrated.state.params.size, legacy_params.size)
	assert_true(migrated.state.params.has("material_preset"))
