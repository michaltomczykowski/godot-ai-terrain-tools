@tool
extends RefCounted

const TerrainData := preload("res://addons/godot_ai_terrain_tools/terrain_data.gd")
const TerrainBuildJob := preload("res://addons/godot_ai_terrain_tools/terrain_build_job.gd")
const TerrainErosionJob := preload("res://addons/godot_ai_terrain_tools/terrain_erosion_job.gd")

const MIN_SIZE := 4
const MAX_SIZE := 128
const FRAME_BUDGET_USEC := 3000
const BUSY_RECOVERY_MSEC := 35000
const MAX_NUMBER_MAGNITUDE := 1000000.0
const MAX_HEIGHT_MAGNITUDE := 1000000000.0
const FORMAT_VERSION := 2
const LEGACY_FORMAT_VERSION := 1
const MESH_CHILD := "TerrainMesh"
const COLLISION_CHILD := "TerrainCollision"
const META_KEY := &"godot_ai_terrain_tools"
const MATERIAL_PRESETS := ["natural", "desert", "snow", "volcanic", "alien"]
const PARAM_KEYS := [
	"size", "cell_size", "seed", "noise_type", "frequency", "octaves",
	"height_scale", "base_height", "generate_collision", "material_preset",
]
## Literal arrays retain Godot 4.5 constant-expression compatibility.
const CREATE_KEYS := [
	"size", "cell_size", "seed", "noise_type", "frequency", "octaves",
	"height_scale", "base_height", "generate_collision", "material_preset",
	"parent_path", "scene_file", "name", "session_id",
]
const REGENERATE_KEYS := [
	"size", "cell_size", "seed", "noise_type", "frequency", "octaves",
	"height_scale", "base_height", "generate_collision", "material_preset",
	"reset_modifications", "path", "scene_file", "session_id",
]
const EDIT_KEYS := ["path", "scene_file", "session_id", "strokes"]
const HOLE_KEYS := ["path", "scene_file", "session_id", "areas"]
const EROSION_KEYS := ["path", "scene_file", "session_id", "algorithm", "iterations", "intensity", "seed"]
const NOISE_TYPES := ["simplex", "simplex_smooth", "perlin", "ridged", "value"]
const STROKE_MODES := ["raise", "lower", "smooth", "flatten", "noise"]
const FALLOFFS := ["smooth", "linear"]

static var _shared_busy := false
static var _busy_started_msec := 0
var _busy: bool:
	get:
		return _shared_busy
	set(value):
		_shared_busy = value
		_busy_started_msec = Time.get_ticks_msec() if value else 0


static func reset_busy() -> void:
	_shared_busy = false
	_busy_started_msec = 0


func create(params: Dictionary, ctx) -> Dictionary:
	var busy := _busy_error()
	if not busy.is_empty():
		return busy
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
	_claim_busy()
	_finish_create(checked.params, terrain_name, parent, root, root.get_path_to(parent), ctx)
	return {"_deferred": true}


func regenerate(params: Dictionary, ctx) -> Dictionary:
	var busy := _busy_error()
	if not busy.is_empty():
		return busy
	var request_error := _validate_request(params, REGENERATE_KEYS, ["path", "scene_file"])
	if not request_error.is_empty():
		return request_error
	if params.has("reset_modifications") and not params.reset_modifications is bool:
		return _error("INVALID_PARAMS", "reset_modifications must be a boolean")
	var target := _managed_target(params)
	if target.has("error"):
		return target
	var merged: Dictionary = target.state.params.duplicate(true)
	for key in PARAM_KEYS:
		if params.has(key):
			merged[key] = params[key]
	var checked := _normalized_params(merged)
	if checked.has("error"):
		return checked
	var reset := bool(params.get("reset_modifications", false))
	var old_data: Resource = target.state.get("data")
	if (
		old_data != null
		and int(checked.params.size) != int(old_data.params.size)
		and old_data.has_modifications()
		and not reset
	):
		return _error("terrain_tools.MODIFICATIONS_EXIST", "Changing size requires reset_modifications=true while sculpting, erosion, or holes exist")
	_claim_busy()
	_finish_regenerate(checked.params, reset, target, ctx)
	return {"_deferred": true}


func sculpt(params: Dictionary, ctx) -> Dictionary:
	var busy := _busy_error()
	if not busy.is_empty():
		return busy
	var request_error := _validate_request(params, EDIT_KEYS, ["path", "scene_file"])
	if not request_error.is_empty():
		return request_error
	var strokes := _normalized_strokes(params.get("strokes"))
	if strokes.has("error"):
		return strokes
	var target := _managed_target(params)
	if target.has("error"):
		return target
	_claim_busy()
	_finish_sculpt(strokes.items, target, ctx)
	return {"_deferred": true}


func holes(params: Dictionary, ctx) -> Dictionary:
	var busy := _busy_error()
	if not busy.is_empty():
		return busy
	var request_error := _validate_request(params, HOLE_KEYS, ["path", "scene_file"])
	if not request_error.is_empty():
		return request_error
	var areas := _normalized_areas(params.get("areas"))
	if areas.has("error"):
		return areas
	var target := _managed_target(params)
	if target.has("error"):
		return target
	_claim_busy()
	_finish_holes(areas.items, target, ctx)
	return {"_deferred": true}


func erode(params: Dictionary, ctx) -> Dictionary:
	var busy := _busy_error()
	if not busy.is_empty():
		return busy
	var request_error := _validate_request(params, EROSION_KEYS, ["path", "scene_file", "algorithm"])
	if not request_error.is_empty():
		return request_error
	var erosion := _normalized_erosion(params)
	if erosion.has("error"):
		return erosion
	var target := _managed_target(params)
	if target.has("error"):
		return target
	_claim_busy()
	_finish_erode(erosion.settings, target, ctx)
	return {"_deferred": true}


func _finish_create(p: Dictionary, terrain_name: String, parent: Node, root: Node, expected_parent_path: NodePath, ctx) -> void:
	await _next_frame()
	var built := await _build_incrementally(p, ctx)
	if _finish_error(built, ctx):
		return
	if (
		not _scene_still_valid(root)
		or not is_instance_valid(parent)
		or not root.is_ancestor_of(parent) and parent != root
		or root.get_path_to(parent) != expected_parent_path
	):
		_send_error(ctx, _error("EDITED_SCENE_MISMATCH", "The edited scene changed while terrain was being generated"))
		return
	var container := Node3D.new()
	container.name = terrain_name
	var children := _make_children(built, bool(p.generate_collision))
	for child in children:
		container.add_child(child)
	container.set_meta(META_KEY, _metadata(built.data))
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Terrain Tools: Create %s" % terrain_name)
	undo_redo.add_do_method(parent, "add_child", container, true)
	undo_redo.add_do_method(self, "_assign_owners", container, root)
	undo_redo.add_do_reference(container)
	undo_redo.add_undo_method(parent, "remove_child", container)
	undo_redo.commit_action()
	_release_busy()
	ctx.send_deferred({"data": _response(container, root, built.data, built, "create")})


func _finish_regenerate(p: Dictionary, reset: bool, target: Dictionary, ctx) -> void:
	await _next_frame()
	var old_data: Resource = target.state.get("data")
	var data: Resource = _regenerated_data(p, old_data, reset)
	var built := await _build_incrementally(data, ctx)
	if _finish_error(built, ctx):
		return
	if not _target_still_valid(target):
		_send_error(ctx, _error("EDITED_SCENE_MISMATCH", "The edited scene changed while terrain was being generated"))
		return
	_commit_replacement("Regenerate", target, built)
	_release_busy()
	ctx.send_deferred({"data": _response(target.container, target.root, built.data, built, "regenerate")})


func _regenerated_data(p: Dictionary, old_data: Resource, reset: bool) -> Resource:
	var data := TerrainData.new()
	data.initialize(p)
	if old_data != null and not reset and int(old_data.params.size) == int(p.size):
		data.edit_offsets = old_data.edit_offsets.duplicate()
		data.holes = old_data.holes.duplicate()
	return data


func _finish_sculpt(strokes: Array, target: Dictionary, ctx) -> void:
	await _next_frame()
	var prepared := await _materialize_data(target.state, ctx)
	if _finish_error(prepared, ctx):
		return
	var data: Resource = prepared.data.snapshot()
	var applied := await _apply_strokes(data, strokes, ctx)
	if _finish_error(applied, ctx):
		return
	var built := await _build_incrementally(data, ctx)
	if _finish_error(built, ctx):
		return
	if not _target_still_valid(target):
		_send_error(ctx, _error("EDITED_SCENE_MISMATCH", "The edited scene changed while terrain was being sculpted"))
		return
	_commit_replacement("Sculpt", target, built)
	_release_busy()
	ctx.send_deferred({"data": _response(target.container, target.root, data, built, "sculpt", {"affected_vertices": applied.affected_vertices})})


func _finish_holes(areas: Array, target: Dictionary, ctx) -> void:
	await _next_frame()
	var prepared := await _materialize_data(target.state, ctx)
	if _finish_error(prepared, ctx):
		return
	var data: Resource = prepared.data.snapshot()
	var applied := await _apply_holes(data, areas, ctx)
	if _finish_error(applied, ctx):
		return
	var built := await _build_incrementally(data, ctx)
	if _finish_error(built, ctx):
		return
	if not _target_still_valid(target):
		_send_error(ctx, _error("EDITED_SCENE_MISMATCH", "The edited scene changed while terrain holes were being generated"))
		return
	_commit_replacement("Holes", target, built)
	_release_busy()
	ctx.send_deferred({"data": _response(target.container, target.root, data, built, "holes", {"affected_vertices": applied.affected_vertices, "hole_vertices": _count_holes(data)})})


func _finish_erode(settings: Dictionary, target: Dictionary, ctx) -> void:
	await _next_frame()
	var prepared := await _materialize_data(target.state, ctx)
	if _finish_error(prepared, ctx):
		return
	var data: Resource = prepared.data.snapshot()
	var job := TerrainErosionJob.new(data, settings.algorithm, settings.iterations, settings.intensity, settings.seed)
	while not job.step(FRAME_BUDGET_USEC):
		if ctx.is_expired():
			_send_error(ctx, _error("terrain_tools.TIMEOUT", "Terrain erosion exceeded its deadline"))
			return
		await _next_frame()
	var eroded := job.result()
	var data_error := _validate_height_data(data)
	if not data_error.is_empty():
		_send_error(ctx, data_error)
		return
	var built := await _build_incrementally(data, ctx)
	if _finish_error(built, ctx):
		return
	if not _target_still_valid(target):
		_send_error(ctx, _error("EDITED_SCENE_MISMATCH", "The edited scene changed while terrain was being eroded"))
		return
	_commit_replacement("Erode", target, built)
	_release_busy()
	ctx.send_deferred({"data": _response(target.container, target.root, data, built, "erode", {"affected_vertices": eroded.affected_vertices, "algorithm": settings.algorithm})})


func _commit_replacement(label: String, target: Dictionary, built: Dictionary) -> void:
	var container: Node3D = target.container
	var root: Node = target.root
	var previous_nodes: Array = target.structure.nodes
	var new_nodes := _make_children(built, bool(built.data.params.generate_collision))
	var old_meta = container.get_meta(META_KEY)
	var new_meta := _metadata(built.data)
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Terrain Tools: %s %s" % [label, container.name])
	undo_redo.add_do_method(container, "set_meta", META_KEY, new_meta)
	undo_redo.add_do_method(self, "_replace_managed_nodes", container, previous_nodes, new_nodes, root)
	for node in new_nodes:
		undo_redo.add_do_reference(node)
	undo_redo.add_undo_method(self, "_replace_managed_nodes", container, new_nodes, previous_nodes, root)
	undo_redo.add_undo_method(container, "set_meta", META_KEY, old_meta)
	for node in previous_nodes:
		undo_redo.add_undo_reference(node)
	undo_redo.commit_action()


func _materialize_data(state: Dictionary, ctx) -> Dictionary:
	var existing: Resource = state.get("data")
	if existing != null:
		return {"data": existing}
	var built := await _build_incrementally(state.params, ctx)
	if built.has("error"):
		return built
	return {"data": built.data}


func _build_incrementally(input: Variant, ctx) -> Dictionary:
	var job := TerrainBuildJob.new(input)
	while not job.step(FRAME_BUDGET_USEC):
		if ctx != null and ctx.is_expired():
			return _error("terrain_tools.TIMEOUT", "Terrain generation exceeded its deadline")
		await _next_frame()
	return job.result()


func _apply_strokes(data: Resource, strokes: Array, ctx) -> Dictionary:
	var changed := {}
	var size := int(data.params.size)
	var cell := float(data.params.cell_size)
	var half := (size - 1) * cell * 0.5
	var processed := 0
	for stroke_value in strokes:
		var stroke: Dictionary = stroke_value
		var source: PackedFloat32Array = data.final_heights()
		var noise := FastNoiseLite.new()
		if stroke.mode == "noise":
			noise.seed = stroke.seed
			noise.frequency = 0.15 / cell
		for index in source.size():
			var x: int = index % size
			var z := int(index / size)
			var distance := Vector2(x * cell - half - stroke.center_x, z * cell - half - stroke.center_z).length()
			if distance <= stroke.radius:
				var weight: float = 1.0 - distance / float(stroke.radius)
				if stroke.falloff == "smooth":
					weight = weight * weight * (3.0 - 2.0 * weight)
				var current: float = source[index]
				var updated: float = current
				match stroke.mode:
					"raise":
						updated += stroke.strength * weight
					"lower":
						updated -= stroke.strength * weight
					"flatten":
						updated = lerpf(current, stroke.target_height, minf(1.0, stroke.strength * weight))
					"smooth":
						updated = lerpf(current, _neighbor_average(source, index, size), minf(1.0, stroke.strength * weight))
					"noise":
						updated += noise.get_noise_2d(x, z) * stroke.strength * weight
				if not is_equal_approx(current, updated):
					if not is_finite(updated) or absf(updated) > MAX_HEIGHT_MAGNITUDE:
						return _error("VALUE_OUT_OF_RANGE", "Sculpting produced a height outside the supported range")
					data.edit_offsets[index] = updated - data.base_heights[index]
					changed[index] = true
			processed += 1
			if processed % 2048 == 0:
				if ctx != null and ctx.is_expired():
					return _error("terrain_tools.TIMEOUT", "Terrain sculpting exceeded its deadline")
				await _next_frame()
	return {"affected_vertices": changed.size()}


func _apply_holes(data: Resource, areas: Array, ctx) -> Dictionary:
	var changed := {}
	var size := int(data.params.size)
	var cell := float(data.params.cell_size)
	var half := (size - 1) * cell * 0.5
	var processed := 0
	for area_value in areas:
		var area: Dictionary = area_value
		var value := 1 if area.mode == "cut" else 0
		for index in data.holes.size():
			var x: int = index % size
			var z := int(index / size)
			var distance := Vector2(x * cell - half - area.center_x, z * cell - half - area.center_z).length()
			if distance <= area.radius and data.holes[index] != value:
				data.holes[index] = value
				changed[index] = true
			processed += 1
			if processed % 4096 == 0:
				if ctx != null and ctx.is_expired():
					return _error("terrain_tools.TIMEOUT", "Terrain hole generation exceeded its deadline")
				await _next_frame()
	return {"affected_vertices": changed.size()}


func _normalized_params(params: Dictionary) -> Dictionary:
	var size_value = params.get("size", 48)
	if not _is_integer_value(size_value):
		return _error("INVALID_PARAMS", "size must be an integer")
	var size := int(size_value)
	if size < MIN_SIZE or size > MAX_SIZE:
		return _error("VALUE_OUT_OF_RANGE", "size must be in %d..%d" % [MIN_SIZE, MAX_SIZE])
	var cell := _positive_float(params.get("cell_size", 2.0), "cell_size")
	if cell.has("error"):
		return cell
	var frequency := _positive_float(params.get("frequency", 0.05), "frequency")
	if frequency.has("error"):
		return frequency
	var height_scale := _positive_float(params.get("height_scale", 8.0), "height_scale")
	if height_scale.has("error"):
		return height_scale
	var base_height := _finite_float(params.get("base_height", 0.0), "base_height")
	if base_height.has("error"):
		return base_height
	var octaves_value = params.get("octaves", 3)
	if not _is_integer_value(octaves_value) or int(octaves_value) < 1 or int(octaves_value) > 6:
		return _error("VALUE_OUT_OF_RANGE", "octaves must be an integer in 1..6")
	var noise_value = params.get("noise_type", "simplex")
	if not noise_value is String or not NOISE_TYPES.has(String(noise_value)):
		return _error("VALUE_OUT_OF_RANGE", "noise_type must be one of: %s" % ", ".join(NOISE_TYPES))
	var seed_value = params.get("seed", 1337)
	if not _is_integer_value(seed_value) or float(seed_value) < -2147483648.0 or float(seed_value) > 2147483647.0:
		return _error("VALUE_OUT_OF_RANGE", "seed must be a signed 32-bit integer")
	var collision_value = params.get("generate_collision", true)
	if not collision_value is bool:
		return _error("INVALID_PARAMS", "generate_collision must be a boolean")
	var material_value = params.get("material_preset", "natural")
	if not material_value is String or not MATERIAL_PRESETS.has(String(material_value)):
		return _error("VALUE_OUT_OF_RANGE", "material_preset must be one of: %s" % ", ".join(MATERIAL_PRESETS))
	return {"params": {
		"size": size,
		"cell_size": cell.value,
		"seed": int(seed_value),
		"noise_type": String(noise_value),
		"frequency": frequency.value,
		"octaves": int(octaves_value),
		"height_scale": height_scale.value,
		"base_height": base_height.value,
		"generate_collision": collision_value,
		"material_preset": String(material_value),
	}}


func _normalized_strokes(value: Variant) -> Dictionary:
	if not value is Array or value.is_empty() or value.size() > 64:
		return _error("INVALID_PARAMS", "strokes must be an array containing 1..64 entries")
	var result: Array = []
	for entry in value:
		if not entry is Dictionary:
			return _error("INVALID_PARAMS", "each stroke must be an object")
		var allowed := ["center_x", "center_z", "radius", "mode", "strength", "falloff", "target_height", "seed"]
		var unknown := _unknown_keys(entry, allowed)
		if not unknown.is_empty():
			return unknown
		for required in ["center_x", "center_z", "radius", "mode", "strength"]:
			if not entry.has(required):
				return _error("INVALID_PARAMS", "stroke.%s is required" % required)
		var center_x := _finite_float(entry.center_x, "stroke.center_x")
		var center_z := _finite_float(entry.center_z, "stroke.center_z")
		var radius := _positive_float(entry.radius, "stroke.radius")
		var strength := _positive_float(entry.strength, "stroke.strength")
		for checked in [center_x, center_z, radius, strength]:
			if checked.has("error"):
				return checked
		if not entry.mode is String or not STROKE_MODES.has(String(entry.mode)):
			return _error("VALUE_OUT_OF_RANGE", "stroke.mode must be one of: %s" % ", ".join(STROKE_MODES))
		var falloff = entry.get("falloff", "smooth")
		if not falloff is String or not FALLOFFS.has(String(falloff)):
			return _error("VALUE_OUT_OF_RANGE", "stroke.falloff must be smooth or linear")
		var normalized := {"center_x": center_x.value, "center_z": center_z.value, "radius": radius.value, "mode": String(entry.mode), "strength": strength.value, "falloff": String(falloff)}
		if normalized.mode == "flatten":
			if not entry.has("target_height"):
				return _error("INVALID_PARAMS", "flatten strokes require target_height")
			var target := _finite_float(entry.target_height, "stroke.target_height")
			if target.has("error"):
				return target
			normalized.target_height = target.value
		elif entry.has("target_height"):
			return _error("INVALID_PARAMS", "target_height is only valid for flatten strokes")
		if normalized.mode == "noise":
			var seed = entry.get("seed", 1337)
			if not _is_signed_seed(seed):
				return _error("VALUE_OUT_OF_RANGE", "stroke.seed must be a signed 32-bit integer")
			normalized.seed = int(seed)
		elif entry.has("seed"):
			return _error("INVALID_PARAMS", "seed is only valid for noise strokes")
		result.append(normalized)
	return {"items": result}


func _normalized_areas(value: Variant) -> Dictionary:
	if not value is Array or value.is_empty() or value.size() > 64:
		return _error("INVALID_PARAMS", "areas must be an array containing 1..64 entries")
	var result: Array = []
	for entry in value:
		if not entry is Dictionary:
			return _error("INVALID_PARAMS", "each hole area must be an object")
		var unknown := _unknown_keys(entry, ["center_x", "center_z", "radius", "mode"])
		if not unknown.is_empty():
			return unknown
		for required in ["center_x", "center_z", "radius", "mode"]:
			if not entry.has(required):
				return _error("INVALID_PARAMS", "area.%s is required" % required)
		var center_x := _finite_float(entry.center_x, "area.center_x")
		var center_z := _finite_float(entry.center_z, "area.center_z")
		var radius := _positive_float(entry.radius, "area.radius")
		for checked in [center_x, center_z, radius]:
			if checked.has("error"):
				return checked
		if not entry.mode is String or not ["cut", "fill"].has(String(entry.mode)):
			return _error("VALUE_OUT_OF_RANGE", "area.mode must be cut or fill")
		result.append({"center_x": center_x.value, "center_z": center_z.value, "radius": radius.value, "mode": String(entry.mode)})
	return {"items": result}


func _normalized_erosion(params: Dictionary) -> Dictionary:
	var algorithm = params.get("algorithm", "thermal")
	if not algorithm is String or not ["thermal", "hydraulic"].has(String(algorithm)):
		return _error("VALUE_OUT_OF_RANGE", "algorithm must be thermal or hydraulic")
	var iterations = params.get("iterations", 20)
	if not _is_integer_value(iterations) or int(iterations) < 1 or int(iterations) > 200:
		return _error("VALUE_OUT_OF_RANGE", "iterations must be an integer in 1..200")
	var intensity := _positive_float(params.get("intensity", 0.5), "intensity")
	if intensity.has("error"):
		return intensity
	if intensity.value > 1.0:
		return _error("VALUE_OUT_OF_RANGE", "intensity must be at most 1")
	var seed = params.get("seed", 1337)
	if not _is_signed_seed(seed):
		return _error("VALUE_OUT_OF_RANGE", "seed must be a signed 32-bit integer")
	return {"settings": {"algorithm": String(algorithm), "iterations": int(iterations), "intensity": intensity.value, "seed": int(seed)}}


func _managed_target(params: Dictionary) -> Dictionary:
	if not params.has("path") or not params.path is String or String(params.path).is_empty():
		return _error("INVALID_PARAMS", "path is required and must be a non-empty string")
	var scene := _edited_scene(params.get("scene_file", ""))
	if scene.has("error"):
		return scene
	var root: Node = scene.node
	var resolved := _resolve_scene_node(String(params.path), root)
	if resolved.has("error"):
		return resolved
	var container: Node = resolved.node
	if not container is Node3D:
		return _error("WRONG_TYPE", "Terrain path must resolve to a Node3D")
	var state := _managed_state(container)
	if state.has("error"):
		return state
	var structure := _capture_managed_nodes(container, int(state.format_version) == LEGACY_FORMAT_VERSION)
	if structure.has("error"):
		return structure
	return {
		"root": root,
		"container": container,
		"container_parent": container.get_parent(),
		"container_path": _path_from_node(container, root),
		"state": state,
		"structure": structure,
	}


func _managed_state(container: Node) -> Dictionary:
	if not container.has_meta(META_KEY):
		return _error("terrain_tools.NOT_MANAGED", "The target was not created by Godot AI Terrain Tools")
	var metadata = container.get_meta(META_KEY)
	if not metadata is Dictionary:
		return _error("terrain_tools.UNSUPPORTED_FORMAT", "Terrain metadata is missing or unsupported")
	var version := int(metadata.get("format_version", 0))
	if version == LEGACY_FORMAT_VERSION:
		if not metadata.get("params") is Dictionary:
			return _error("terrain_tools.UNSUPPORTED_FORMAT", "Legacy terrain metadata has no parameter snapshot")
		var checked := _normalized_params(metadata.params)
		if checked.has("error"):
			return _error("terrain_tools.UNSUPPORTED_FORMAT", "Legacy terrain parameters are invalid")
		return {"format_version": version, "params": checked.params, "data": null}
	if version != FORMAT_VERSION or not metadata.get("data") is Resource:
		return _error("terrain_tools.UNSUPPORTED_FORMAT", "Terrain metadata is missing or unsupported")
	var data: Resource = metadata.data
	if data.get_script() != TerrainData:
		return _error("terrain_tools.UNSUPPORTED_FORMAT", "TerrainData is invalid or unsupported")
	var checked := _normalized_params(data.params)
	if checked.has("error") or not data.is_valid():
		return _error("terrain_tools.UNSUPPORTED_FORMAT", "TerrainData parameters or arrays are invalid")
	var height_error := _validate_height_data(data)
	if not height_error.is_empty():
		return _error("terrain_tools.UNSUPPORTED_FORMAT", "TerrainData heights are invalid")
	return {"format_version": version, "params": checked.params, "data": data}


func _managed_metadata(container: Node) -> Dictionary:
	var state := _managed_state(container)
	if state.has("error"):
		return state
	return {"metadata": container.get_meta(META_KEY), "state": state}


func _capture_managed_nodes(container: Node, allow_legacy_collision: bool = false) -> Dictionary:
	var meshes := _find_direct_children(container, MESH_CHILD)
	if meshes.size() != 1 or not meshes[0] is MeshInstance3D or meshes[0].mesh == null:
		return _error("terrain_tools.INVALID_STRUCTURE", "Managed terrain must have exactly one valid TerrainMesh")
	var nodes: Array[Node] = [meshes[0]]
	var collisions := _find_direct_children(container, COLLISION_CHILD)
	if collisions.size() > 1:
		return _error("terrain_tools.INVALID_STRUCTURE", "Managed terrain has duplicate TerrainCollision children")
	if collisions.size() == 1:
		var collision: Node = collisions[0]
		if not collision is StaticBody3D or collision.get_child_count() != 1 or not collision.get_child(0) is CollisionShape3D:
			return _error("terrain_tools.INVALID_STRUCTURE", "Managed TerrainCollision has an unexpected structure")
		var shape := (collision.get_child(0) as CollisionShape3D).shape
		if not shape is HeightMapShape3D and not (allow_legacy_collision and shape is ConcavePolygonShape3D):
			return _error("terrain_tools.INVALID_STRUCTURE", "Managed TerrainCollision has no valid heightmap shape")
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
		var shape := HeightMapShape3D.new()
		shape.map_width = int(built.data.params.size)
		shape.map_depth = int(built.data.params.size)
		shape.map_data = built.collision_heights
		collision_shape.shape = shape
		collision_shape.scale = Vector3(float(built.data.params.cell_size), 1.0, float(built.data.params.cell_size))
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


func _response(container: Node, root: Node, data: Resource, built: Dictionary, operation: String = "regenerate", extra: Dictionary = {}) -> Dictionary:
	var response := {
		"path": _path_from_node(container, root),
		"name": container.name,
		"operation": operation,
		"params": data.params.duplicate(true),
		"vertices": built.vertices,
		"triangles": built.triangle_count,
		"generate_collision": bool(data.params.generate_collision),
		"material_preset": String(data.params.material_preset),
		"hole_vertices": _count_holes(data),
		"undoable": true,
	}
	response.merge(extra, true)
	return response


func _metadata(value: Variant) -> Dictionary:
	if value is Dictionary:
		return {"format_version": LEGACY_FORMAT_VERSION, "params": value.duplicate(true)}
	return {"format_version": FORMAT_VERSION, "params": value.params.duplicate(true), "data": value}


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
	var node := root.get_node_or_null(NodePath("/".join(parts.slice(1))))
	if node == null:
		return _error("NODE_NOT_FOUND", "Node not found: %s" % path)
	return {"node": node}


func _validate_request(params: Dictionary, allowed: Array, string_fields: Array) -> Dictionary:
	var unknown := _unknown_keys(params, allowed)
	if not unknown.is_empty():
		return unknown
	for field in string_fields:
		if params.has(field) and not params[field] is String:
			return _error("INVALID_PARAMS", "%s must be a string" % field)
	return {}


func _unknown_keys(values: Dictionary, allowed: Array) -> Dictionary:
	for key in values:
		if not allowed.has(String(key)):
			return _error("INVALID_PARAMS", "Unknown parameter: %s" % key)
	return {}


func _positive_float(value: Variant, field: String) -> Dictionary:
	var checked := _finite_float(value, field)
	if checked.has("error"):
		return checked
	if checked.value <= 0.0:
		return _error("VALUE_OUT_OF_RANGE", "%s must be greater than zero" % field)
	return checked


func _finite_float(value: Variant, field: String) -> Dictionary:
	if not value is int and not value is float:
		return _error("INVALID_PARAMS", "%s must be numeric" % field)
	var converted := float(value)
	if not is_finite(converted):
		return _error("INVALID_PARAMS", "%s must be finite" % field)
	if absf(converted) > MAX_NUMBER_MAGNITUDE:
		return _error("VALUE_OUT_OF_RANGE", "%s magnitude must not exceed %s" % [field, MAX_NUMBER_MAGNITUDE])
	return {"value": converted}


func _is_integer_value(value: Variant) -> bool:
	return value is int or value is float and is_finite(value) and float(value) == floorf(value)


func _is_signed_seed(value: Variant) -> bool:
	return _is_integer_value(value) and float(value) >= -2147483648.0 and float(value) <= 2147483647.0


func _neighbor_average(values: PackedFloat32Array, index: int, size: int) -> float:
	var total := values[index]
	var count := 1
	var x := index % size
	var z := int(index / size)
	if x > 0:
		total += values[index - 1]
		count += 1
	if x + 1 < size:
		total += values[index + 1]
		count += 1
	if z > 0:
		total += values[index - size]
		count += 1
	if z + 1 < size:
		total += values[index + size]
		count += 1
	return total / count


func _count_holes(data: Resource) -> int:
	var count := 0
	for value in data.holes:
		if value != 0:
			count += 1
	return count


func _target_still_valid(target: Dictionary) -> bool:
	if (
		not _scene_still_valid(target.root)
		or not is_instance_valid(target.container)
		or target.container.get_parent() != target.container_parent
		or not target.root.is_ancestor_of(target.container)
		or _path_from_node(target.container, target.root) != target.container_path
	):
		return false
	var current := _capture_managed_nodes(
		target.container,
		int(target.state.format_version) == LEGACY_FORMAT_VERSION,
	)
	return not current.has("error") and _same_nodes(current.nodes, target.structure.nodes)


func _same_nodes(first: Array, second: Array) -> bool:
	if first.size() != second.size():
		return false
	for index in first.size():
		if first[index] != second[index]:
			return false
	return true


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


func _busy_error() -> Dictionary:
	if _busy and Time.get_ticks_msec() - _busy_started_msec > BUSY_RECOVERY_MSEC:
		reset_busy()
	if not _busy:
		return {}
	return _error("terrain_tools.BUSY", "Terrain generation is already running; retry after it finishes", {"retryable": true})


func _claim_busy() -> void:
	_busy = true


func _release_busy() -> void:
	_busy = false


func _finish_error(result: Dictionary, ctx) -> bool:
	if not result.has("error"):
		return false
	_send_error(ctx, result)
	return true


func _send_error(ctx, error: Dictionary) -> void:
	_release_busy()
	ctx.send_deferred(error)


func _validate_height_data(data: Resource) -> Dictionary:
	var validation_error: String = data.validation_error()
	if not validation_error.is_empty():
		return _error("terrain_tools.INVALID_DATA", validation_error)
	for height in data.final_heights():
		if not is_finite(height) or absf(height) > MAX_HEIGHT_MAGNITUDE:
			return _error("VALUE_OUT_OF_RANGE", "Terrain heights exceed the supported range")
	return {}


static func _error(code: String, message: String, data: Dictionary = {}) -> Dictionary:
	var error := {"code": code, "message": message}
	if not data.is_empty():
		error.data = data
	return {"status": "error", "error": error}


static func _next_frame() -> Signal:
	return (Engine.get_main_loop() as SceneTree).process_frame
