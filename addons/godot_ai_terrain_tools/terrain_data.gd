@tool
extends Resource

## Persistent source of truth for a managed terrain. Instances are treated as
## immutable snapshots once attached to a scene so editor undo can restore an
## exact previous state.

const FORMAT_VERSION := 2

@export var format_version := FORMAT_VERSION
@export var params: Dictionary = {}
@export var base_ready := false
@export var base_heights := PackedFloat32Array()
@export var edit_offsets := PackedFloat32Array()
@export var holes := PackedByteArray()

var size: int:
	get:
		return int(params.get("size", 0))

var material_preset: String:
	get:
		return String(params.get("material_preset", "natural"))


func initialize(settings: Dictionary) -> void:
	params = settings.duplicate(true)
	var count := int(params.get("size", 0)) * int(params.get("size", 0))
	base_heights.resize(count)
	edit_offsets.resize(count)
	holes.resize(count)


func is_valid() -> bool:
	return validation_error().is_empty()


func validation_error() -> String:
	var size := int(params.get("size", 0))
	var count := size * size
	if format_version != FORMAT_VERSION or not base_ready or size < 4:
		return "TerrainData version, readiness, or size is invalid"
	if base_heights.size() != count or edit_offsets.size() != count or holes.size() != count:
		return "TerrainData array lengths do not match its size"
	for index in count:
		if not is_finite(base_heights[index]) or not is_finite(edit_offsets[index]):
			return "TerrainData contains a non-finite height at index %d" % index
		if holes[index] != 0 and holes[index] != 1:
			return "TerrainData contains an invalid hole value at index %d" % index
	return ""


func final_heights() -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(base_heights.size())
	for index in base_heights.size():
		result[index] = base_heights[index] + edit_offsets[index]
	return result


func has_modifications() -> bool:
	for value in edit_offsets:
		if not is_zero_approx(value):
			return true
	for value in holes:
		if value != 0:
			return true
	return false


func set_hole(x: int, z: int, enabled: bool) -> void:
	if x < 0 or z < 0 or x >= size or z >= size:
		return
	holes[z * size + x] = 1 if enabled else 0


func snapshot() -> Resource:
	var copy := duplicate(true)
	copy.base_heights = base_heights.duplicate()
	copy.edit_offsets = edit_offsets.duplicate()
	copy.holes = holes.duplicate()
	copy.params = params.duplicate(true)
	copy.base_ready = base_ready
	return copy
