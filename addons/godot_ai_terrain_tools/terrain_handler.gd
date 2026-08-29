@tool
extends RefCounted

const TerrainData := preload("res://addons/godot_ai_terrain_tools/terrain_data.gd")
const TerrainBuildJob := preload("res://addons/godot_ai_terrain_tools/terrain_build_job.gd")
const TerrainErosionJob := preload("res://addons/godot_ai_terrain_tools/terrain_erosion_job.gd")
const TerrainRoadJob := preload("res://addons/godot_ai_terrain_tools/terrain_road_job.gd")
const TerrainPaintJob := preload("res://addons/godot_ai_terrain_tools/terrain_paint_job.gd")
const TerrainLandformJob := preload("res://addons/godot_ai_terrain_tools/terrain_landform_job.gd")

const MIN_SIZE := 4
const MAX_SIZE := 256
const FRAME_BUDGET_USEC := 3000
const BUSY_RECOVERY_MSEC := 35000
const MAX_NUMBER_MAGNITUDE := 1000000.0
const MAX_HEIGHT_MAGNITUDE := 1000000000.0
const FORMAT_VERSION := 3
const PREVIOUS_FORMAT_VERSION := 2
const LEGACY_FORMAT_VERSION := 1
const MESH_CHILD := "TerrainMesh"
const COLLISION_CHILD := "TerrainCollision"
const META_KEY := &"godot_ai_terrain_tools"
const MATERIAL_PRESETS := ["natural", "desert", "snow", "volcanic", "alien"]
const RENDER_MODES := ["procedural", "bundled", "custom"]
const SURFACE_PROFILES := ["mountain_valley", "forest", "arid", "legacy"]
const PAINT_LAYERS := ["ground", "road", "dirt", "sand", "rock", "snow", "auto"]
const PARAM_KEYS := [
	"size", "cell_size", "seed", "noise_type", "frequency", "octaves",
	"height_scale", "base_height", "generate_collision", "material_preset",
	"render_mode", "texture_scale", "custom_textures", "surface_profile", "texture_variants",
]
## Literal arrays retain Godot 4.5 constant-expression compatibility.
const CREATE_KEYS := [
	"size", "cell_size", "seed", "noise_type", "frequency", "octaves",
	"height_scale", "base_height", "generate_collision", "material_preset",
	"render_mode", "texture_scale", "custom_textures", "surface_profile", "texture_variants",
	"parent_path", "scene_file", "name", "session_id",
]
const REGENERATE_KEYS := [
	"size", "cell_size", "seed", "noise_type", "frequency", "octaves",
	"height_scale", "base_height", "generate_collision", "material_preset",
	"render_mode", "texture_scale", "custom_textures", "surface_profile", "texture_variants",
	"reset_modifications", "path", "scene_file", "session_id",
]
const EDIT_KEYS := ["path", "scene_file", "session_id", "strokes"]
const HOLE_KEYS := ["path", "scene_file", "session_id", "areas"]
const EROSION_KEYS := ["path", "scene_file", "session_id", "algorithm", "iterations", "intensity", "seed", "preset", "region", "rain", "erosion", "deposition", "evaporation", "talus", "ridge_preservation"]
const LANDFORM_KEYS := ["path", "scene_file", "session_id", "features"]
const ROAD_KEYS := ["path", "scene_file", "session_id", "points", "width", "shoulder_width", "elevation_mode", "start_height", "end_height", "max_grade", "smoothing_passes", "paint_road", "falloff"]
const PAINT_KEYS := ["path", "scene_file", "session_id", "strokes"]
const MATERIAL_KEYS := ["path", "scene_file", "session_id", "render_mode", "texture_scale", "custom_textures", "material_preset", "surface_profile", "texture_variants"]
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


func landform(params: Dictionary, ctx) -> Dictionary:
	var busy := _busy_error()
	if not busy.is_empty():
		return busy
	var request_error := _validate_request(params, LANDFORM_KEYS, ["path", "scene_file"])
	if not request_error.is_empty():
		return request_error
	var normalized := _normalized_landforms(params.get("features"))
	if normalized.has("error"):
		return normalized
	var target := _managed_target(params)
	if target.has("error"):
		return target
	_claim_busy()
	_finish_landform(normalized.items, target, ctx)
	return {"_deferred": true}


func road(params: Dictionary, ctx) -> Dictionary:
	var busy := _busy_error()
	if not busy.is_empty():
		return busy
	var request_error := _validate_request(params, ROAD_KEYS, ["path", "scene_file", "elevation_mode", "falloff"])
	if not request_error.is_empty():
		return request_error
	var normalized := _normalized_road(params)
	if normalized.has("error"):
		return normalized
	var target := _managed_target(params)
	if target.has("error"):
		return target
	_claim_busy()
	_finish_road(normalized.settings, target, ctx)
	return {"_deferred": true}


func paint(params: Dictionary, ctx) -> Dictionary:
	var busy := _busy_error()
	if not busy.is_empty():
		return busy
	var request_error := _validate_request(params, PAINT_KEYS, ["path", "scene_file"])
	if not request_error.is_empty():
		return request_error
	var normalized := _normalized_paint_strokes(params.get("strokes"))
	if normalized.has("error"):
		return normalized
	var target := _managed_target(params)
	if target.has("error"):
		return target
	_claim_busy()
	_finish_paint(normalized.items, target, ctx)
	return {"_deferred": true}


func material(params: Dictionary, ctx) -> Dictionary:
	var busy := _busy_error()
	if not busy.is_empty():
		return busy
	var request_error := _validate_request(params, MATERIAL_KEYS, ["path", "scene_file", "render_mode", "material_preset"])
	if not request_error.is_empty():
		return request_error
	var target := _managed_target(params)
	if target.has("error"):
		return target
	var merged: Dictionary = target.state.params.duplicate(true)
	for key in ["render_mode", "texture_scale", "custom_textures", "material_preset", "surface_profile", "texture_variants"]:
		if params.has(key):
			merged[key] = params[key]
	var checked := _normalized_params(merged)
	if checked.has("error"):
		return checked
	_claim_busy()
	_finish_material(checked.params, target, ctx)
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
		if old_data.paint_weights.size() == data.paint_weights.size():
			data.paint_weights = old_data.paint_weights.duplicate()
			data.paint_coverage = old_data.paint_coverage.duplicate()
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
	var job := TerrainErosionJob.new(data, settings.algorithm, settings.iterations, settings.intensity, settings.seed, settings)
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


func _finish_landform(features: Array, target: Dictionary, ctx) -> void:
	await _next_frame()
	var prepared := await _materialize_data(target.state, ctx)
	if _finish_error(prepared, ctx):
		return
	var data: Resource = prepared.data.snapshot()
	var applied := await _apply_landforms(data, features, ctx)
	if _finish_error(applied, ctx):
		return
	var built := await _build_incrementally(data, ctx)
	if _finish_error(built, ctx):
		return
	if not _target_still_valid(target):
		_send_error(ctx, _error("EDITED_SCENE_MISMATCH", "The edited scene changed while landforms were being generated"))
		return
	_commit_replacement("Landform", target, built)
	_release_busy()
	ctx.send_deferred({"data": _response(target.container, target.root, data, built, "landform", {"affected_vertices": applied.affected_vertices})})


func _finish_road(settings: Dictionary, target: Dictionary, ctx) -> void:
	await _next_frame()
	var prepared := await _materialize_data(target.state, ctx)
	if _finish_error(prepared, ctx):
		return
	var data: Resource = prepared.data.snapshot()
	var applied := await _apply_road(data, settings, ctx)
	if _finish_error(applied, ctx):
		return
	var built := await _build_incrementally(data, ctx)
	if _finish_error(built, ctx):
		return
	if not _target_still_valid(target):
		_send_error(ctx, _error("EDITED_SCENE_MISMATCH", "The edited scene changed while the road was being generated"))
		return
	_commit_replacement("Road", target, built)
	_release_busy()
	ctx.send_deferred({"data": _response(target.container, target.root, data, built, "road", {
		"affected_vertices": applied.affected_vertices,
		"painted_vertices": applied.painted_vertices,
		"road_length": applied.road_length,
	})})


func _finish_paint(strokes: Array, target: Dictionary, ctx) -> void:
	await _next_frame()
	var prepared := await _materialize_data(target.state, ctx)
	if _finish_error(prepared, ctx):
		return
	var data: Resource = prepared.data.snapshot()
	var applied := await _apply_paint(data, strokes, ctx)
	if _finish_error(applied, ctx):
		return
	var built := await _build_incrementally(data, ctx)
	if _finish_error(built, ctx):
		return
	if not _target_still_valid(target):
		_send_error(ctx, _error("EDITED_SCENE_MISMATCH", "The edited scene changed while terrain was being painted"))
		return
	_commit_replacement("Paint", target, built)
	_release_busy()
	ctx.send_deferred({"data": _response(target.container, target.root, data, built, "paint", {
		"affected_vertices": applied.affected_vertices,
	})})


func _finish_material(params: Dictionary, target: Dictionary, ctx) -> void:
	await _next_frame()
	var prepared := await _materialize_data(target.state, ctx)
	if _finish_error(prepared, ctx):
		return
	var data: Resource = _regenerated_material_data(params, prepared.data)
	var built := await _build_incrementally(data, ctx)
	if _finish_error(built, ctx):
		return
	if not _target_still_valid(target):
		_send_error(ctx, _error("EDITED_SCENE_MISMATCH", "The edited scene changed while the terrain material was being updated"))
		return
	_commit_replacement("Material", target, built)
	_release_busy()
	ctx.send_deferred({"data": _response(target.container, target.root, data, built, "material")})


func _regenerated_material_data(params: Dictionary, old_data: Resource) -> Resource:
	var data: Resource = old_data.snapshot()
	data.params = params.duplicate(true)
	return data


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
	var size: int = int(data.params.size)
	var cell: float = float(data.params.cell_size)
	var half: float = (size - 1) * cell * 0.5
	var processed := 0
	for stroke_value in strokes:
		var stroke: Dictionary = stroke_value
		var source: PackedFloat32Array = data.final_heights()
		var noise := FastNoiseLite.new()
		if stroke.mode == "noise":
			noise.seed = stroke.seed
			noise.frequency = 0.15 / cell
		var bounds := _circle_grid_bounds(size, cell, half, Vector2(stroke.center_x, stroke.center_z), stroke.radius)
		for z in range(bounds.min_z, bounds.max_z + 1):
			for x in range(bounds.min_x, bounds.max_x + 1):
				var index: int = z * size + x
				var distance := Vector2(x * cell - half - stroke.center_x, z * cell - half - stroke.center_z).length()
				if distance <= stroke.radius:
					var weight: float = 1.0 - distance / float(stroke.radius)
					if stroke.falloff == "smooth":
						weight = weight * weight * (3.0 - 2.0 * weight)
					var current: float = source[index]
					var updated: float = current
					match stroke.mode:
						"raise": updated += stroke.strength * weight
						"lower": updated -= stroke.strength * weight
						"flatten": updated = lerpf(current, stroke.target_height, minf(1.0, stroke.strength * weight))
						"smooth": updated = lerpf(current, _neighbor_average(source, index, size), minf(1.0, stroke.strength * weight))
						"noise": updated += noise.get_noise_2d(x, z) * stroke.strength * weight
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
		var bounds := _circle_grid_bounds(size, cell, half, Vector2(area.center_x, area.center_z), area.radius)
		for z in range(bounds.min_z, bounds.max_z + 1):
			for x in range(bounds.min_x, bounds.max_x + 1):
				var index: int = z * size + x
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


func _apply_landforms(data: Resource, features: Array, ctx) -> Dictionary:
	var job := TerrainLandformJob.new(data, features)
	while not job.step(FRAME_BUDGET_USEC):
		if ctx != null and ctx.is_expired():
			return _error("terrain_tools.TIMEOUT", "Terrain landform generation exceeded its deadline")
		await _next_frame()
	return job.result()


func _apply_landforms_sync(data: Resource, features: Array) -> Dictionary:
	var job := TerrainLandformJob.new(data, features)
	while not job.step(1000000):
		pass
	return job.result()


func _apply_erosion_sync(data: Resource, settings: Dictionary) -> Dictionary:
	var job := TerrainErosionJob.new(data, settings.algorithm, settings.iterations, settings.intensity, settings.seed, settings)
	while not job.step(1000000):
		pass
	return job.result()


static func _circle_grid_bounds(size: int, cell: float, half: float, center: Vector2, radius: float) -> Dictionary:
	return {
		"min_x": clampi(int(floor((center.x - radius + half) / cell)), 0, size - 1),
		"max_x": clampi(int(ceil((center.x + radius + half) / cell)), 0, size - 1),
		"min_z": clampi(int(floor((center.y - radius + half) / cell)), 0, size - 1),
		"max_z": clampi(int(ceil((center.y + radius + half) / cell)), 0, size - 1),
	}


func _apply_road(data: Resource, settings: Dictionary, ctx) -> Dictionary:
	var job := TerrainRoadJob.new(data, settings)
	while not job.step(FRAME_BUDGET_USEC):
		if ctx != null and ctx.is_expired():
			return _error("terrain_tools.TIMEOUT", "Road generation exceeded its deadline")
		await _next_frame()
	return job.result()


func _apply_road_sync(data: Resource, settings: Dictionary) -> Dictionary:
	var job := TerrainRoadJob.new(data, settings)
	while not job.step(1000000):
		pass
	return job.result()


func _apply_road_legacy(data: Resource, settings: Dictionary, ctx) -> Dictionary:
	var size: int = int(data.params.size)
	var cell: float = float(data.params.cell_size)
	var half: float = (size - 1) * cell * 0.5
	var heights: PackedFloat32Array = data.final_heights()
	var points: Array = settings.points
	var cumulative: Array[float] = [0.0]
	for index in range(1, points.size()):
		var point: Vector2 = points[index]
		cumulative.append(cumulative[-1] + point.distance_to(points[index - 1]))
	var road_length: float = cumulative[-1]
	var start_height: float = _sample_height(heights, size, cell, half, points[0])
	var end_height: float = _sample_height(heights, size, cell, half, points[-1])
	if settings.has("start_height"):
		start_height = settings.start_height
		end_height = settings.end_height
	if absf(end_height - start_height) > road_length * float(settings.max_grade) + 0.0001:
		return _error("terrain_tools.GRADE_INFEASIBLE", "Road endpoints cannot be connected within max_grade")
	var profile: Array[float] = []
	for index in points.size():
		if settings.elevation_mode == "linear":
			profile.append(lerpf(start_height, end_height, cumulative[index] / road_length))
		else:
			profile.append(_sample_height(heights, size, cell, half, points[index]))
	profile[0] = start_height
	profile[-1] = end_height
	if settings.elevation_mode == "follow_smooth":
		for _pass in int(settings.smoothing_passes):
			var source := profile.duplicate()
			for index in range(1, profile.size() - 1):
				profile[index] = (source[index - 1] + source[index] * 2.0 + source[index + 1]) * 0.25
		_limit_road_grade(profile, cumulative, float(settings.max_grade), start_height, end_height)
	var changed := {}
	var painted := {}
	var half_width := float(settings.width) * 0.5
	var shoulder := float(settings.shoulder_width)
	var processed := 0
	for index in heights.size():
		if data.holes[index] != 0:
			continue
		var x: int = index % size
		var z: int = int(index / size)
		var position: Vector2 = Vector2(x * cell - half, z * cell - half)
		var sample := _closest_path_sample(points, profile, position)
		if sample.distance > half_width + shoulder:
			continue
		var weight := 1.0
		if sample.distance > half_width:
			if shoulder <= 0.0:
				continue
			weight = 1.0 - (sample.distance - half_width) / shoulder
			if settings.falloff == "smooth":
				weight = weight * weight * (3.0 - 2.0 * weight)
		var updated: float = lerpf(heights[index], sample.height, weight)
		if not is_equal_approx(updated, heights[index]):
			data.edit_offsets[index] = updated - data.base_heights[index]
			changed[index] = true
		if settings.paint_road:
			_paint_sample(data, index, "road", weight)
			painted[index] = true
		processed += 1
		if processed % 2048 == 0:
			if ctx != null and ctx.is_expired():
				return _error("terrain_tools.TIMEOUT", "Road generation exceeded its deadline")
			await _next_frame()
	if changed.is_empty() and painted.is_empty():
		return _error("terrain_tools.OUTSIDE_TERRAIN", "The road corridor does not intersect any unmasked terrain samples")
	return {
		"affected_vertices": changed.size(),
		"painted_vertices": painted.size(),
		"road_length": road_length,
	}


func _apply_paint(data: Resource, strokes: Array, ctx) -> Dictionary:
	var job := TerrainPaintJob.new(data, strokes)
	while not job.step(FRAME_BUDGET_USEC):
		if ctx != null and ctx.is_expired():
			return _error("terrain_tools.TIMEOUT", "Terrain painting exceeded its deadline")
		await _next_frame()
	return job.result()


func _apply_paint_sync(data: Resource, strokes: Array) -> Dictionary:
	var job := TerrainPaintJob.new(data, strokes)
	while not job.step(1000000):
		pass
	return job.result()


func _apply_paint_legacy(data: Resource, strokes: Array, ctx) -> Dictionary:
	var size: int = int(data.params.size)
	var cell: float = float(data.params.cell_size)
	var half: float = (size - 1) * cell * 0.5
	var changed := {}
	var processed := 0
	for stroke_value in strokes:
		var stroke: Dictionary = stroke_value
		for index in data.paint_coverage.size():
			if data.holes[index] != 0:
				continue
			var x: int = index % size
			var z: int = int(index / size)
			var position: Vector2 = Vector2(x * cell - half, z * cell - half)
			var distance: float = _distance_to_polyline(stroke.points, position)
			if distance <= stroke.radius:
				var weight: float = 1.0 - distance / float(stroke.radius)
				if stroke.falloff == "smooth":
					weight = weight * weight * (3.0 - 2.0 * weight)
				var amount: float = float(stroke.strength) * weight
				if amount > 0.0:
					_paint_sample(data, index, stroke.layer, amount)
					changed[index] = true
			processed += 1
			if processed % 4096 == 0:
				if ctx != null and ctx.is_expired():
					return _error("terrain_tools.TIMEOUT", "Terrain painting exceeded its deadline")
				await _next_frame()
	return {"affected_vertices": changed.size()}


func _paint_sample(data: Resource, index: int, layer: String, amount: float) -> void:
	amount = clampf(amount, 0.0, 1.0)
	if layer == "auto":
		data.paint_coverage[index] = maxf(0.0, data.paint_coverage[index] - amount)
		if is_zero_approx(data.paint_coverage[index]):
			data.paint_weights[index] = Color(0.0, 0.0, 0.0, 0.0)
		return
	var target := _layer_weights(layer)
	var current: Color = data.paint_weights[index]
	if current.r + current.g + current.b + current.a <= 0.00001:
		current = target
	else:
		current = _normalized_color_weights(current).lerp(target, amount)
	data.paint_weights[index] = _normalized_color_weights(current)
	data.paint_coverage[index] = lerpf(data.paint_coverage[index], 1.0, amount)


func _layer_weights(layer: String) -> Color:
	match layer:
		"road":
			return Color(0.0, 1.0, 0.0, 0.0)
		"rock":
			return Color(0.0, 0.0, 1.0, 0.0)
		"snow":
			return Color(0.0, 0.0, 0.0, 1.0)
		_:
			return Color(1.0, 0.0, 0.0, 0.0)


func _normalized_color_weights(value: Color) -> Color:
	var total := value.r + value.g + value.b + value.a
	return value / total if total > 0.00001 else Color(1.0, 0.0, 0.0, 0.0)


func _limit_road_grade(profile: Array[float], distances: Array[float], max_grade: float, start_height: float, end_height: float) -> void:
	for _pass in 4:
		profile[0] = start_height
		for index in range(1, profile.size()):
			var allowance := (distances[index] - distances[index - 1]) * max_grade
			profile[index] = clampf(profile[index], profile[index - 1] - allowance, profile[index - 1] + allowance)
		profile[-1] = end_height
		for index in range(profile.size() - 2, -1, -1):
			var allowance := (distances[index + 1] - distances[index]) * max_grade
			profile[index] = clampf(profile[index], profile[index + 1] - allowance, profile[index + 1] + allowance)
	profile[0] = start_height
	profile[-1] = end_height


func _closest_path_sample(points: Array, profile: Array[float], position: Vector2) -> Dictionary:
	var best_distance := INF
	var best_height := profile[0]
	for index in range(points.size() - 1):
		var start: Vector2 = points[index]
		var finish: Vector2 = points[index + 1]
		var segment: Vector2 = finish - start
		var t: float = clampf((position - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
		var distance: float = position.distance_to(start + segment * t)
		if distance < best_distance:
			best_distance = distance
			best_height = lerpf(profile[index], profile[index + 1], t)
	return {"distance": best_distance, "height": best_height}


func _distance_to_polyline(points: Array, position: Vector2) -> float:
	if points.size() == 1:
		return position.distance_to(points[0])
	var profile: Array[float] = []
	profile.resize(points.size())
	return float(_closest_path_sample(points, profile, position).distance)


func _sample_height(heights: PackedFloat32Array, size: int, cell: float, half: float, point: Vector2) -> float:
	var grid_x := clampf((point.x + half) / cell, 0.0, size - 1.0)
	var grid_z := clampf((point.y + half) / cell, 0.0, size - 1.0)
	var x0 := int(floorf(grid_x))
	var z0 := int(floorf(grid_z))
	var x1 := mini(x0 + 1, size - 1)
	var z1 := mini(z0 + 1, size - 1)
	var tx := grid_x - x0
	var tz := grid_z - z0
	var top := lerpf(heights[z0 * size + x0], heights[z0 * size + x1], tx)
	var bottom := lerpf(heights[z1 * size + x0], heights[z1 * size + x1], tx)
	return lerpf(top, bottom, tz)


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
	var render_mode = params.get("render_mode", "bundled")
	if not render_mode is String or not RENDER_MODES.has(String(render_mode)):
		return _error("VALUE_OUT_OF_RANGE", "render_mode must be one of: %s" % ", ".join(RENDER_MODES))
	var texture_scale := _positive_float(params.get("texture_scale", 0.2), "texture_scale")
	if texture_scale.has("error"):
		return texture_scale
	var custom_textures := _normalized_custom_textures(params.get("custom_textures", {}))
	if custom_textures.has("error"):
		return custom_textures
	var surface_profile = params.get("surface_profile", "mountain_valley")
	if not surface_profile is String or not SURFACE_PROFILES.has(String(surface_profile)):
		return _error("VALUE_OUT_OF_RANGE", "surface_profile must be one of: %s" % ", ".join(SURFACE_PROFILES))
	var texture_variants := _normalized_texture_variants(params.get("texture_variants", {}))
	if texture_variants.has("error"):
		return texture_variants
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
		"render_mode": String(render_mode),
		"texture_scale": texture_scale.value,
		"custom_textures": custom_textures.value,
		"surface_profile": String(surface_profile),
		"texture_variants": texture_variants.value,
	}}


func _normalized_texture_variants(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _error("INVALID_PARAMS", "texture_variants must be an object")
	var unknown := _unknown_keys(value, ["ground", "dirt", "rock"])
	if not unknown.is_empty():
		return unknown
	var normalized: Dictionary = {}
	for family in value:
		var variant = value[family]
		if not _is_integer_value(variant) or int(variant) < 0 or int(variant) > 2:
			return _error("VALUE_OUT_OF_RANGE", "texture_variants.%s must be an integer in 0..2" % family)
		normalized[family] = int(variant)
	return {"value": normalized}


func _normalized_road(params: Dictionary) -> Dictionary:
	var points := _normalized_points(params.get("points"), 2, 64, "points")
	if points.has("error"):
		return points
	var width := _positive_float(params.get("width"), "width")
	if width.has("error"):
		return width
	var shoulder := _nonnegative_float(params.get("shoulder_width", 2.0), "shoulder_width")
	if shoulder.has("error"):
		return shoulder
	var elevation_mode = params.get("elevation_mode", "follow_smooth")
	if not elevation_mode is String or not ["follow_smooth", "linear"].has(String(elevation_mode)):
		return _error("VALUE_OUT_OF_RANGE", "elevation_mode must be follow_smooth or linear")
	if params.has("start_height") != params.has("end_height"):
		return _error("INVALID_PARAMS", "start_height and end_height must be provided together")
	var max_grade := _positive_float(params.get("max_grade", 0.35), "max_grade")
	if max_grade.has("error") or max_grade.value > 1.0:
		return _error("VALUE_OUT_OF_RANGE", "max_grade must be greater than zero and at most 1")
	var passes = params.get("smoothing_passes", 4)
	if not _is_integer_value(passes) or int(passes) < 0 or int(passes) > 12:
		return _error("VALUE_OUT_OF_RANGE", "smoothing_passes must be an integer in 0..12")
	var paint_road = params.get("paint_road", true)
	if not paint_road is bool:
		return _error("INVALID_PARAMS", "paint_road must be a boolean")
	var falloff = params.get("falloff", "smooth")
	if not falloff is String or not FALLOFFS.has(String(falloff)):
		return _error("VALUE_OUT_OF_RANGE", "falloff must be smooth or linear")
	var settings := {
		"points": points.value,
		"width": width.value,
		"shoulder_width": shoulder.value,
		"elevation_mode": String(elevation_mode),
		"max_grade": max_grade.value,
		"smoothing_passes": int(passes),
		"paint_road": paint_road,
		"falloff": String(falloff),
	}
	if params.has("start_height"):
		var start := _finite_float(params.start_height, "start_height")
		var end := _finite_float(params.end_height, "end_height")
		if start.has("error"):
			return start
		if end.has("error"):
			return end
		settings.start_height = start.value
		settings.end_height = end.value
	return {"settings": settings}


func _normalized_paint_strokes(value: Variant) -> Dictionary:
	if not value is Array or value.is_empty() or value.size() > 64:
		return _error("INVALID_PARAMS", "strokes must be an array containing 1..64 entries")
	var result: Array = []
	for entry in value:
		if not entry is Dictionary:
			return _error("INVALID_PARAMS", "each paint stroke must be an object")
		var unknown := _unknown_keys(entry, ["points", "radius", "layer", "strength", "falloff"])
		if not unknown.is_empty():
			return unknown
		for required in ["points", "radius", "layer", "strength"]:
			if not entry.has(required):
				return _error("INVALID_PARAMS", "paint stroke.%s is required" % required)
		var points := _normalized_points(entry.points, 1, 64, "paint stroke.points")
		if points.has("error"):
			return points
		var radius := _positive_float(entry.radius, "paint stroke.radius")
		if radius.has("error"):
			return radius
		if not entry.layer is String or not PAINT_LAYERS.has(String(entry.layer)):
			return _error("VALUE_OUT_OF_RANGE", "paint stroke.layer must be one of: %s" % ", ".join(PAINT_LAYERS))
		var strength := _positive_float(entry.strength, "paint stroke.strength")
		if strength.has("error") or strength.value > 1.0:
			return _error("VALUE_OUT_OF_RANGE", "paint stroke.strength must be greater than zero and at most 1")
		var falloff = entry.get("falloff", "smooth")
		if not falloff is String or not FALLOFFS.has(String(falloff)):
			return _error("VALUE_OUT_OF_RANGE", "paint stroke.falloff must be smooth or linear")
		var normalized_layer := String(entry.layer)
		if normalized_layer == "dirt" or normalized_layer == "sand":
			normalized_layer = "road"
		result.append({
			"points": points.value,
			"radius": radius.value,
			"layer": normalized_layer,
			"strength": strength.value,
			"falloff": String(falloff),
		})
	return {"items": result}


func _normalized_points(value: Variant, minimum: int, maximum: int, field: String) -> Dictionary:
	if not value is Array or value.size() < minimum or value.size() > maximum:
		return _error("INVALID_PARAMS", "%s must contain %d..%d points" % [field, minimum, maximum])
	var result: Array = []
	for index in value.size():
		var entry = value[index]
		if not entry is Dictionary:
			return _error("INVALID_PARAMS", "%s entries must be objects" % field)
		var unknown := _unknown_keys(entry, ["x", "z"])
		if not unknown.is_empty():
			return unknown
		if not entry.has("x") or not entry.has("z"):
			return _error("INVALID_PARAMS", "%s entries require x and z" % field)
		var x := _finite_float(entry.x, "%s.x" % field)
		var z := _finite_float(entry.z, "%s.z" % field)
		if x.has("error"):
			return x
		if z.has("error"):
			return z
		var point := Vector2(x.value, z.value)
		if not result.is_empty() and point.is_equal_approx(result[-1]):
			return _error("INVALID_PARAMS", "%s cannot contain consecutive duplicate points" % field)
		result.append(point)
	return {"value": result}


func _normalized_custom_textures(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _error("INVALID_PARAMS", "custom_textures must be an object")
	var normalized := {}
	var unknown_layers := _unknown_keys(value, ["ground", "road", "rock", "snow"])
	if not unknown_layers.is_empty():
		return unknown_layers
	for layer in value:
		var maps = value[layer]
		if not maps is Dictionary:
			return _error("INVALID_PARAMS", "custom_textures.%s must be an object" % layer)
		var unknown_maps := _unknown_keys(maps, ["albedo", "normal", "roughness"])
		if not unknown_maps.is_empty():
			return unknown_maps
		var normalized_maps := {}
		for texture_kind in maps:
			var path = maps[texture_kind]
			if not path is String or not String(path).begins_with("res://"):
				return _error("INVALID_PARAMS", "custom texture paths must be res:// strings")
			if not ResourceLoader.exists(String(path)) or not load(String(path)) is Texture2D:
				return _error("terrain_tools.INVALID_TEXTURE", "Custom texture is missing or is not Texture2D: %s" % path)
			normalized_maps[String(texture_kind)] = String(path)
		normalized[String(layer)] = normalized_maps
	return {"value": normalized}


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


func _normalized_landforms(value: Variant) -> Dictionary:
	if not value is Array or value.is_empty() or value.size() > 32:
		return _error("INVALID_PARAMS", "features must be an array containing 1..32 entries")
	var result: Array = []
	for entry in value:
		if not entry is Dictionary:
			return _error("INVALID_PARAMS", "each landform feature must be an object")
		var unknown := _unknown_keys(entry, ["type", "points", "width", "falloff_width", "profile", "height", "roughness", "scale", "seed"])
		if not unknown.is_empty():
			return unknown
		for required in ["type", "points", "width", "falloff_width", "profile", "height"]:
			if not entry.has(required):
				return _error("INVALID_PARAMS", "landform feature.%s is required" % required)
		var kind = entry.type
		if not kind is String or not ["ridge", "valley", "plateau"].has(String(kind)):
			return _error("VALUE_OUT_OF_RANGE", "landform feature.type must be ridge, valley, or plateau")
		var points := _normalized_points(entry.points, 1, 64, "landform feature.points")
		if points.has("error"):
			return points
		var width := _positive_float(entry.width, "landform feature.width")
		var falloff_width := _nonnegative_float(entry.falloff_width, "landform feature.falloff_width")
		var height := _finite_float(entry.height, "landform feature.height")
		var roughness := _nonnegative_float(entry.get("roughness", 0.0), "landform feature.roughness")
		var scale := _positive_float(entry.get("scale", 1.0), "landform feature.scale")
		for checked in [width, falloff_width, height, roughness, scale]:
			if checked.has("error"):
				return checked
		var profile = entry.profile
		if not profile is String or not ["smooth", "sharp", "terraced"].has(String(profile)):
			return _error("VALUE_OUT_OF_RANGE", "landform feature.profile must be smooth, sharp, or terraced")
		var seed = entry.get("seed", 1337)
		if not _is_signed_seed(seed):
			return _error("VALUE_OUT_OF_RANGE", "landform feature.seed must be a signed 32-bit integer")
		result.append({
			"type": String(kind), "points": points.value, "width": width.value,
			"falloff_width": falloff_width.value, "profile": String(profile),
			"height": height.value, "roughness": roughness.value,
			"scale": scale.value, "seed": int(seed),
		})
	return {"items": result}


func _normalized_erosion(params: Dictionary) -> Dictionary:
	var algorithm = params.get("algorithm", "thermal")
	if not algorithm is String or not ["thermal", "hydraulic", "thermal_natural", "hydraulic_natural"].has(String(algorithm)):
		return _error("VALUE_OUT_OF_RANGE", "algorithm must be thermal, hydraulic, thermal_natural, or hydraulic_natural")
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
	var preset = params.get("preset", "balanced")
	if not preset is String or not ["soft", "balanced", "rugged"].has(String(preset)):
		return _error("VALUE_OUT_OF_RANGE", "preset must be soft, balanced, or rugged")
	var preset_values: Dictionary = {
		"soft": {"rain": 0.55, "erosion": 0.22, "deposition": 0.42, "evaporation": 0.12, "talus": 0.22},
		"balanced": {"rain": 0.8, "erosion": 0.4, "deposition": 0.3, "evaporation": 0.08, "talus": 0.15},
		"rugged": {"rain": 1.0, "erosion": 0.58, "deposition": 0.2, "evaporation": 0.05, "talus": 0.1},
	}[String(preset)]
	var settings := {"algorithm": String(algorithm), "iterations": int(iterations), "intensity": intensity.value, "seed": int(seed), "preset": String(preset)}
	for key in ["rain", "erosion", "deposition", "evaporation", "talus"]:
		var checked := _nonnegative_float(params.get(key, preset_values[key]), key)
		if checked.has("error"):
			return checked
		if checked.value > 1.0:
			return _error("VALUE_OUT_OF_RANGE", "%s must be at most 1" % key)
		settings[key] = checked.value
	var preservation := _nonnegative_float(params.get("ridge_preservation", 0.0), "ridge_preservation")
	if preservation.has("error") or preservation.value > 1.0:
		return _error("VALUE_OUT_OF_RANGE", "ridge_preservation must be in 0..1")
	settings.ridge_preservation = preservation.value
	if params.has("region"):
		var region = params.region
		if not region is Dictionary:
			return _error("INVALID_PARAMS", "region must be an object")
		var unknown_region := _unknown_keys(region, ["center_x", "center_z", "points", "radius"])
		if not unknown_region.is_empty():
			return unknown_region
		if not region.has("radius"):
			return _error("INVALID_PARAMS", "region.radius is required")
		var rr := _positive_float(region.radius, "region.radius")
		if rr.has("error"):
			return rr
		var has_points: bool = region.has("points")
		var has_center: bool = region.has("center_x") or region.has("center_z")
		if has_points == has_center:
			return _error("INVALID_PARAMS", "region must contain either points or center_x/center_z")
		if has_points:
			var points := _normalized_points(region.points, 2, 64, "region.points")
			if points.has("error"):
				return points
			settings.region = {"points": points.value, "radius": rr.value}
		else:
			if not region.has("center_x") or not region.has("center_z"):
				return _error("INVALID_PARAMS", "region.center_x and region.center_z are required together")
			var rx := _finite_float(region.center_x, "region.center_x")
			var rz := _finite_float(region.center_z, "region.center_z")
			for checked in [rx, rz]:
				if checked.has("error"):
					return checked
			settings.region = {"center_x": rx.value, "center_z": rz.value, "radius": rr.value}
	return {"settings": settings}


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
	if version == PREVIOUS_FORMAT_VERSION:
		if not metadata.get("data") is Resource:
			return _error("terrain_tools.UNSUPPORTED_FORMAT", "Terrain v2 metadata has no TerrainData resource")
		var previous: Resource = metadata.data
		if previous.get_script() != TerrainData:
			return _error("terrain_tools.UNSUPPORTED_FORMAT", "Terrain v2 data is invalid or unsupported")
		var previous_checked := _normalized_params(previous.params)
		if previous_checked.has("error") or not _valid_previous_data(previous):
			return _error("terrain_tools.UNSUPPORTED_FORMAT", "Terrain v2 parameters or arrays are invalid")
		var upgraded := _upgrade_previous_data(previous, previous_checked.params)
		var previous_height_error := _validate_height_data(upgraded)
		if not previous_height_error.is_empty():
			return _error("terrain_tools.UNSUPPORTED_FORMAT", "Terrain v2 heights are invalid")
		return {"format_version": FORMAT_VERSION, "params": upgraded.params, "data": upgraded}
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


func _valid_previous_data(data: Resource) -> bool:
	var size := int(data.params.get("size", 0))
	var count := size * size
	if not data.base_ready or size < MIN_SIZE:
		return false
	if data.base_heights.size() != count or data.edit_offsets.size() != count or data.holes.size() != count:
		return false
	for index in count:
		if not is_finite(data.base_heights[index]) or not is_finite(data.edit_offsets[index]):
			return false
		if data.holes[index] != 0 and data.holes[index] != 1:
			return false
	return true


func _upgrade_previous_data(previous: Resource, normalized_params: Dictionary) -> Resource:
	var upgraded := TerrainData.new()
	upgraded.initialize(normalized_params)
	upgraded.base_heights = previous.base_heights.duplicate()
	upgraded.edit_offsets = previous.edit_offsets.duplicate()
	upgraded.holes = previous.holes.duplicate()
	upgraded.base_ready = previous.base_ready
	return upgraded


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


func _nonnegative_float(value: Variant, field: String) -> Dictionary:
	var checked := _finite_float(value, field)
	if checked.has("error"):
		return checked
	if checked.value < 0.0:
		return _error("VALUE_OUT_OF_RANGE", "%s must be zero or greater" % field)
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
