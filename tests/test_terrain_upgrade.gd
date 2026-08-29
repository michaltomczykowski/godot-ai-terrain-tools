@tool
extends McpTestSuite

## Focused contract coverage for the live terrain authoring upgrade.
##
## These tests intentionally exercise the handler's synchronous validation and
## small-grid data jobs.  A small grid keeps the direct private job calls below
## under the deferred frame-yield threshold; the live promoted tools remain
## deferred and are covered by the integration smoke harness.

const TerrainHandler := preload("res://addons/godot_ai_terrain_tools/terrain_handler.gd")
const TerrainData := preload("res://addons/godot_ai_terrain_tools/terrain_data.gd")
const TerrainBuildJob := preload("res://addons/godot_ai_terrain_tools/terrain_build_job.gd")
const TerrainPlugin := preload("res://addons/godot_ai_terrain_tools/plugin.gd")

const META_KEY := &"godot_ai_terrain_tools"
const FORMAT_VERSION := 3

var _handler: TerrainHandler


func suite_name() -> String:
	return "terrain_upgrade"


func suite_setup(_ctx: Dictionary) -> void:
	_handler = TerrainHandler.new()
	TerrainHandler.reset_busy()


func suite_teardown() -> void:
	TerrainHandler.reset_busy()


func _normalized(params: Dictionary = {}) -> Dictionary:
	return _handler._normalized_params(params)


func _new_data(params: Dictionary = {}) -> TerrainData:
	var checked := _normalized(params)
	assert_has_key(checked, "params")
	var data := TerrainData.new()
	data.initialize(checked.params)
	return data


func _build(data: TerrainData) -> Dictionary:
	var job := TerrainBuildJob.new(data)
	while not job.step(1000000):
		pass
	return job.result()


func _mesh_arrays(built: Dictionary) -> Array:
	var mesh := built.get("mesh") as Mesh
	return mesh.surface_get_arrays(0) if mesh != null and mesh.get_surface_count() > 0 else []


func _schema_property(spec: McpCustomToolSpec, property_name: String) -> Dictionary:
	var properties: Dictionary = spec.params_schema.get("properties", {})
	var value: Variant = properties.get(property_name, {})
	return value if value is Dictionary else {}


func _assert_tool_contract(spec: McpCustomToolSpec, required: Array, should_promote: bool = true) -> void:
	assert_eq(spec.promoted, should_promote)
	assert_true(spec.requires_writable)
	assert_true(spec.undoable)
	assert_true(spec.deferred)
	assert_eq(spec.timeout_ms, 30000)
	for name_value in required:
		assert_true((spec.params_schema.required as Array).has(String(name_value)))
	assert_eq(spec.validate().size(), 0)


## ----- TerrainData v3 persistence and migration -----

func test_v3_data_allocates_valid_semantic_paint_state_and_snapshots_exactly() -> void:
	var data := _new_data({"size": 8, "seed": 7001})
	_build(data)
	assert_eq(TerrainData.FORMAT_VERSION, FORMAT_VERSION)
	assert_eq(data.format_version, FORMAT_VERSION)
	assert_eq(data.paint_weights.size(), 64)
	assert_eq(data.paint_coverage.size(), 64)
	assert_true(data.is_valid())
	for index in data.paint_weights.size():
		var weights: Color = data.paint_weights[index]
		assert_true(is_finite(weights.r) and is_finite(weights.g) and is_finite(weights.b) and is_finite(weights.a))
		assert_true(weights.r >= 0.0 and weights.g >= 0.0 and weights.b >= 0.0 and weights.a >= 0.0)
		assert_true(is_zero_approx(data.paint_coverage[index]))
	var initial_weight: Color = data.paint_weights[10]
	var baseline := data.snapshot() as TerrainData
	data.paint_weights[10] = Color(0.0, 1.0, 0.0, 0.0)
	data.paint_coverage[10] = 0.75
	assert_true(data.has_modifications())
	assert_eq(baseline.paint_weights[10], initial_weight)
	assert_eq(baseline.paint_coverage[10], 0.0)
	var copy := data.snapshot() as TerrainData
	assert_eq(copy.paint_weights, data.paint_weights)
	assert_eq(copy.paint_coverage, data.paint_coverage)
	data.paint_weights[10] = Color(1.0, 0.0, 0.0, 0.0)
	data.paint_coverage[10] = 1.0
	assert_eq(copy.paint_weights[10], Color(0.0, 1.0, 0.0, 0.0))
	assert_eq(copy.paint_coverage[10], 0.75)


func test_v3_validation_rejects_invalid_paint_weights_and_coverage() -> void:
	var data := _new_data({"size": 6, "seed": 7002})
	_build(data)
	data.paint_weights[0] = Color(-0.1, 0.0, 0.0, 0.0)
	assert_false(data.is_valid())
	data.paint_weights[0] = Color(0.0, 0.0, 0.0, 0.0)
	data.paint_coverage[0] = 1.1
	assert_false(data.is_valid())
	data.paint_coverage[0] = NAN
	assert_false(data.is_valid())
	data.paint_coverage[0] = 0.0
	data.paint_weights[0] = Color(INF, 0.0, 0.0, 0.0)
	assert_false(data.is_valid())


func test_v3_data_paint_arrays_survive_packed_scene_save_and_load() -> void:
	var scene_root := Node3D.new()
	scene_root.name = "TerrainUpgradePersistenceRoot"
	var container := Node3D.new()
	container.name = "Terrain"
	scene_root.add_child(container)
	container.owner = scene_root
	var data := _new_data({"size": 6, "seed": 7003, "render_mode": "procedural"})
	_build(data)
	data.paint_weights[7] = Color(0.0, 1.0, 0.0, 0.0)
	data.paint_coverage[7] = 1.0
	data.paint_weights[14] = Color(0.0, 0.0, 1.0, 0.5)
	data.paint_coverage[14] = 0.5
	container.set_meta(META_KEY, _handler._metadata(data))
	var packed := PackedScene.new()
	assert_eq(packed.pack(scene_root), OK)
	var path := "user://terrain_tools_upgrade_v3_persistence.tscn"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	assert_eq(ResourceSaver.save(packed, path), OK)
	var loaded := ResourceLoader.load(path) as PackedScene
	assert_true(loaded != null)
	var loaded_root := loaded.instantiate()
	track(loaded_root)
	var loaded_data: Variant = loaded_root.get_node("Terrain").get_meta(META_KEY).get("data")
	assert_true(loaded_data is TerrainData)
	assert_true((loaded_data as TerrainData).is_valid())
	assert_eq((loaded_data as TerrainData).paint_weights, data.paint_weights)
	assert_eq((loaded_data as TerrainData).paint_coverage, data.paint_coverage)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	scene_root.free()


func test_v2_state_migrates_to_v3_without_losing_heights_or_holes() -> void:
	var container := Node3D.new()
	track(container)
	var params: Dictionary = _normalized({"size": 6, "seed": 7004}).params
	var legacy := TerrainData.new()
	legacy.initialize(params)
	legacy.format_version = 2
	_build(legacy)
	legacy.edit_offsets[8] = 1.75
	legacy.holes[14] = 1
	var old_heights := legacy.final_heights()
	var old_holes := legacy.holes.duplicate()
	container.set_meta(META_KEY, {
		"format_version": 2,
		"params": params,
		"data": legacy,
	})
	var state := _handler._managed_state(container)
	assert_has_key(state, "data")
	assert_true(state.data is TerrainData)
	var migrated: TerrainData = state.data
	assert_eq(migrated.format_version, FORMAT_VERSION)
	assert_eq(migrated.final_heights(), old_heights)
	assert_eq(migrated.holes, old_holes)
	assert_eq(migrated.paint_weights.size(), 36)
	assert_eq(migrated.paint_coverage.size(), 36)
	for coverage in migrated.paint_coverage:
		assert_true(is_zero_approx(coverage))


## ----- road validation and deterministic baked grading -----

func _road_request() -> Dictionary:
	return {
		"path": "/Terrain",
		"points": [{"x": -5.0, "z": 1.0}, {"x": 5.0, "z": 1.0}],
		"width": 5.0,
		"shoulder_width": 1.5,
		"elevation_mode": "linear",
		"start_height": -1.0,
		"end_height": 1.0,
		"max_grade": 0.35,
	}


func test_road_normalization_rejects_invalid_paths_and_infeasible_settings() -> void:
	for request in [
		{},
		{"path": 42, "points": [{"x": 0.0, "z": 0.0}, {"x": 1.0, "z": 1.0}], "width": 2.0},
		{"path": "/Terrain", "points": [], "width": 2.0},
		{"path": "/Terrain", "points": [{"x": 0.0, "z": 0.0}], "width": 2.0},
		{"path": "/Terrain", "points": [{"x": 0.0, "z": 0.0}, {"x": 1.0, "z": 1.0}], "width": 0.0},
		{"path": "/Terrain", "points": [{"x": 0.0, "z": 0.0}, {"x": 1.0, "z": 1.0}], "width": 2.0, "elevation_mode": "arc"},
		{"path": "/Terrain", "points": [{"x": 0.0, "z": 0.0}, {"x": 1.0, "z": 1.0}], "width": 2.0, "start_height": 1.0},
		{"path": "/Terrain", "points": [{"x": 0.0, "z": 0.0}, {"x": 1.0, "z": 1.0}], "width": 2.0, "max_grade": 0.0},
	]:
		assert_is_error(_handler.road(request, null))
	var normalized := _handler._normalized_road(_road_request())
	assert_has_key(normalized, "settings")
	assert_eq(normalized.settings.width, 5.0)
	assert_eq(normalized.settings.elevation_mode, "linear")
	assert_eq(normalized.settings.points.size(), 2)


func test_road_grading_is_deterministic_flat_across_corridor_and_paints_road() -> void:
	var first := _new_data({"size": 12, "seed": 7010})
	var second := _new_data({"size": 12, "seed": 7010})
	_build(first)
	_build(second)
	var normalized := _handler._normalized_road(_road_request())
	assert_has_key(normalized, "settings")
	var first_result: Variant = _handler._apply_road_sync(first, normalized.settings)
	var second_result: Variant = _handler._apply_road_sync(second, normalized.settings)
	assert_true(first_result is Dictionary)
	assert_true(second_result is Dictionary)
	assert_eq(first.final_heights(), second.final_heights())
	assert_eq(first.paint_weights, second.paint_weights)
	assert_eq(first.paint_coverage, second.paint_coverage)
	assert_gt((first_result as Dictionary).get("affected_vertices", 0), 0)
	var center_row := 6 * 12 + 6
	var weights := first.paint_weights
	assert_gt(first.paint_coverage[center_row], 0.0)
	assert_gt(weights[center_row].g, weights[center_row].r)
	for x in range(3, 9):
		var center_height := first.final_heights()[6 * 12 + x]
		var across_a := first.final_heights()[5 * 12 + x]
		var across_b := first.final_heights()[7 * 12 + x]
		assert_true(absf(center_height - across_a) < 0.15,
			"road corridor must be approximately flat across its width")
		assert_true(absf(center_height - across_b) < 0.15,
			"road corridor must be approximately flat across its width")
	for index in first.final_heights().size():
		assert_true(is_finite(first.final_heights()[index]))


func test_road_skips_holes_and_clips_outside_terrain() -> void:
	var data := _new_data({"size": 10, "seed": 7011})
	_build(data)
	data.holes[5 * 10 + 5] = 1
	var hole_height := data.final_heights()[55]
	var request := _road_request()
	request.points = [{"x": -20.0, "z": 1.0}, {"x": 20.0, "z": 1.0}]
	request.width = 3.0
	var normalized := _handler._normalized_road(request)
	assert_has_key(normalized, "settings")
	var result: Variant = _handler._apply_road_sync(data, normalized.settings)
	assert_true(result is Dictionary)
	assert_true(is_equal_approx(data.final_heights()[55], hole_height),
		"road grading must not modify masked vertices")
	assert_true(data.is_valid())


func test_road_rejects_infeasible_grade_before_mutating_data() -> void:
	var data := _new_data({"size": 10, "seed": 7012})
	_build(data)
	var before_heights := data.final_heights()
	var before_weights := data.paint_weights.duplicate()
	var request := _road_request()
	request.start_height = -5.0
	request.end_height = 5.0
	request.max_grade = 0.1
	var normalized := _handler._normalized_road(request)
	assert_has_key(normalized, "settings")
	var result: Variant = _handler._apply_road_sync(data, normalized.settings)
	assert_is_error(result)
	assert_eq(data.final_heights(), before_heights)
	assert_eq(data.paint_weights, before_weights)


## ----- ordered semantic paint strokes -----

func _paint_strokes() -> Array:
	return [{
		"points": [{"x": -5.0, "z": 1.0}, {"x": 1.0, "z": 1.0}, {"x": 5.0, "z": 1.0}],
		"radius": 2.5,
		"strength": 1.0,
		"falloff": "smooth",
		"layer": "road",
	}]


func test_paint_normalization_supports_all_layers_polyline_and_auto() -> void:
	for layer in ["ground", "road", "dirt", "sand", "rock", "snow", "auto"]:
		var strokes := [{
			"points": [{"x": 0.0, "z": 0.0}],
			"radius": 1.0,
			"strength": 0.5,
			"falloff": "linear",
			"layer": layer,
		}]
		var normalized := _handler._normalized_paint_strokes(strokes)
		assert_has_key(normalized, "items")
		var expected_layer: String = "road" if layer == "dirt" or layer == "sand" else layer
		assert_eq(normalized.items[0].layer, expected_layer)
	assert_eq(_handler._normalized_paint_strokes(_paint_strokes()).items[0].points.size(), 3)
	for invalid in [
		[],
		[{"points": [], "radius": 1.0, "strength": 1.0, "layer": "road"}],
		[{"points": [{"x": 0.0, "z": 0.0}], "radius": 0.0, "strength": 1.0, "layer": "road"}],
		[{"points": [{"x": 0.0, "z": 0.0}], "radius": 1.0, "strength": 1.0, "layer": "mud"}],
		[{"points": [{"x": 0.0, "z": 0.0}], "radius": 1.0, "strength": NAN, "layer": "road"}],
	]:
		assert_is_error(_handler._normalized_paint_strokes(invalid))


func test_paint_circle_polyline_falloff_and_ordered_overlap_are_persistent() -> void:
	var data := _new_data({"size": 12, "seed": 7020})
	_build(data)
	var normalized := _handler._normalized_paint_strokes(_paint_strokes())
	assert_has_key(normalized, "items")
	var result: Variant = _handler._apply_paint_sync(data, normalized.items)
	assert_true(result is Dictionary)
	var center := 6 * 12 + 6
	assert_gt(data.paint_coverage[center], 0.0)
	assert_gt(data.paint_weights[center].g, 0.0)
	assert_gt((result as Dictionary).get("affected_vertices", 0), 0)
	var endpoint := 6 * 12 + 3
	assert_gt(data.paint_coverage[endpoint], 0.0,
		"a polyline must paint its endpoints, not only the first circle")
	var untouched := 0
	for coverage in data.paint_coverage:
		if is_zero_approx(coverage):
			untouched += 1
	assert_gt(untouched, 0)

	var overlap := _handler._normalized_paint_strokes([
		{"points": [{"x": 0.5, "z": 0.5}], "radius": 1.5, "strength": 1.0, "falloff": "linear", "layer": "road"},
		{"points": [{"x": 0.5, "z": 0.5}], "radius": 1.5, "strength": 1.0, "falloff": "linear", "layer": "snow"},
	])
	var overlapped := _new_data({"size": 8, "seed": 7021})
	_build(overlapped)
	assert_true(_handler._apply_paint_sync(overlapped, overlap.items) is Dictionary)
	var overlap_center := 4 * 8 + 4
	assert_gt(overlapped.paint_weights[overlap_center].a, overlapped.paint_weights[overlap_center].g,
		"ordered strokes must let the later semantic layer win")


func test_paint_auto_restores_automatic_classification_and_falloff_shapes() -> void:
	var smooth_data := _new_data({"size": 8, "seed": 7022})
	var linear_data := _new_data({"size": 8, "seed": 7022})
	_build(smooth_data)
	_build(linear_data)
	var smooth := _handler._normalized_paint_strokes([{
		"points": [{"x": 0.5, "z": 0.5}], "radius": 2.5, "strength": 1.0, "falloff": "smooth", "layer": "rock",
	}])
	var linear := _handler._normalized_paint_strokes([{
		"points": [{"x": 0.5, "z": 0.5}], "radius": 2.5, "strength": 1.0, "falloff": "linear", "layer": "rock",
	}])
	assert_true(_handler._apply_paint_sync(smooth_data, smooth.items) is Dictionary)
	assert_true(_handler._apply_paint_sync(linear_data, linear.items) is Dictionary)
	var edge := 4 * 8 + 4
	assert_ne(smooth_data.paint_coverage[edge], linear_data.paint_coverage[edge],
		"smooth and linear falloffs must produce different edge weights")
	var auto := _handler._normalized_paint_strokes([{
		"points": [{"x": 0.5, "z": 0.5}], "radius": 2.5, "strength": 1.0, "falloff": "smooth", "layer": "auto",
	}])
	assert_true(_handler._apply_paint_sync(smooth_data, auto.items) is Dictionary)
	for coverage in smooth_data.paint_coverage:
		assert_true(is_zero_approx(coverage), "auto painting must restore automatic classification")
	assert_true(smooth_data.is_valid())


func test_paint_skips_masked_holes() -> void:
	var data := _new_data({"size": 8, "seed": 7023})
	_build(data)
	var center := 4 * 8 + 4
	var initial_weights: Color = data.paint_weights[center]
	data.holes[center] = 1
	var normalized := _handler._normalized_paint_strokes([{
		"points": [{"x": 1.0, "z": 1.0}], "radius": 2.0, "strength": 1.0, "falloff": "linear", "layer": "road",
	}])
	assert_has_key(normalized, "items")
	assert_true(_handler._apply_paint_sync(data, normalized.items) is Dictionary)
	assert_true(is_zero_approx(data.paint_coverage[center]))
	assert_eq(data.paint_weights[center], initial_weights)


## ----- material modes and promoted public schemas -----

func test_material_modes_normalize_and_keep_geometry_unchanged() -> void:
	var baseline := _new_data({"size": 8, "seed": 7030, "render_mode": "procedural"})
	var baseline_built := _build(baseline)
	var baseline_arrays := _mesh_arrays(baseline_built)
	for mode in ["procedural", "bundled", "custom"]:
		var options: Dictionary = {"size": 8, "seed": 7030, "render_mode": mode, "texture_scale": 6.0}
		if mode == "custom":
			options.custom_textures = {}
		var checked := _normalized(options)
		assert_has_key(checked, "params")
		assert_eq(checked.params.render_mode, mode)
		assert_eq(checked.params.texture_scale, 6.0)
		var data := _new_data(options)
		var built := _build(data)
		var arrays := _mesh_arrays(built)
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		assert_eq(colors.size(), 64)
		for color in colors:
			assert_true(is_finite(color.r) and is_finite(color.g) and is_finite(color.b) and is_finite(color.a))
			assert_true(absf(color.r + color.g + color.b + color.a - 1.0) < 0.01,
				"semantic vertex weights must remain normalized")
		assert_eq(arrays[Mesh.ARRAY_VERTEX], baseline_arrays[Mesh.ARRAY_VERTEX],
			"material mode must not alter terrain geometry")
		assert_eq(arrays[Mesh.ARRAY_INDEX], baseline_arrays[Mesh.ARRAY_INDEX],
			"material mode must not alter terrain topology")
		var material := (built.mesh as Mesh).surface_get_material(0)
		assert_true(material is ShaderMaterial,
			"terrain material modes must use the semantic shader material")
		assert_true((material as ShaderMaterial).shader != null)
		if mode != "procedural":
			for layer in ["ground", "road", "rock", "snow"]:
				for map_name in ["albedo", "normal", "roughness"]:
					var texture: Variant = (material as ShaderMaterial).get_shader_parameter("%s_%s" % [layer, map_name])
					assert_true(texture is Texture2D,
						"bundled/custom mode must resolve %s %s texture" % [layer, map_name])


func test_material_only_data_replacement_preserves_heights_holes_and_paint() -> void:
	var original := _new_data({"size": 8, "seed": 7031, "render_mode": "procedural"})
	_build(original)
	original.edit_offsets[9] = 1.25
	original.holes[18] = 1
	original.paint_weights[27] = Color(0.0, 1.0, 0.0, 0.0)
	original.paint_coverage[27] = 0.8
	var changed: Dictionary = _normalized({
		"size": 8,
		"seed": 7031,
		"render_mode": "bundled",
		"texture_scale": 3.0,
	}).params
	var updated: TerrainData = _handler._regenerated_material_data(changed, original) as TerrainData
	assert_eq(updated.params.render_mode, "bundled")
	assert_eq(updated.params.texture_scale, 3.0)
	assert_eq(updated.base_heights, original.base_heights)
	assert_eq(updated.edit_offsets, original.edit_offsets)
	assert_eq(updated.holes, original.holes)
	assert_eq(updated.paint_weights, original.paint_weights)
	assert_eq(updated.paint_coverage, original.paint_coverage)


func test_material_normalization_rejects_bad_mode_scale_and_custom_paths() -> void:
	for invalid in [
		{"render_mode": "vertex"},
		{"render_mode": 3},
		{"texture_scale": 0.0},
		{"texture_scale": INF},
		{"render_mode": "custom", "custom_textures": "bad"},
		{"render_mode": "custom", "custom_textures": {"road": {"albedo": "user://not-res"}}},
	]:
		assert_is_error(_normalized(invalid))


func test_road_paint_and_material_specs_publish_complete_contracts() -> void:
	var plugin := track(TerrainPlugin.new())
	var road: McpCustomToolSpec = plugin._road_spec()
	var paint: McpCustomToolSpec = plugin._paint_spec()
	var material: McpCustomToolSpec = plugin._material_spec()
	assert_eq(road.name, "terrain_road")
	assert_eq(paint.name, "terrain_paint")
	assert_eq(material.name, "terrain_material")
	assert_eq(road.method, &"road")
	assert_eq(paint.method, &"paint")
	assert_eq(material.method, &"material")
	_assert_tool_contract(road, ["path", "points", "width"])
	_assert_tool_contract(paint, ["path", "strokes"])
	_assert_tool_contract(material, ["path"], false)
	var road_properties := road.params_schema.properties as Dictionary
	var elevation := _schema_property(road, "elevation_mode")
	assert_eq(elevation.enum, ["follow_smooth", "linear"])
	assert_has_key(road_properties, "max_grade")
	assert_has_key(road_properties, "shoulder_width")
	var paint_item := (_schema_property(paint, "strokes").get("items", {}) as Dictionary)
	var paint_properties := paint_item.get("properties", {}) as Dictionary
	assert_eq((paint_properties.get("layer", {}) as Dictionary).enum, ["ground", "road", "dirt", "sand", "rock", "snow", "auto"])
	assert_eq((paint_properties.get("falloff", {}) as Dictionary).enum, ["smooth", "linear"])
	var material_mode := _schema_property(material, "render_mode")
	assert_eq(material_mode.enum, ["procedural", "bundled", "custom"])
	assert_has_key(material.params_schema.properties, "texture_scale")
	assert_has_key(material.params_schema.properties, "custom_textures")
