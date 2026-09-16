# Changelog

All notable changes to Godot AI Terrain Tools are documented here.

## [1.4.0] - 2026-09-16

### Changed

- Ported to Godot AI 4.1. The addon still uses Godot AI's published
  `McpToolRegistry` custom-tool interface; the pinned CI harness and the live
  smoke now run against Godot AI v4.1.0, and the smoke authenticates with the
  HTTP bearer capability Godot AI 4 requires on every request.
- **Terrain is rendered with colours only.** The generated 2048×2048 HD
  surface pack, the legacy Poly Haven maps, their manifests and checksums, and
  the HD texture generator are removed. The shader blends one palette colour
  per semantic layer (ground, road/dirt/sand, rock, snow) by the vertex weights
  the build and paint passes write, plus a small deterministic grain.
- `terrain_create`, `terrain_regenerate`, and `terrain_material` no longer
  accept `render_mode`, `texture_scale`, `custom_textures`, or
  `texture_variants`. `material_preset` (colour palette) and `surface_profile`
  (automatic surface classification) remain, and the documented
  `surface_profile` default is now the code default, `mountain_valley`.
- Terrains saved before this release still load: their persisted render-mode
  and texture keys are ignored, while heights, holes, paint, and collision are
  preserved.

### Removed

- `addons/godot_ai_terrain_tools/assets/` (generated HD maps, previews, legacy
  CC0 maps, and their manifests/checksums) and `scripts/generate_hd_textures.gd`.
- `docs/terrain-tools-showcase.png` and `docs/terrain-tools-comparison.png`.

### Verification

- Material suites now assert palette colours on the shader material, the
  absence of render-mode/texture properties in the published spec, and that
  legacy texture keys in stored data are ignored.
- The Godot suites and the promoted-tool live smoke run against Godot AI
  v4.1.0.

## [1.3.0] - 2026-08-29

### Added

- Optional terrain resolution up to `256×256` while retaining the existing
  default size. A 256 grid produces 65,536 vertices and 130,050 triangles,
  with a matching `HeightMapShape3D` collision map.
- `custom_terrain_landform` for up to 32 ordered ridge, valley, and plateau
  features. Features support circular or polyline geometry, smooth/sharp/
  terraced profiles, falloff width, deterministic roughness, scale, and seed.
- `thermal_natural` and `hydraulic_natural` erosion modes with eight-neighbor
  slope processing, proportional multi-direction flow, deterministic rainfall,
  deposition, evaporation, mass checks, `soft`/`balanced`/`rugged` presets,
  ridge preservation, and localized regions. Regions may be circles using
  `center_x`, `center_z`, and `radius`, or polyline corridors using `points`
  and `radius`.
- Bounds-aware sculpting and painting so small circular strokes and paths do
  not scan the entire heightmap.
- Automatic surface classification using height, slope, curvature, and
  deposition/lowland signals, with stable ground, dirt/sand, rock, and snow
  placement. Manual semantic painting continues to override automatic weights.
- Nine independent 2048×2048 seamless CC0 surface materials: three rock,
  three ground/forest, and three dirt/sand variants. Profiles include
  `mountain_valley`, `forest`, `arid`, and `legacy`; each family supports a
  selected texture variant with profile fallback.
- `dirt` and `sand` paint aliases for the existing `road` semantic channel.

### Changed

- Bundled rendering now prefers the generated HD pack and retains the Poly
  Haven collection as the `legacy` fallback. Only the selected family
  variants are bound, avoiding texture-unit pressure.
- Corrected triplanar normal transformation and restrained material detail
  normals. Bundled detail-normal influence defaults to `0.08`, while HD
  albedo and roughness remain active, avoiding steep-terrain lighting
  artifacts and dark bands without removing surface relief.
- All nine operations remain registered, but Godot AI promotes eight. The
  material operation remains available as `terrain_material` through
  `custom_manage`, preserving first-class access to sculpting and landforms
  under the promoted-tool cap.
- TerrainData v3 compatibility, snapshots, undo/redo replacement, holes, and
  geometry/collision parity are preserved.

### Verification

- Added coverage for landform validation, circular/polyline geometry, profiles,
  deterministic roughness, batch ordering, clipping, undo/redo, collision
  alignment, natural-erosion determinism and conservation, regional masks,
  ridge preservation, holes, finite output, timeout handling, and BUSY state.
- Added checks for 256×256 mesh/collision counts, all surface profiles,
  variant fallback, paint aliases, migration, custom-texture compatibility,
  legacy rendering, HD texture checksums, dimensions, seams, normal orientation,
  roughness ranges, packaging, parser loading, and live promoted-tool access.

### Known limitations

- Terrain authoring remains editor-only and uses a regular heightfield; caves,
  overhangs, runtime editing, streaming, LOD, vegetation scattering, and
  shader displacement are not included.
- Deferred custom-tool operations have a 30-second deadline. Heavy natural
  erosion on a 256×256 terrain with high iteration counts may return
  `terrain_tools.TIMEOUT`; use fewer iterations, lower intensity, or a circle/
  polyline region to stay within the boundary.
