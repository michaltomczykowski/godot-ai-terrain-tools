@tool
extends McpTestSuite

## Contract tests for the precision terrain upgrade.
##
## The upgrade deliberately keeps TerrainData at format v3.  These tests
## exercise the public normalization contracts and the small synchronous jobs
## used by the deferred editor handlers.  The 256x256 test is intentionally a
## single smoke test: it checks the full-resolution topology without making
## every test pay the cost of constructing a large terrain.

const TerrainHandler := preload("res://addons/godot_ai_terrain_tools/terrain_handler.gd")
const TerrainData := preload("res://addons/godot_ai_terrain_tools/terrain_data.gd")
const TerrainBuildJob := preload("res://addons/godot_ai_terrain_tools/terrain_build_job.gd")
const TerrainErosionJob := preload("res://addons/godot_ai_terrain_tools/terrain_erosion_job.gd")
const TerrainPlugin := preload("res://addons/godot_ai_terrain_tools/plugin.gd")

var _handler: TerrainHandler


func suite_name() -> String:
	return "terrain_precision"


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


func _is_error(value: Variant) -> bool:
	return value is Dictionary and (value as Dictionary).has("error")


func _landform_features() -> Array:
	return [
		{
			"type": "ridge",
			"points": [{"x": -14.0, "z": -8.0}, {"x": 0.0, "z": 0.0}, {"x": 14.0, "z": 8.0}],
			"width": 7.0,
			"falloff_width": 3.0,
			"profile": "sharp",
			"height": 4.0,
			"roughness": 0.12,
			"scale": 1.0,
			"seed": 4242,
		},
		{
			"type": "valley",
			"points": [{"x": -10.0, "z": 10.0}],
			"width": 9.0,
			"falloff_width": 4.0,
			"profile": "smooth",
			"height": -2.0,
			"roughness": 0.0,
			"scale": 1.0,
			"seed": 4243,
		},
		{
			"type": "plateau",
			"points": [{"x": 11.0, "z": -11.0}],
			"width": 6.0,
			"falloff_width": 2.0,
			"profile": "terraced",
			"height": 2.5,
			"roughness": 0.05,
			"scale": 1.25,
			"seed": 4244,
		},
	]


## ----- resolution and collision parity -----

func test_max_size_256_builds_expected_mesh_and_heightfield_collision() -> void:
	assert_eq(TerrainHandler.MAX_SIZE, 256,
		"the optional high-precision terrain ceiling must be 256 samples")
	var defaults := _normalized({})
	assert_has_key(defaults, "params")
	assert_eq(defaults.params.size, 48,
		"raising the ceiling must not change the default terrain resolution")
	var checked := _normalized({"size": 256, "seed": 9101, "generate_collision": true})
	assert_has_key(checked, "params")
	var data := _new_data(checked.params)
	var built := _build(data)
	assert_eq(built.vertices, 65536)
	assert_eq(built.triangle_count, 130050)
	assert_eq((built.collision_heights as PackedFloat32Array).size(), 65536)
	var mesh := built.mesh as Mesh
	assert_true(mesh != null and mesh.get_surface_count() == 1)
	var arrays: Array = mesh.surface_get_arrays(0)
	assert_eq((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 65536)
	assert_eq((arrays[Mesh.ARRAY_COLOR] as PackedColorArray).size(), 65536)
	var shape_children: Array[Node] = _handler._make_children(built, true)
	assert_eq(shape_children.size(), 2)
	var collision_shape := (shape_children[1] as StaticBody3D).get_child(0) as CollisionShape3D
	assert_true(collision_shape.shape is HeightMapShape3D)
	var shape := collision_shape.shape as HeightMapShape3D
	assert_eq(shape.map_width, 256)
	assert_eq(shape.map_depth, 256)
	assert_eq((shape.map_data as PackedFloat32Array).size(), 65536)


## ----- localized landforms -----

func test_landform_normalization_supports_batch_profiles_and_is_deterministic() -> void:
	var features := _landform_features()
	var first: Variant = _handler._normalized_landforms(features)
	var second: Variant = _handler._normalized_landforms(features.duplicate(true))
	assert_false(_is_error(first), "ridge/valley/plateau feature batch should normalize")
	assert_false(_is_error(second), "normalization should be repeatable")
	assert_true(first is Dictionary and second is Dictionary)
	var first_dict := first as Dictionary
	var second_dict := second as Dictionary
	var first_items: Array = first_dict.items
	var second_items: Array = second_dict.items
	assert_eq(first_items.size(), 3)
	assert_eq(second_items.size(), 3)
	assert_eq(first_items, second_items, "feature normalization must preserve deterministic order and roughness seed")
	assert_eq(String(first_items[0].get("type", first_items[0].get("mode", ""))), "ridge")
	assert_eq(String(first_items[1].get("type", first_items[1].get("mode", ""))), "valley")
	assert_eq(String(first_items[2].get("type", first_items[2].get("mode", ""))), "plateau")
	assert_eq(first_items[0].profile, "sharp")
	assert_eq(first_items[1].profile, "smooth")
	assert_eq(first_items[2].profile, "terraced")
	var too_many: Array = []
	for index in range(33):
		too_many.append(features[index % features.size()].duplicate(true))
	for bad in [
		[],
		too_many,
		[{"type": "volcano", "points": [{"x": 0.0, "z": 0.0}], "width": 2.0, "falloff_width": 1.0, "profile": "smooth", "height": 1.0}],
		[{"type": "ridge", "points": [], "width": 2.0, "falloff_width": 1.0, "profile": "smooth", "height": 1.0}],
		[{"type": "ridge", "points": [{"x": 0.0, "z": 0.0}], "width": 0.0, "falloff_width": 1.0, "profile": "smooth", "height": 1.0}],
		[{"type": "ridge", "points": [{"x": 0.0, "z": 0.0}], "width": 2.0, "falloff_width": 1.0, "profile": "cubic", "height": 1.0}],
	]:
		assert_true(_is_error(_handler._normalized_landforms(bad)), "invalid landform input must be rejected")


func test_landform_application_is_deterministic_clipped_and_changes_only_affected_samples() -> void:
	var features := _landform_features()
	var normalized: Variant = _handler._normalized_landforms(features)
	assert_false(_is_error(normalized))
	var settings: Array = (normalized as Dictionary).items
	var first := _new_data({"size": 24, "seed": 9102})
	var second := _new_data({"size": 24, "seed": 9102})
	_build(first)
	_build(second)
	var before := first.final_heights()
	var first_result: Variant = _handler._apply_landforms_sync(first, settings)
	var second_result: Variant = _handler._apply_landforms_sync(second, settings)
	assert_false(_is_error(first_result))
	assert_false(_is_error(second_result))
	assert_eq(first.final_heights(), second.final_heights(), "landform roughness must be deterministic")
	assert_ne(first.final_heights(), before, "landform features must affect the heightfield")
	for value in first.final_heights():
		assert_true(is_finite(value))
	assert_true(first.is_valid())


func test_landform_polyline_bounds_clip_to_grid_edges_without_out_of_range_writes() -> void:
	var normalized := _handler._normalized_landforms([{
		"type": "ridge",
		"points": [{"x": 8.0, "z": 8.0}, {"x": 40.0, "z": 40.0}],
		"width": 4.0,
		"falloff_width": 2.0,
		"profile": "sharp",
		"height": 2.0,
	}])
	assert_has_key(normalized, "items")
	var data := _new_data({"size": 12, "seed": 9106})
	_build(data)
	var before := data.final_heights()
	var result := _handler._apply_landforms_sync(data, normalized.items)
	assert_gt(result.affected_vertices, 0,
		"a polyline entering the terrain at an edge must still affect clipped samples")
	assert_true(data.is_valid())
	assert_ne(data.final_heights(), before)
	for value in data.final_heights():
		assert_true(is_finite(value))


## ----- natural erosion -----

func _run_erosion(data: TerrainData, algorithm: String, iterations: int = 8, intensity: float = 0.35, seed: int = 901) -> Dictionary:
	var job := TerrainErosionJob.new(data, algorithm, iterations, intensity, seed)
	while not job.step(1000000):
		pass
	return job.result()


func _distance_to_segment(point: Vector2, start: Vector2, end: Vector2) -> float:
	var segment := end - start
	var length_squared := segment.length_squared()
	if length_squared <= 0.000001:
		return point.distance_to(start)
	var amount := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(start + segment * amount)


func _point_vector(point: Variant) -> Vector2:
	if point is Vector2:
		return point
	var entry: Dictionary = point
	return Vector2(float(entry.x), float(entry.z))


func _region_contains(region: Dictionary, position: Vector2) -> bool:
	var radius := float(region.radius)
	if region.has("center_x"):
		return position.distance_to(Vector2(float(region.center_x), float(region.center_z))) <= radius + 0.0001
	var points: Array = region.points
	var distance := INF
	for point_index in range(points.size() - 1):
		var start := _point_vector(points[point_index])
		var end := _point_vector(points[point_index + 1])
		distance = minf(distance, _distance_to_segment(position, start, end))
	return distance <= radius + 0.0001


func test_natural_erosion_modes_are_deterministic_finite_and_hole_safe() -> void:
	for algorithm in ["thermal_natural", "hydraulic_natural"]:
		var checked: Variant = _handler._normalized_erosion({
			"algorithm": algorithm,
			"iterations": 8,
			"intensity": 0.35,
			"seed": 901,
		})
		assert_false(_is_error(checked), "%s should be a published erosion mode" % algorithm)
		for preset in ["soft", "balanced", "rugged"]:
			var preset_result := _handler._normalized_erosion({"algorithm": algorithm, "preset": preset})
			assert_false(_is_error(preset_result), "%s should be a published erosion preset" % preset)
			assert_eq(preset_result.settings.preset, preset)
		var first := _new_data({"size": 18, "seed": 9103})
		var second := _new_data({"size": 18, "seed": 9103})
		_build(first)
		_build(second)
		first.holes[9 * 18 + 9] = 1
		second.holes[9 * 18 + 9] = 1
		var hole_height := first.final_heights()[9 * 18 + 9]
		var before_mass := 0.0
		for value in first.final_heights():
			before_mass += value
		assert_false(_is_error(_run_erosion(first, algorithm)))
		assert_false(_is_error(_run_erosion(second, algorithm)))
		assert_eq(first.final_heights(), second.final_heights(), "%s must be deterministic" % algorithm)
		assert_eq(first.final_heights()[9 * 18 + 9], hole_height, "%s must preserve holes" % algorithm)
		var after_mass := 0.0
		for value in first.final_heights():
			after_mass += value
		assert_true(absf(after_mass - before_mass) < 0.01,
			"%s erosion must conserve total terrain mass" % algorithm)
		for value in first.final_heights():
			assert_true(is_finite(value), "%s must never emit NAN/INF heights" % algorithm)


func test_natural_erosion_accepts_regions_and_ridge_preservation_without_mutating_outside_region() -> void:
	var request := {
		"algorithm": "hydraulic_natural",
		"iterations": 6,
		"intensity": 0.35,
		"seed": 902,
		"rain": 0.8,
		"erosion": 0.4,
		"deposition": 0.3,
		"evaporation": 0.08,
		"talus": 0.15,
		"ridge_preservation": 0.75,
		"region": {"center_x": 0.0, "center_z": 0.0, "radius": 12.0},
	}
	var checked: Variant = _handler._normalized_erosion(request)
	assert_false(_is_error(checked), "natural erosion region and exposed parameters should normalize")
	var settings: Dictionary = (checked as Dictionary).settings
	var first := _new_data({"size": 18, "seed": 9104})
	var second := _new_data({"size": 18, "seed": 9104})
	_build(first)
	_build(second)
	var before := first.final_heights()
	var first_result: Variant = _handler._apply_erosion_sync(first, settings)
	var second_result: Variant = _handler._apply_erosion_sync(second, settings)
	assert_false(_is_error(first_result))
	assert_false(_is_error(second_result))
	assert_eq(first.final_heights(), second.final_heights(), "masked natural erosion must remain deterministic")
	var outside_changed := false
	for index in first.final_heights().size():
		var x := index % 18
		var z := int(index / 18)
		if Vector2(float(x - 8), float(z - 8)).length() > 8.0 and not is_equal_approx(first.final_heights()[index], before[index]):
			outside_changed = true
	assert_false(outside_changed, "regional erosion must not modify samples outside its mask")

	var ridge_unprotected := _new_data({"size": 18, "seed": 9107})
	var ridge_protected := _new_data({"size": 18, "seed": 9107})
	_build(ridge_unprotected)
	_build(ridge_protected)
	var peak_index := 9 * 18 + 9
	ridge_unprotected.edit_offsets[peak_index] += 8.0
	ridge_protected.edit_offsets[peak_index] += 8.0
	var peak_before := ridge_unprotected.final_heights()[peak_index]
	var unprotected_settings: Dictionary = settings.duplicate(true)
	unprotected_settings.ridge_preservation = 0.0
	var protected_settings: Dictionary = settings.duplicate(true)
	protected_settings.ridge_preservation = 1.0
	_handler._apply_erosion_sync(ridge_unprotected, unprotected_settings)
	_handler._apply_erosion_sync(ridge_protected, protected_settings)
	var unprotected_delta := absf(ridge_unprotected.final_heights()[peak_index] - peak_before)
	var protected_delta := absf(ridge_protected.final_heights()[peak_index] - peak_before)
	assert_true(protected_delta <= unprotected_delta + 0.0001,
		"ridge preservation should not erode a peak more than the unprotected run")


func test_natural_erosion_regions_support_circles_and_polyline_corridors() -> void:
	var valid_regions: Array = [
		{"center_x": 0.0, "center_z": 0.0, "radius": 8.0},
		{"points": [{"x": -12.0, "z": -12.0}, {"x": 12.0, "z": 12.0}], "radius": 3.5},
	]
	for invalid_region in [
		[],
		{},
		{"center_x": 0.0, "center_z": 0.0},
		{"center_x": 0.0, "center_z": 0.0, "radius": 0.0},
		{"center_x": 0.0, "center_z": 0.0, "radius": 2.0, "points": [{"x": 0.0, "z": 0.0}, {"x": 1.0, "z": 1.0}]},
		{"points": [], "radius": 3.0},
		{"points": [{"x": 0.0, "z": 0.0}], "radius": 3.0},
		{"points": [{"x": 0.0, "z": 0.0}, {"x": INF, "z": 1.0}], "radius": 3.0},
		{"points": [{"x": 0.0, "z": 0.0}, {"x": 1.0, "z": 1.0}], "radius": 3.0, "unexpected": true},
		{"points": "not-a-polyline", "radius": 3.0},
	]:
		assert_true(_is_error(_handler._normalized_erosion({
			"algorithm": "hydraulic_natural", "region": invalid_region,
		})), "invalid erosion region must be rejected")

	for algorithm in ["thermal_natural", "hydraulic_natural"]:
		for region in valid_regions:
			var checked: Variant = _handler._normalized_erosion({
				"algorithm": algorithm,
				"iterations": 8,
				"intensity": 0.6,
				"seed": 9130,
				"region": region,
			})
			assert_false(_is_error(checked), "%s region should normalize: %s" % [algorithm, region])
			var settings: Dictionary = (checked as Dictionary).settings
			assert_true(settings.region is Dictionary)
			assert_eq(settings.region.radius, region.radius)
			if region.has("center_x"):
				assert_eq(settings.region.center_x, region.center_x)
				assert_eq(settings.region.center_z, region.center_z)
			else:
				assert_eq(settings.region.points.size(), region.points.size())
				for point_index in region.points.size():
					var expected_point := Vector2(float(region.points[point_index].x), float(region.points[point_index].z))
					assert_eq(_point_vector(settings.region.points[point_index]), expected_point)

			var data := _new_data({"size": 20, "seed": 9131})
			_build(data)
			## Impose a deterministic downhill gradient so both natural algorithms
			## have a measurable in-region transfer independent of the base noise.
			for z in range(20):
				for x in range(20):
					data.edit_offsets[z * 20 + x] = float(x + z) * 0.25
			var before := data.final_heights()
			var result: Variant = _handler._apply_erosion_sync(data, settings)
			assert_false(_is_error(result), "%s region erosion should apply" % algorithm)
			var after := data.final_heights()
			var changed_inside := false
			var outside_count := 0
			var half_extent := (20.0 - 1.0) * 2.0 * 0.5
			for index in after.size():
				var x := index % 20
				var z := int(index / 20)
				var position := Vector2(float(x) * 2.0 - half_extent, float(z) * 2.0 - half_extent)
				if _region_contains(settings.region, position):
					if not is_equal_approx(after[index], before[index]):
						changed_inside = true
				else:
					outside_count += 1
					assert_eq(after[index], before[index],
						"%s erosion must leave cells outside its region unchanged" % algorithm)
			assert_gt(outside_count, 0)
			assert_true(changed_inside,
				"%s erosion region must affect at least one in-region cell" % algorithm)


## ----- material profiles, variants, aliases, and registration -----

func test_material_surface_profiles_are_normalized_and_published() -> void:
	var probe := _normalized({
		"size": 8,
		"seed": 9105,
		"surface_profile": "mountain_valley",
	})
	assert_has_key(probe, "params")
	assert_eq(probe.params.surface_profile, "mountain_valley")
	for profile in ["mountain_valley", "forest", "arid", "legacy"]:
		var checked := _normalized({"size": 8, "surface_profile": profile})
		assert_has_key(checked, "params")
		assert_eq(checked.params.surface_profile, profile)
	for invalid in [
		{"surface_profile": "volcanic"},
		{"surface_profile": 7},
	]:
		assert_true(_is_error(_normalized(invalid)), "invalid profile input must be rejected")
	var plugin := track(TerrainPlugin.new())
	var material: McpCustomToolSpec = plugin._material_spec()
	assert_true(material != null)
	var properties: Dictionary = material.params_schema.get("properties", {})
	assert_has_key(properties, "surface_profile")
	assert_eq((properties.surface_profile as Dictionary).enum, ["mountain_valley", "forest", "arid", "legacy"])
	## The material is colour-only: no render-mode or texture knobs remain.
	for removed in ["render_mode", "texture_scale", "custom_textures", "texture_variants"]:
		assert_false(properties.has(removed), "material spec must not expose %s" % removed)


func test_dirt_and_sand_paint_aliases_are_accepted_and_preserve_manual_override() -> void:
	for alias in ["dirt", "sand"]:
		var normalized: Variant = _handler._normalized_paint_strokes([{
			"points": [{"x": 0.0, "z": 0.0}],
			"radius": 2.0,
			"strength": 1.0,
			"falloff": "smooth",
			"layer": alias,
		}])
		assert_false(_is_error(normalized), "%s should be a paint alias" % alias)
		var items: Array = (normalized as Dictionary).items
		assert_eq(items.size(), 1)
		assert_true(["road", "dirt", "sand"].has(String(items[0].get("layer", ""))))
	var plugin := track(TerrainPlugin.new())
	var paint: McpCustomToolSpec = plugin._paint_spec()
	var stroke_property: Dictionary = paint.params_schema.properties.strokes
	var layer_property: Dictionary = stroke_property.items.properties.layer
	assert_true((layer_property.enum as Array).has("dirt"))
	assert_true((layer_property.enum as Array).has("sand"))


func test_landform_tool_is_promoted_deferred_undoable_and_registered_with_other_terrain_tools() -> void:
	var plugin := track(TerrainPlugin.new())
	var spec: McpCustomToolSpec = plugin._landform_spec()
	assert_true(spec != null)
	assert_eq(spec.name, "terrain_landform")
	assert_true(spec.promoted)
	assert_true(spec.deferred)
	assert_true(spec.requires_writable)
	assert_true(spec.undoable)
	assert_eq(spec.timeout_ms, 30000)
	assert_true((spec.params_schema.required as Array).has("path"))
	assert_true((spec.params_schema.required as Array).has("features"))
	assert_eq(spec.validate().size(), 0)
	var dispatcher := McpDispatcher.new(McpLogBuffer.new())
	var connection := McpConnection.new()
	var locator := McpServiceLocator.new()
	locator.setup(connection, McpLogBuffer.new())
	var registry := McpToolRegistry.new()
	registry.setup(dispatcher, locator)
	plugin._registry = registry
	plugin._register_tools()
	assert_true(registry.get_spec("terrain_create") != null)
	assert_true(registry.get_spec("terrain_regenerate") != null)
	assert_true(registry.get_spec("terrain_sculpt") != null)
	assert_true(registry.get_spec("terrain_holes") != null)
	assert_true(registry.get_spec("terrain_erode") != null)
	assert_true(registry.get_spec("terrain_road") != null)
	assert_true(registry.get_spec("terrain_paint") != null)
	assert_true(registry.get_spec("terrain_material") != null)
	var landform_name := String(spec.name)
	assert_true(registry.get_spec(landform_name) != null)
	var registered: Array[McpCustomToolSpec] = registry.all()
	assert_eq(registered.size(), 9, "all terrain operations must remain registered")
	var promoted_count := 0
	var material: McpCustomToolSpec = registry.get_spec("terrain_material")
	for registered_spec: McpCustomToolSpec in registered:
		if registered_spec.promoted:
			promoted_count += 1
	assert_eq(promoted_count, 8, "Godot AI's promoted custom-tool budget is eight")
	assert_true(material != null)
	assert_false(material.promoted, "material stays available through custom_manage")
	assert_true(material.deferred)
	assert_true(material.requires_writable)
	assert_true(material.undoable)
	assert_true(registry.is_tool_enabled("terrain_material"))
	assert_eq(registry.unregister_source(plugin.SOURCE_PATH), 9,
		"adding landform should register exactly one additional terrain tool")
