@tool
extends RefCounted

const TerrainBuildJob := preload("res://addons/godot_ai_terrain_tools/terrain_build_job.gd")

const MIN_SIZE := 4
const MAX_SIZE := 128
const FRAME_BUDGET_USEC := 3000
const FORMAT_VERSION := 1
const MESH_CHILD := "TerrainMesh"
const COLLISION_CHILD := "TerrainCollision"
const META_KEY := &"godot_ai_terrain_tools"
const PARAM_KEYS := [
	"size", "cell_size", "seed", "noise_type", "frequency", "octaves",
	"height_scale", "base_height", "generate_collision",
]
## Keep these literal for Godot 4.5, which does not accept Array addition in a
## constant expression.
const CREATE_KEYS := [
	"size", "cell_size", "seed", "noise_type", "frequency", "octaves",
	"height_scale", "base_height", "generate_collision",
	"parent_path", "scene_file", "name", "session_id",
]
const REGENERATE_KEYS := [
	"size", "cell_size", "seed", "noise_type", "frequency", "octaves",
	"height_scale", "base_height", "generate_collision",
	"path", "scene_file", "session_id",
]
const NOISE_TYPES := ["simplex", "simplex_smooth", "perlin", "ridged", "value"]

var _busy := false


func create(params: Dictionary, ctx) -> Dictionary:
	if _busy:
		return _error(
			"terrain_tools.BUSY",
			"Terrain generation is already running; retry after it finishes",
			{"retryable": true},
		)
	var request_error := _validate_request(params, CREATE_KEYS, ["parent_path", "scene_file", "name"])
	if not request_error.is_empty():
		return request_error
	var checked := _normalized_params(params)
	if checked.has("error"):
		return checked
	var scene := _edited_scene(params.get("scene_file", ""))
	if scene.has("error"):
		return scene
	var root: Node = scene.node
	var parent_result := _resolve_scene_node(String(params.get("parent_path", "")), root)
	if parent_result.has("error"):
		return parent_result
	var parent: Node = parent_result.node
	if not parent is Node3D:
		return _error("WRONG_TYPE", "Terrain parent must be a Node3D (got %s)" % parent.get_class())
	var terrain_name := String(params.get("name", "Terrain"))
	if terrain_name.is_empty() or terrain_name.contains("/"):
		return _error("INVALID_PARAMS", "name must be non-empty and cannot contain '/'")
	_busy = true
	_finish_create(checked.params, terrain_name, parent, root, ctx)
	return {"_deferred": true}


func regenerate(params: Dictionary, ctx) -> Dictionary:
	if _busy:
		return _error(
			"terrain_tools.BUSY",
			"Terrain generation is already running; retry after it finishes",
			{"retryable": true},
		)
	var request_error := _validate_request(params, REGENERATE_KEYS, ["path", "scene_file"])
	if not request_error.is_empty():
		return request_error
	if not params.has("path") or String(params.path).is_empty():
		return _error("INVALID_PARAMS", "path is required and must be non-empty")
	var scene := _edited_scene(params.get("scene_file", ""))
	if scene.has("error"):
		return scene
	var root: Node = scene.node
	var resolved := _resolve_scene_node(String(params.get("path", "")), root)
	if resolved.has("error"):
		return resolved
	var container: Node = resolved.node
	if not container is Node3D:
		return _error("WRONG_TYPE", "Terrain path must resolve to a Node3D")
	var metadata := _managed_metadata(container)
	if metadata.has("error"):
		return metadata
	var merged: Dictionary = metadata.metadata.params.duplicate(true)
	for key in PARAM_KEYS:
		if params.has(key):
			merged[key] = params[key]
	var checked := _normalized_params(merged)
	if checked.has("error"):
		return checked
	var structure := _capture_managed_nodes(container)
	if structure.has("error"):
		return structure
	_busy = true
	_finish_regenerate(checked.params, container, root, structure, ctx)
	return {"_deferred": true}


func _finish_create(p: Dictionary, terrain_name: String, parent: Node, root: Node, ctx) -> void:
	await _next_frame()
	var built := await _build_incrementally(p, ctx)
	if built.has("error"):
		_busy = false
		ctx.send_deferred(built)
		return
	if not _scene_still_valid(root) or not is_instance_valid(parent) or not root.is_ancestor_of(parent) and parent != root:
		_busy = false
		ctx.send_deferred(_error("EDITED_SCENE_MISMATCH", "The edited scene changed while terrain was being generated"))
		return
	var container := Node3D.new()
	container.name = terrain_name
	var children := _make_children(built, bool(p.generate_collision))
	for child in children:
		container.add_child(child)
	container.set_meta(META_KEY, _metadata(p))
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Terrain Tools: Create %s" % terrain_name)
	undo_redo.add_do_method(parent, "add_child", container, true)
	undo_redo.add_do_method(self, "_assign_owners", container, root)
	undo_redo.add_do_reference(container)
	undo_redo.add_undo_method(parent, "remove_child", container)
	undo_redo.commit_action()
	_busy = false
	ctx.send_deferred({"data": _response(container, root, p, built)})


func _finish_regenerate(
	p: Dictionary,
	container: Node3D,
	root: Node,
	previous: Dictionary,
	ctx,
) -> void:
	await _next_frame()
	var built := await _build_incrementally(p, ctx)
	if built.has("error"):
		_busy = false
		ctx.send_deferred(built)
		return
	if not _scene_still_valid(root) or not is_instance_valid(container) or not root.is_ancestor_of(container):
		_busy = false
		ctx.send_deferred(_error("EDITED_SCENE_MISMATCH", "The edited scene changed while terrain was being generated"))
		return
	var new_nodes := _make_children(built, bool(p.generate_collision))
	var new_meta := _metadata(p)
	var old_meta: Dictionary = container.get_meta(META_KEY).duplicate(true)
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Terrain Tools: Regenerate %s" % container.name)
	undo_redo.add_do_method(container, "set_meta", META_KEY, new_meta)
	undo_redo.add_do_method(self, "_replace_managed_nodes", container, previous.nodes, new_nodes, root)
	for node in new_nodes:
		undo_redo.add_do_reference(node)
	undo_redo.add_undo_method(self, "_replace_managed_nodes", container, new_nodes, previous.nodes, root)
	undo_redo.add_undo_method(container, "set_meta", META_KEY, old_meta)
	for node in previous.nodes:
		undo_redo.add_undo_reference(node)
	undo_redo.commit_action()
	_busy = false
	ctx.send_deferred({"data": _response(container, root, p, built)})


func _build_incrementally(p: Dictionary, ctx) -> Dictionary:
	var job := TerrainBuildJob.new(p)
	while not job.step(FRAME_BUDGET_USEC):
		if ctx.is_expired():
			return _error("terrain_tools.TIMEOUT", "Terrain generation exceeded its deadline")
		await _next_frame()
	return job.result()


func _normalized_params(params: Dictionary) -> Dictionary:
	var size_value = params.get("size", 48)
	if not _is_integer_value(size_value):
		return _error("INVALID_PARAMS", "size must be an integer")
	var size := int(size_value)
	if size < MIN_SIZE or size > MAX_SIZE:
		return _error("VALUE_OUT_OF_RANGE", "size must be in %d..%d" % [MIN_SIZE, MAX_SIZE])
	var cell := _finite_float(params.get("cell_size", 2.0), "cell_size")
	if cell.has("error"):
		return cell
	if cell.value <= 0.0:
		return _error("VALUE_OUT_OF_RANGE", "cell_size must be greater than zero")
	var frequency := _finite_float(params.get("frequency", 0.05), "frequency")
	if frequency.has("error"):
		return frequency
	if frequency.value <= 0.0:
		return _error("VALUE_OUT_OF_RANGE", "frequency must be greater than zero")
	var height_scale := _finite_float(params.get("height_scale", 8.0), "height_scale")
	if height_scale.has("error"):
		return height_scale
	if height_scale.value <= 0.0:
		return _error("VALUE_OUT_OF_RANGE", "height_scale must be greater than zero")
	var base_height := _finite_float(params.get("base_height", 0.0), "base_height")
	if base_height.has("error"):
		return base_height
	var octaves_value = params.get("octaves", 3)
	if not _is_integer_value(octaves_value):
		return _error("INVALID_PARAMS", "octaves must be an integer")
	var octaves := int(octaves_value)
	if octaves < 1 or octaves > 6:
		return _error("VALUE_OUT_OF_RANGE", "octaves must be in 1..6")
	var noise_value = params.get("noise_type", "simplex")
	if not noise_value is String:
		return _error("INVALID_PARAMS", "noise_type must be a string")
	var noise_type := String(noise_value)
	if not NOISE_TYPES.has(noise_type):
		return _error("VALUE_OUT_OF_RANGE", "noise_type must be one of: %s" % ", ".join(NOISE_TYPES))
	var seed_value = params.get("seed", 1337)
	if not _is_integer_value(seed_value):
		return _error("INVALID_PARAMS", "seed must be an integer")
	var collision_value = params.get("generate_collision", true)
	if not collision_value is bool:
		return _error("INVALID_PARAMS", "generate_collision must be a boolean")
	return {"params": {
		"size": size,
		"cell_size": cell.value,
		"seed": int(seed_value),
		"noise_type": noise_type,
		"frequency": frequency.value,
		"octaves": octaves,
		"height_scale": height_scale.value,
		"base_height": base_height.value,
		"generate_collision": collision_value,
	}}


func _edited_scene(expected_file: Variant) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _error("EDITOR_NOT_READY", "No edited scene is open")
	var expected := String(expected_file)
	if not expected.is_empty() and root.scene_file_path != expected:
		return _error("EDITED_SCENE_MISMATCH", "Expected edited scene '%s', got '%s'" % [expected, root.scene_file_path])
	return {"node": root}


func _resolve_scene_node(path: String, root: Node) -> Dictionary:
	if path.is_empty() or path == "/" or path == "/" + String(root.name):
		return {"node": root}
	if not path.begins_with("/"):
		return _error("INVALID_PARAMS", "Scene paths must start with '/'")
	var parts := path.trim_prefix("/").split("/", false)
	if parts.is_empty() or parts[0] != String(root.name):
		return _error("NODE_NOT_FOUND", "Path '%s' is outside the edited scene root '/%s'" % [path, root.name])
	var relative := "/".join(parts.slice(1))
	var node := root.get_node_or_null(NodePath(relative))
	if node == null:
		return _error("NODE_NOT_FOUND", "Node not found: %s" % path)
	return {"node": node}


func _managed_metadata(container: Node) -> Dictionary:
	if not container.has_meta(META_KEY):
		return _error("terrain_tools.NOT_MANAGED", "The target was not created by Godot AI Terrain Tools")
	var metadata = container.get_meta(META_KEY)
	if not metadata is Dictionary or int(metadata.get("format_version", 0)) != FORMAT_VERSION:
		return _error("terrain_tools.UNSUPPORTED_FORMAT", "Terrain metadata is missing or unsupported")
	if not metadata.get("params") is Dictionary:
		return _error("terrain_tools.UNSUPPORTED_FORMAT", "Terrain metadata has no parameter snapshot")
	return {"metadata": metadata}


func _capture_managed_nodes(container: Node) -> Dictionary:
	var meshes := _find_direct_children(container, MESH_CHILD)
	if meshes.size() != 1:
		return _error("terrain_tools.INVALID_STRUCTURE", "Managed terrain must have exactly one TerrainMesh")
	var mesh_node: Node = meshes[0]
	if not mesh_node is MeshInstance3D or mesh_node.mesh == null:
		return _error("terrain_tools.INVALID_STRUCTURE", "Managed terrain has no valid TerrainMesh")
	var nodes: Array[Node] = [mesh_node]
	var collisions := _find_direct_children(container, COLLISION_CHILD)
	if collisions.size() > 1:
		return _error("terrain_tools.INVALID_STRUCTURE", "Managed terrain has duplicate TerrainCollision children")
	if collisions.size() == 1:
		var collision: Node = collisions[0]
		if not collision is StaticBody3D or collision.get_child_count() != 1 or not collision.get_child(0) is CollisionShape3D:
			return _error("terrain_tools.INVALID_STRUCTURE", "Managed TerrainCollision has an unexpected structure")
		var collision_shape := collision.get_child(0) as CollisionShape3D
		if not collision_shape.shape is ConcavePolygonShape3D:
			return _error("terrain_tools.INVALID_STRUCTURE", "Managed TerrainCollision has no valid concave shape")
		nodes.append(collision)
	return {"nodes": nodes}


func _make_children(built: Dictionary, with_collision: bool) -> Array[Node]:
	var nodes: Array[Node] = []
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = MESH_CHILD
	mesh_instance.mesh = built.mesh
	nodes.append(mesh_instance)
	if with_collision:
		var body := StaticBody3D.new()
		body.name = COLLISION_CHILD
		var collision_shape := CollisionShape3D.new()
		collision_shape.name = "CollisionShape3D"
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(built.triangles)
		collision_shape.shape = shape
		body.add_child(collision_shape)
		nodes.append(body)
	return nodes


func _replace_managed_nodes(container: Node3D, removal: Array, replacement: Array, root: Node) -> void:
	for node in removal:
		if is_instance_valid(node) and node.get_parent() == container:
			container.remove_child(node)
	for node in replacement:
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		container.add_child(node)
		_assign_owners(node, root)


func _assign_owners(node: Node, root: Node) -> void:
	node.owner = root
	for child in node.get_children():
		_assign_owners(child, root)


func _response(container: Node, root: Node, p: Dictionary, built: Dictionary) -> Dictionary:
	return {
		"path": _path_from_node(container, root),
		"name": container.name,
		"params": p.duplicate(true),
		"vertices": built.vertices,
		"triangles": built.triangle_count,
		"generate_collision": bool(p.generate_collision),
		"undoable": true,
	}


func _metadata(p: Dictionary) -> Dictionary:
	return {"format_version": FORMAT_VERSION, "params": p.duplicate(true)}


func _scene_still_valid(root: Node) -> bool:
	return is_instance_valid(root) and EditorInterface.get_edited_scene_root() == root


func _path_from_node(node: Node, root: Node) -> String:
	if node == root:
		return "/" + String(root.name)
	return "/%s/%s" % [root.name, root.get_path_to(node)]


func _find_direct_children(parent: Node, child_name: String) -> Array[Node]:
	var matches: Array[Node] = []
	for child in parent.get_children():
		if child.name == child_name:
			matches.append(child)
	return matches


func _validate_request(params: Dictionary, allowed: Array, string_fields: Array) -> Dictionary:
	for key in params:
		if not allowed.has(String(key)):
			return _error("INVALID_PARAMS", "Unknown parameter: %s" % key)
	for field in string_fields:
		if params.has(field) and not params[field] is String:
			return _error("INVALID_PARAMS", "%s must be a string" % field)
	return {}


func _finite_float(value: Variant, field: String) -> Dictionary:
	if not value is int and not value is float:
		return _error("INVALID_PARAMS", "%s must be numeric" % field)
	var converted := float(value)
	if not is_finite(converted):
		return _error("INVALID_PARAMS", "%s must be finite" % field)
	return {"value": converted}


func _is_integer_value(value: Variant) -> bool:
	return value is int or value is float and is_finite(value) and float(value) == floorf(value)


static func _error(code: String, message: String, data: Dictionary = {}) -> Dictionary:
	## Godot AI's transport classifies plugin failures by the top-level status;
	## without it a custom failure is serialized as an empty successful result.
	var error := {"code": code, "message": message}
	if not data.is_empty():
		error.data = data
	return {"status": "error", "error": error}


static func _next_frame() -> Signal:
	return (Engine.get_main_loop() as SceneTree).process_frame
