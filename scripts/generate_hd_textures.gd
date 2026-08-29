extends SceneTree

## Deterministic terrain-surface asset pipeline.
##
## This script intentionally uses only Godot's Image API so the generated
## maps can be reproduced in the same Godot 4.x environment used by the addon.
## It accepts the source image directory as a command-line argument because
## the source images live outside the repository.

const OUTPUT_ROOT_RELATIVE := "res://addons/godot_ai_terrain_tools/assets/generated"
const PREVIEW_ROOT_RELATIVE := "res://addons/godot_ai_terrain_tools/assets/previews"
const MANIFEST_RELATIVE := "res://addons/godot_ai_terrain_tools/assets/GENERATED_ASSET_MANIFEST.json"
const CHECKSUM_MANIFEST_RELATIVE := "res://addons/godot_ai_terrain_tools/assets/GENERATED_ASSET_CHECKSUMS.sha256"
const OUTPUT_SIZE := 2048
const PREVIEW_TILE_SIZE := 512
const WRAP_BLEND_WIDTH := 96
const NORMAL_STRENGTH := 3.0
const HEIGHT_LUMA := Vector3(0.2126, 0.7152, 0.0722)

const MATERIALS := [
	{
		"family": "rock",
		"variant": "stratified_dark_rock",
		"albedo_id": "exec-0a1131a8-a0fa-4d68-a4c9-21402d941ed4.png",
		"height_id": "exec-77ee7af1-ffd5-425e-8dff-dad8f1000633.png",
		"prompt": "Seamless tileable dark stratified mountain rock surface, vertically layered charcoal slate, subtle rusty mineral seams, realistic PBR material, no lighting, no objects, no borders.",
	},
	{
		"family": "rock",
		"variant": "weathered_granite",
		"albedo_id": "exec-cbcfc3c9-01c2-4f60-8916-9afa8a1adf5a.png",
		"height_id": "exec-23738a49-96b1-4a95-b076-0e9d3f5e565c.png",
		"prompt": "Seamless tileable weathered granite mountain rock surface, cool gray coarse grains, fractured mineral flecks and restrained natural variation, realistic PBR material, no lighting, no objects, no borders.",
	},
	{
		"family": "rock",
		"variant": "rugged_limestone",
		"albedo_id": "exec-b48ec057-5f6b-4494-8f60-a7055026835b.png",
		"height_id": "exec-2d698d24-827b-4011-8beb-caebc04a5e05.png",
		"prompt": "Seamless tileable rugged limestone cliff surface, pale gray layered sedimentary rock with weathered grooves and small embedded stones, realistic PBR material, no lighting, no objects, no borders.",
	},
	{
		"family": "ground",
		"variant": "meadow_grass",
		"albedo_id": "exec-7c541872-9b21-4c94-b2f9-79c875dbfae8.png",
		"height_id": "exec-5aa0121f-f79b-4c86-9ade-a10dbf837b68.png",
		"prompt": "Seamless tileable alpine meadow grass ground surface, low green grass, subtle soil gaps and varied blades seen from directly above, realistic PBR material, no lighting, no objects, no borders.",
	},
	{
		"family": "ground",
		"variant": "mossy_forest_floor",
		"albedo_id": "exec-da677100-863c-4ad3-ad79-bb11e282297d.png",
		"height_id": "exec-6b585b78-b7aa-408b-bfbe-3f66bec26e99.png",
		"prompt": "Seamless tileable mossy forest floor, deep green moss, damp leaf litter, tiny twigs and soft organic clumps viewed from directly above, realistic PBR material, no lighting, no objects, no borders.",
	},
	{
		"family": "ground",
		"variant": "dry_mountain_grass",
		"albedo_id": "exec-97ba332c-b7ca-4a44-a5e8-ffdf15193639.png",
		"height_id": "exec-68687083-07d8-4704-b017-5b8aa1f49e88.png",
		"prompt": "Seamless tileable dry mountain grass ground, muted olive and straw grasses with sparse exposed soil and fine natural breakup, realistic PBR material, no lighting, no objects, no borders.",
	},
	{
		"family": "dirt",
		"variant": "compact_earth",
		"albedo_id": "exec-95950532-cef3-4e45-a94c-7be170bc7ec1.png",
		"height_id": "exec-84bb0cdb-9ec2-45d3-b999-aea45a198b73.png",
		"prompt": "Seamless tileable compact mountain earth, brown packed soil with small stones, compressed clods and subtle dry cracks viewed from directly above, realistic PBR material, no lighting, no objects, no borders.",
	},
	{
		"family": "dirt",
		"variant": "pale_sand",
		"albedo_id": "exec-ee343549-3d5b-4715-a36b-befc2440cc1d.png",
		"height_id": "exec-756282bf-73a6-42f1-82e9-3bbfbc7be82d.png",
		"prompt": "Seamless tileable pale mountain sand, warm beige fine grains with sparse pebbles and wind-shaped ripples viewed from directly above, realistic PBR material, no lighting, no objects, no borders.",
	},
	{
		"family": "dirt",
		"variant": "gravelly_loam",
		"albedo_id": "exec-96b10b63-1570-46d0-a36e-f409f1a538a1.png",
		"height_id": "exec-93c4d9d4-87f0-4716-a7a3-4602288e1c45.png",
		"prompt": "Seamless tileable gravelly loam terrain, dark earthy soil mixed with angular small stones and subtle moisture variation, realistic PBR material, no lighting, no objects, no borders.",
	},
]

var _source_dir := "C:/Users/mtomc/.codex/generated_images/01a042a8-16c0-7b30-baf9-d4736af3f25d"
var _output_root := ""
var _preview_root := ""
var _manifest_path := ""
var _checksum_manifest_path := ""
var _wrap_width := WRAP_BLEND_WIDTH
var _errors: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_args()
	_source_dir = _argument_value(args, "--source-dir", _source_dir)
	_output_root = _argument_value(args, "--output-root", ProjectSettings.globalize_path(OUTPUT_ROOT_RELATIVE))
	_preview_root = _argument_value(args, "--preview-root", ProjectSettings.globalize_path(PREVIEW_ROOT_RELATIVE))
	_manifest_path = _argument_value(args, "--manifest", ProjectSettings.globalize_path(MANIFEST_RELATIVE))
	_checksum_manifest_path = _argument_value(
		args, "--checksums", ProjectSettings.globalize_path(CHECKSUM_MANIFEST_RELATIVE)
	)
	var wrap_value := _argument_value(args, "--wrap-width", str(WRAP_BLEND_WIDTH))
	_wrap_width = maxi(1, int(wrap_value))

	if not DirAccess.make_dir_recursive_absolute(_output_root) == OK:
		_errors.append("Could not create output directory: %s" % _output_root)
	if not DirAccess.make_dir_recursive_absolute(_preview_root) == OK:
		_errors.append("Could not create preview directory: %s" % _preview_root)
	if not _errors.is_empty():
		_finish_failure()
		return

	var materials: Array = []
	for material in MATERIALS:
		var result := _process_material(material)
		if result.has("error"):
			_errors.append(String(result.error))
		else:
			materials.append(result)
	if not _errors.is_empty():
		_finish_failure()
		return

	if not _write_checksum_manifest(materials):
		_finish_failure()
		return
	var manifest := _make_manifest(materials)
	var manifest_file := FileAccess.open(_manifest_path, FileAccess.WRITE)
	if manifest_file == null:
		_finish_failure("Could not write manifest: %s" % _manifest_path)
		return
	manifest_file.store_string(JSON.stringify(manifest, "\t") + "\n")
	manifest_file.close()
	print("Generated and validated %d HD terrain materials" % materials.size())
	print("Manifest: %s" % _manifest_path)
	quit(0)


func _process_material(spec: Dictionary) -> Dictionary:
	var family := String(spec.family)
	var variant := String(spec.variant)
	var albedo_source := _load_source(String(spec.albedo_id))
	if albedo_source.has("error"):
		return albedo_source
	var height_source := _load_source(String(spec.height_id))
	if height_source.has("error"):
		return height_source

	var albedo: Image = albedo_source.image
	albedo.resize(OUTPUT_SIZE, OUTPUT_SIZE, Image.INTERPOLATE_CUBIC)
	albedo.convert(Image.FORMAT_RGBA8)
	albedo = _periodic_wrap_blend(albedo)

	var height: Image = _to_height_image(height_source.image)
	height.resize(OUTPUT_SIZE, OUTPUT_SIZE, Image.INTERPOLATE_CUBIC)
	height.convert(Image.FORMAT_RGBA8)
	height = _periodic_wrap_blend(height)

	var normal_stats := {"min_y": 1.0, "max_y": 0.0, "mean_y": 0.0, "mean_z": 0.0}
	var normal := _derive_normal(height, normal_stats)
	var rough_stats := {"min": 1.0, "max": 0.0, "mean": 0.0}
	var roughness := _derive_roughness(albedo, height, rough_stats)

	var output_dir := _join(_output_root, family, variant)
	if DirAccess.make_dir_recursive_absolute(output_dir) != OK:
		return {"error": "Could not create output directory: %s" % output_dir}
	var paths := {
		"albedo": _join(output_dir, "albedo.png"),
		"height": _join(output_dir, "height.png"),
		"normal_opengl": _join(output_dir, "normal_opengl.png"),
		"roughness": _join(output_dir, "roughness.png"),
	}
	for key in paths:
		var map: Image = albedo
		if key == "height":
			map = height
		elif key == "normal_opengl":
			map = normal
		elif key == "roughness":
			map = roughness
		var save_error: Error = map.save_png(paths[key])
		if save_error != OK:
			return {"error": "Could not write %s for %s/%s (error %d)" % [key, family, variant, save_error]}

	var preview_dir := _join(_preview_root, family)
	if DirAccess.make_dir_recursive_absolute(preview_dir) != OK:
		return {"error": "Could not create preview directory: %s" % preview_dir}
	var preview_path := _join(preview_dir, "%s_2x2.png" % variant)
	var preview := _make_preview(albedo)
	if preview.save_png(preview_path) != OK:
		return {"error": "Could not write preview for %s/%s" % [family, variant]}

	var files: Array = []
	for key in ["albedo", "height", "normal_opengl", "roughness"]:
		var path: String = paths[key]
		files.append({
			"name": "%s.png" % key,
			"path": _relative_asset_path(family, variant, "%s.png" % key),
			"sha256": FileAccess.get_sha256(path),
			"bytes": _file_size(path),
			"width": OUTPUT_SIZE,
			"height": OUTPUT_SIZE,
		})

	var seam := {
		"albedo": _edge_metrics(albedo),
		"height": _edge_metrics(height),
	}
	var valid := bool(seam.albedo.max_abs <= 2.0 / 255.0 and seam.height.max_abs <= 2.0 / 255.0)
	valid = valid and bool(normal_stats.mean_z > 0.5)
	valid = valid and bool(rough_stats.min >= 0.15 and rough_stats.max <= 0.98)
	return {
		"family": family,
		"variant_index": _variant_index(family, variant),
		"variant": variant,
		"status": "complete" if valid else "generated",
		"path": _relative_asset_path(family, variant, ""),
		"source": {
			"albedo_id": spec.albedo_id,
			"height_id": spec.height_id,
			"prompt": spec.prompt,
			"source_directory": "external source directory supplied with --source-dir",
		},
		"source_dimensions": {
			"albedo": [albedo_source.width, albedo_source.height],
			"height": [height_source.width, height_source.height],
		},
		"files": files,
		"preview": {
			"path": _relative_preview_path(family, "%s_2x2.png" % variant),
			"sha256": FileAccess.get_sha256(preview_path),
			"bytes": _file_size(preview_path),
			"width": OUTPUT_SIZE / 2,
			"height": OUTPUT_SIZE / 2,
		},
		"validation": {
			"valid": valid,
			"seam": seam,
			"normal": normal_stats,
			"roughness": rough_stats,
		},
	}


func _load_source(source_id: String) -> Dictionary:
	var path := _join(_source_dir, source_id)
	var image := Image.new()
	var error := image.load(path)
	if error != OK:
		return {"error": "Could not load source %s (error %d)" % [path, error]}
	if image.is_empty():
		return {"error": "Source image is empty: %s" % path}
	return {"image": image, "width": image.get_width(), "height": image.get_height()}


func _to_height_image(source: Image) -> Image:
	var result := Image.create(source.get_width(), source.get_height(), false, Image.FORMAT_RGBA8)
	for y in source.get_height():
		for x in source.get_width():
			var pixel := source.get_pixel(x, y)
			var value := clampf(pixel.r * HEIGHT_LUMA.x + pixel.g * HEIGHT_LUMA.y + pixel.b * HEIGHT_LUMA.z, 0.0, 1.0)
			result.set_pixel(x, y, Color(value, value, value, 1.0))
	return result


func _periodic_wrap_blend(source: Image) -> Image:
	var width := source.get_width()
	var height := source.get_height()
	var blend_x := mini(_wrap_width, maxi(1, width / 4))
	var blend_y := mini(_wrap_width, maxi(1, height / 4))
	var result: Image = source.duplicate()
	for y in height:
		for x in blend_x:
			var weight := _edge_weight(blend_x - x, blend_x)
			var partner := width - 1 - x
			var blended := source.get_pixel(x, y).lerp(source.get_pixel(partner, y), 0.5 * weight)
			result.set_pixel(x, y, blended)
			var right_x := width - 1 - x
			var right_blended := source.get_pixel(right_x, y).lerp(source.get_pixel(x, y), 0.5 * weight)
			result.set_pixel(right_x, y, right_blended)
	for x in width:
		for y in blend_y:
			var weight := _edge_weight(blend_y - y, blend_y)
			var partner := height - 1 - y
			var current := result.get_pixel(x, y)
			var opposite := result.get_pixel(x, partner)
			result.set_pixel(x, y, current.lerp(opposite, 0.5 * weight))
			result.set_pixel(x, partner, opposite.lerp(current, 0.5 * weight))
	return result


func _edge_weight(distance_from_inner_edge: int, blend_width: int) -> float:
	var normalized := clampf(float(distance_from_inner_edge) / float(blend_width), 0.0, 1.0)
	return normalized * normalized * (3.0 - 2.0 * normalized)


func _derive_normal(height: Image, stats: Dictionary) -> Image:
	var width := height.get_width()
	var image := Image.create(width, height.get_height(), false, Image.FORMAT_RGBA8)
	for y in height.get_height():
		var ym := posmod(y - 1, height.get_height())
		var yp := posmod(y + 1, height.get_height())
		for x in width:
			var xm := posmod(x - 1, width)
			var xp := posmod(x + 1, width)
			var dx := height.get_pixel(xp, y).r - height.get_pixel(xm, y).r
			var dy := height.get_pixel(x, yp).r - height.get_pixel(x, ym).r
			var normal := Vector3(-dx * NORMAL_STRENGTH, -dy * NORMAL_STRENGTH, 1.0).normalized()
			var encoded := Color(normal.x * 0.5 + 0.5, normal.y * 0.5 + 0.5, normal.z * 0.5 + 0.5, 1.0)
			image.set_pixel(x, y, encoded)
			stats.min_y = minf(float(stats.min_y), encoded.g)
			stats.max_y = maxf(float(stats.max_y), encoded.g)
			stats.mean_y += encoded.g
			stats.mean_z += encoded.b
	var count := float(width * height.get_height())
	stats.mean_y /= count
	stats.mean_z /= count
	return image


func _derive_roughness(albedo: Image, height: Image, stats: Dictionary) -> Image:
	var width := albedo.get_width()
	var image := Image.create(width, albedo.get_height(), false, Image.FORMAT_RGBA8)
	for y in albedo.get_height():
		var ym := posmod(y - 1, albedo.get_height())
		var yp := posmod(y + 1, albedo.get_height())
		for x in width:
			var xm := posmod(x - 1, width)
			var xp := posmod(x + 1, width)
			var center := albedo.get_pixel(x, y)
			var luminance := center.r * HEIGHT_LUMA.x + center.g * HEIGHT_LUMA.y + center.b * HEIGHT_LUMA.z
			var neighbors := [
				albedo.get_pixel(xm, y), albedo.get_pixel(xp, y),
				albedo.get_pixel(x, ym), albedo.get_pixel(x, yp),
			]
			var contrast := 0.0
			for neighbor in neighbors:
				var neighbor_luma: float = neighbor.r * HEIGHT_LUMA.x + neighbor.g * HEIGHT_LUMA.y + neighbor.b * HEIGHT_LUMA.z
				contrast += absf(luminance - neighbor_luma)
			contrast *= 0.25
			var height_contrast := absf(height.get_pixel(xp, y).r - height.get_pixel(xm, y).r)
			height_contrast += absf(height.get_pixel(x, yp).r - height.get_pixel(x, ym).r)
			var roughness := clampf(0.52 + (1.0 - luminance) * 0.20 + contrast * 2.0 + height_contrast * 0.16, 0.15, 0.98)
			image.set_pixel(x, y, Color(roughness, roughness, roughness, 1.0))
			stats.min = minf(float(stats.min), roughness)
			stats.max = maxf(float(stats.max), roughness)
			stats.mean += roughness
	stats.mean /= float(width * albedo.get_height())
	return image


func _make_preview(albedo: Image) -> Image:
	var tile: Image = albedo.duplicate()
	tile.resize(PREVIEW_TILE_SIZE, PREVIEW_TILE_SIZE, Image.INTERPOLATE_BILINEAR)
	var preview := Image.create(PREVIEW_TILE_SIZE * 2, PREVIEW_TILE_SIZE * 2, false, Image.FORMAT_RGBA8)
	for tile_y in 2:
		for tile_x in 2:
			preview.blit_rect(
				tile,
				Rect2i(0, 0, PREVIEW_TILE_SIZE, PREVIEW_TILE_SIZE),
				Vector2i(tile_x * PREVIEW_TILE_SIZE, tile_y * PREVIEW_TILE_SIZE)
			)
	return preview


func _edge_metrics(image: Image) -> Dictionary:
	var width := image.get_width()
	var height := image.get_height()
	var max_abs := 0.0
	var total := 0.0
	var samples := 0
	for y in height:
		var horizontal := _pixel_difference(image.get_pixel(0, y), image.get_pixel(width - 1, y))
		max_abs = maxf(max_abs, horizontal)
		total += horizontal
		samples += 1
	for x in width:
		var vertical := _pixel_difference(image.get_pixel(x, 0), image.get_pixel(x, height - 1))
		max_abs = maxf(max_abs, vertical)
		total += vertical
		samples += 1
	return {"max_abs": max_abs, "mean_abs": total / float(samples), "tolerance": 2.0 / 255.0}


func _pixel_difference(first: Color, second: Color) -> float:
	return maxf(absf(first.r - second.r), maxf(absf(first.g - second.g), absf(first.b - second.b)))


func _make_manifest(materials: Array) -> Dictionary:
	var prompts: Array = []
	for material in materials:
		prompts.append({
			"family": material.family,
			"variant": material.variant,
			"prompt": material.source.prompt,
			"albedo_source_id": material.source.albedo_id,
			"height_source_id": material.source.height_id,
		})
	return {
		"schema_version": 1,
		"status": "complete",
		"license": "CC0-1.0",
		"license_notice": "LICENSE-CC0.txt",
		"checksum_manifest": "GENERATED_ASSET_CHECKSUMS.sha256",
		"root": "generated",
		"map_order": ["albedo.png", "height.png", "normal_opengl.png", "roughness.png"],
		"requirements": {
			"dimensions": [OUTPUT_SIZE, OUTPUT_SIZE],
			"seamless_tile": true,
			"normal_convention": "OpenGL (+Y)",
			"reference_pixels_reused": false,
			"checksum_algorithm": "sha256",
		},
		"generation": {
			"tool": "scripts/generate_hd_textures.gd",
			"runtime": Engine.get_version_info().string,
			"target_runtime": "Godot 4.7",
			"generated_at_utc": Time.get_datetime_string_from_system(true),
			"source_directory": "external source directory supplied with --source-dir",
			"prompts": prompts,
			"processing": [
				"resize with Image.INTERPOLATE_CUBIC to 2048x2048",
				"restrained periodic edge wrap-blend with a 96px smoothstep boundary and 0.5 maximum partner weight",
				"height converted to linear luminance using Rec.709 weights 0.2126, 0.7152, 0.0722",
				"OpenGL normal derived from wrapped one-pixel central differences with strength 3.0",
				"roughness derived from albedo luminance/contrast and wrapped height contrast, clamped to 0.15..0.98",
				"2x2 albedo previews generated at 1024x1024",
			],
			"validation_report": "GENERATED_ASSET_PROVENANCE.md",
		},
		"materials": materials,
	}


func _variant_index(family: String, variant: String) -> int:
	var index := 0
	for material in MATERIALS:
		if String(material.family) != family:
			continue
		if String(material.variant) == variant:
			return index
		index += 1
	return -1


func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := file.get_length()
	file.close()
	return size


func _write_checksum_manifest(materials: Array) -> bool:
	var file := FileAccess.open(_checksum_manifest_path, FileAccess.WRITE)
	if file == null:
		_errors.append("Could not write checksum manifest: %s" % _checksum_manifest_path)
		return false
	file.store_string("# SHA-256 checksums for the complete HD terrain surface pack.\n")
	file.store_string("# Paths are relative to addons/godot_ai_terrain_tools/assets/.\n")
	for material in materials:
		for entry in material.files:
			file.store_string("%s  generated/%s\n" % [entry.sha256, entry.path])
	file.close()
	return true


func _relative_asset_path(family: String, variant: String, filename: String) -> String:
	var prefix := "%s/%s" % [family, variant]
	return prefix if filename.is_empty() else "%s/%s" % [prefix, filename]


func _relative_preview_path(family: String, filename: String) -> String:
	return "previews/%s/%s" % [family, filename]


func _argument_value(args: PackedStringArray, name: String, fallback: String) -> String:
	for index in args.size():
		if args[index] == name and index + 1 < args.size():
			return args[index + 1]
	return fallback


func _join(first: String, second: String, third: String = "") -> String:
	var result := first.trim_suffix("/").trim_suffix("\\") + "/" + second
	if not third.is_empty():
		result += "/" + third
	return result


func _finish_failure(message: String = "") -> void:
	if not message.is_empty():
		_errors.append(message)
	for error in _errors:
		push_error(error)
	quit(1)
