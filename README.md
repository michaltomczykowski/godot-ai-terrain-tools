# Godot AI Terrain Tools

Godot AI Terrain Tools is an editor-only heightmap authoring addon for Godot
4.7. It registers nine Godot AI custom tools for deterministic terrain
creation, regeneration, batch sculpting, open-hole masks, bounded erosion,
graded roads, semantic painting, colour palettes, and authored landforms.
Eight high-frequency operations are promoted as first-class MCP tools;
`terrain_material` remains available through `custom_manage` so the promotion
cap never displaces sculpting or landform authoring. Terrain is rendered with
per-layer palette colours only; the addon also adds natural erosion modes,
profile-aware surface classification, and optional 256×256 authoring.
All changes are made to the edited scene as one undoable editor action.

This is a lightweight heightmap authoring tool, not a runtime terrain system.
The terrain remains a regular grid: it can be raised, lowered, smoothed,
flattened, or noise-sculpted in the editor, but it does not provide overhangs
or volumetric terrain.

## Requirements

- Godot 4.7 or newer.
- [Godot AI](https://github.com/hi-godot/godot-ai) 4.1 or newer.
- An MCP client connected through the Godot AI plugin (for example Claude
  Code, Codex, or another MCP-compatible client).

Godot AI 4.1 is the minimum because it provides the published
`McpToolRegistry` custom-tool interface used by this addon.

## Installation

1. Install the addon either way:
   - Download `godot-ai-terrain-tools.zip` from the [latest
     release](https://github.com/michaltomczykowski/godot-ai-terrain-tools/releases/latest)
     and extract it into your project root; the archive contains
     `addons/godot_ai_terrain_tools/`.
   - Or copy this repository's `addons/godot_ai_terrain_tools` directory into
     your project's `addons/` directory.
   Install Godot AI's `addons/godot_ai` directory beside it. To try the
   included scene directly, open this repository as a Godot project; its root
   `project.godot` points at `demo/main.tscn`.
2. Open the project in Godot and enable **Godot AI** and **Godot AI Terrain
   Tools** in **Project > Project Settings > Plugins**.
3. Connect your MCP client using the Godot AI dock. The eight promoted tools
   appear as `custom_terrain_create`, `custom_terrain_regenerate`,
   `custom_terrain_sculpt`, `custom_terrain_holes`, `custom_terrain_erode`,
   `custom_terrain_road`, `custom_terrain_paint`, and
   `custom_terrain_landform`. All nine registered operations, including
   `terrain_material`, are listed and invokable through `custom_manage`.

The addon uses Godot AI's published custom-tool registry interface. It does
not import Godot AI's private Python handlers or require a fork of Godot AI.
Release history and per-version notes: [CHANGELOG.md](CHANGELOG.md).

## Editor tools

All nine tools are registered, require a writable editor, are deferred for
larger builds, and are undoable. Eight are promoted as first-class MCP tools;
`terrain_material` is intentionally routed through `custom_manage` because
Godot AI caps promoted custom tools. Only one terrain operation runs at a time;
while one is running, another request receives the retryable
`terrain_tools.BUSY` error. `scene_file` is an optional edited-scene guard on
every tool that targets a scene path.

### Common creation and regeneration settings

`custom_terrain_create` and `custom_terrain_regenerate` share these settings:

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `size` | integer | `48` | Square grid width/depth, inclusive range `4..256`. The default remains `48`; 256 is an opt-in maximum. |
| `cell_size` | number | `2.0` | Positive distance between height samples. |
| `seed` | integer | `1337` | Deterministic noise seed. |
| `noise_type` | string | `simplex` | One of `simplex`, `simplex_smooth`, `perlin`, `ridged`, `value`. |
| `frequency` | number | `0.05` | Positive noise frequency. |
| `octaves` | integer | `3` | Fractal octaves, inclusive range `1..6`. |
| `height_scale` | number | `8.0` | Positive vertical amplitude. |
| `base_height` | number | `0.0` | Finite vertical offset. |
| `generate_collision` | boolean | `true` | Add the matching static heightfield collision body. |
| `material_preset` | string | `natural` | One of `natural`, `desert`, `snow`, `volcanic`, `alien`; selects the built-in colour palette. |
| `surface_profile` | string | `mountain_valley` | One of `mountain_valley`, `forest`, `arid`, or `legacy`; controls automatic surface classification (rock, snow, and dirt bias) for the generated palette weights. |

Terrain is rendered with colours only. The shader blends one palette colour per
semantic layer (ground, road/dirt/sand, rock, snow) by the vertex weights the
build and paint passes write, plus a small deterministic grain so large flat
areas do not read as untextured plastic. No textures are loaded or bundled, so
material changes never alter terrain heights, holes, topology, or collision.

The presets are colour palettes, not texture assets. They change the shader
colours while keeping terrain geometry and semantic paint deterministic.

### `custom_terrain_create`

Creates a managed `Node3D` under `parent_path` (or under the edited scene
root). The container has a `TerrainMesh` `MeshInstance3D` and, when enabled, a
`TerrainCollision` `StaticBody3D` containing a `HeightMapShape3D`.

In addition to the common settings, the create-only parameters are:

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `parent_path` | string | edited scene root | Node3D scene path for the generated container. |
| `scene_file` | string | omitted | Optional `res://...tscn` edited-scene guard. |
| `name` | string | `Terrain` | Non-empty generated container name; `/` is not allowed. |

Example MCP call:

```json
{
  "name": "custom_terrain_create",
  "arguments": {
    "parent_path": "/TerrainDemo",
    "name": "Valley",
    "size": 64,
    "cell_size": 1.5,
    "seed": 8675309,
    "noise_type": "simplex_smooth",
    "frequency": 0.035,
    "octaves": 4,
    "height_scale": 10.0,
    "material_preset": "natural",
    "surface_profile": "mountain_valley",
    "generate_collision": true
  }
}
```

The response includes the generated path, effective settings, vertex and
triangle counts, collision state, material preset, hole count, and
`undoable: true`.

### `custom_terrain_regenerate`

Regenerates an existing managed terrain. The required `path` must resolve to a
container created by this addon; arbitrary `Node3D` nodes are rejected.
Omitted common settings are read from the persisted `TerrainData` state.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `path` | string | required | Managed terrain container scene path. |
| `scene_file` | string | omitted | Optional edited-scene guard. |
| `reset_modifications` | boolean | `false` | Clear sculpt offsets, erosion offsets, semantic paint, and hole masks before regeneration. |

When `reset_modifications` is false, same-size regeneration preserves all
sculpting, erosion, semantic paint, and holes. Setting it to true clears them,
including when the grid size is unchanged. If a terrain has any modifications, changing
`size` requires `reset_modifications: true`; otherwise the request fails with
`terrain_tools.MODIFICATIONS_EXIST`. An unmodified terrain may change size
without a reset. `reset_modifications` is a regenerate-only parameter and is
rejected by create.

Example that changes the seed and palette while preserving same-size edits:

```json
{
  "name": "custom_terrain_regenerate",
  "arguments": {
    "path": "/TerrainDemo/Valley",
    "seed": 42,
    "height_scale": 6.0,
    "material_preset": "desert",
    "generate_collision": false
  }
}
```

### `custom_terrain_road`

Grades a smooth, path-based road directly into the managed heightmap. The
operation samples the existing terrain at the endpoints (unless explicit
heights are supplied), resamples and smooths the longitudinal profile,
enforces `max_grade`, flattens the road corridor, and feathers the cut/fill
through configurable shoulders. It clips paths at terrain boundaries and
skips masked hole samples. Geometry, collision, and the default `road`
semantic paint are committed as one undoable action.

The request requires `path`, at least two terrain-local `{x, z}` points, and a
positive `width`. Coordinates use the same terrain-local units as sculpt
strokes. Optional fields are:

| Field | Type | Description |
| --- | --- | --- |
| `points` | array | Ordered terrain-local `{x, z}` path points. |
| `width` | positive number | Flat road corridor width. |
| `elevation_mode` | string | `follow_smooth` (default) or `linear`. |
| `start_height`, `end_height` | number | Optional endpoint elevations; omitted values sample the existing terrain. |
| `max_grade` | positive number | Maximum allowed longitudinal grade; infeasible paths are rejected before mutation. |
| `shoulder_width` | non-negative number | Width of the feathered cut/fill shoulder. |
| `smoothing_passes` | integer | Number of longitudinal smoothing passes. |
| `falloff` | string | `smooth` (default) or `linear` shoulder feathering. |
| `paint_road` | boolean | Paint the corridor as `road` (default `true`) or leave semantic paint unchanged. |

### `custom_terrain_paint`

Applies `1..64` ordered semantic paint strokes and rebuilds the terrain once
as one undoable action. A stroke with one point paints a circle; multiple
points paint a continuous polyline. The request requires `path` and
`strokes`.

| Stroke field | Type | Default | Description |
| --- | --- | --- | --- |
| `points` | array | required | One or more terrain-local `{x, z}` points. |
| `radius` | positive number | required | Brush radius in terrain units. |
| `strength` | number | required | Blend amount in `0..1`. |
| `falloff` | string | `smooth` | `smooth` or `linear`. |
| `layer` | string | required | `ground`, `road` (`dirt`/`sand` aliases), `rock`, `snow`, or `auto`. |

`auto` removes manual paint in the affected area and restores the automatic
height/slope classification. Strokes are evaluated in request order, so
later paint can intentionally replace or blend earlier paint.

### `terrain_material` via `custom_manage`

Changes only the managed terrain's colour palette and surface-classification
profile. It requires `path` and accepts `material_preset` (`natural`, `desert`,
`snow`, `volcanic`, or `alien`) and `surface_profile` (`mountain_valley`,
`forest`, `arid`, or `legacy`). The operation leaves heights, paint weights,
topology, holes, and collision unchanged.

This operation is registered under `terrain_material` but is not one of the
eight promoted `custom_terrain_*` tools. Use `custom_manage` for discovery and
invocation:

Example:

```json
{
  "name": "custom_manage",
  "arguments": {
    "op": "invoke",
    "params": {
      "tool_name": "terrain_material",
      "params": {
        "path": "/TerrainDemo/Valley",
        "material_preset": "desert"
      }
    }
  }
}
```

### `custom_terrain_landform`

Applies `1..32` deterministic landform features and rebuilds the managed
terrain once as one undoable action. Features operate on the existing
`edit_offsets`, so the TerrainData v3 format, snapshots, holes, and collision
alignment remain compatible. A feature with one point is circular; two or more
points form a polyline ridge or valley spine. Processing is clipped to the
feature bounds so a small feature does not scan the whole heightmap.

| Feature field | Type | Description |
| --- | --- | --- |
| `type` | string | `ridge`, `valley`, or `plateau`. |
| `points` | array | One or more terrain-local `{x, z}` points. |
| `width` | positive number | Core radius for a circular feature or half-width around a polyline. |
| `falloff_width` | non-negative number | Feather distance beyond the core. |
| `profile` | string | `smooth`, `sharp`, or `terraced`. |
| `height` | number | Signed ridge amplitude, or target elevation for `valley`/`plateau`. |
| `roughness` | number | Deterministic detail amount, clamped to the documented range. |
| `scale` | positive number | Detail scale in terrain-local units. |
| `seed` | integer | Feature-local deterministic roughness seed. |

For a polyline, the closest point on each segment determines the falloff and
the longitudinal feature is blended continuously at segment joins. `sharp`
preserves a more pronounced crest or cut, while `terraced` quantizes the
profile into broad steps. Features are evaluated in request order, allowing a
valley floor or plateau to be placed after a ridge chain.

Example ridge chain and valley floor:

```json
{
  "name": "custom_terrain_landform",
  "arguments": {
    "path": "/TerrainDemo/Valley",
    "features": [
      {
        "type": "ridge",
        "points": [{"x": -32, "z": -8}, {"x": -4, "z": 0}, {"x": 30, "z": 12}],
        "width": 5.0,
        "falloff_width": 4.0,
        "profile": "sharp",
        "height": 4.0,
        "roughness": 0.25,
        "scale": 7.0,
        "seed": 17
      },
      {
        "type": "valley",
        "points": [{"x": -28, "z": 10}, {"x": 28, "z": 8}],
        "width": 10.0,
        "falloff_width": 8.0,
        "profile": "smooth",
        "height": -1.5,
        "seed": 18
      }
    ]
  }
}
```

### `custom_terrain_sculpt`

Applies a batch of `1..64` terrain-local brush strokes and rebuilds the
managed terrain once as one undoable action. The request requires `path` and
`strokes`; each stroke requires `center_x`, `center_z`, `radius`, `mode`, and
`strength`.

| Stroke field | Type | Default | Description |
| --- | --- | --- | --- |
| `center_x`, `center_z` | number | required | Terrain-local X/Z brush center in the same units as `cell_size`. |
| `radius` | positive number | required | Brush radius. |
| `mode` | string | required | `raise`, `lower`, `smooth`, `flatten`, or `noise`. |
| `strength` | positive number | required | Effect strength. |
| `falloff` | string | `smooth` | `smooth` or `linear`. |
| `target_height` | number | omitted | Required only for `flatten`; invalid for other modes. |
| `seed` | integer | `1337` | Used only by `noise`; invalid for other modes. |

Example:

```json
{
  "name": "custom_terrain_sculpt",
  "arguments": {
    "path": "/TerrainDemo/Valley",
    "strokes": [
      {"center_x": -12.0, "center_z": 4.0, "radius": 8.0, "mode": "raise", "strength": 2.0},
      {"center_x": 10.0, "center_z": -6.0, "radius": 5.0, "mode": "smooth", "strength": 0.7, "falloff": "linear"},
      {"center_x": 0.0, "center_z": 0.0, "radius": 4.0, "mode": "flatten", "strength": 0.8, "target_height": 1.5}
    ]
  }
}
```

### `custom_terrain_holes`

Applies a batch of `1..64` circular hole areas and rebuilds once as one
undoable action. The request requires `path` and `areas`; each area requires
`center_x`, `center_z`, `radius`, and `mode`, where `mode` is `cut` or `fill`.
Coordinates are terrain-local X/Z positions in the same units as `cell_size`,
matching sculpt strokes.

```json
{
  "name": "custom_terrain_holes",
  "arguments": {
    "path": "/TerrainDemo/Valley",
    "areas": [
      {"center_x": 6.0, "center_z": 2.0, "radius": 3.5, "mode": "cut"},
      {"center_x": -8.0, "center_z": -4.0, "radius": 2.0, "mode": "fill"}
    ]
  }
}
```

An area masks height samples on the regular grid. Any mesh triangle touching
a masked sample is omitted, so a `cut` is an open surface hole rather than a
textured decal, a wall, or a cave. `fill` clears the mask and leaves the
stored height edits in place.

### `custom_terrain_erode`

Applies one bounded, deterministic erosion job to the managed `TerrainData`
and bakes the result into its edit offsets. It requires `path` and accepts:

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `algorithm` | string | `thermal` | Compatibility modes are `thermal` and `hydraulic`; precision modes are `thermal_natural` and `hydraulic_natural`. |
| `iterations` | integer | `20` | Inclusive range `1..200`. |
| `intensity` | number | `0.5` | Positive strength, maximum `1.0`. |
| `seed` | integer | `1337` | Deterministic hydraulic rainfall seed. |
| `preset` | string | `balanced` | Natural modes only: `soft`, `balanced`, or `rugged`. |
| `rain` | number | preset | Hydraulic natural rainfall multiplier. |
| `erosion` / `deposition` | number | preset | Natural hydraulic transport rates. |
| `evaporation` / `talus` | number | preset | Water loss and thermal stability controls. |
| `region` | object | omitted | Optional circular `{center_x, center_z, radius}` or polyline corridor `{points, radius}` mask. |
| `ridge_preservation` | number | `0.0` | `0..1` protection against erosion near steep/convex ridges. |

Both compatibility algorithms skip masked hole samples and remain unchanged.
Natural modes use eight-neighbor, slope-aware thermal transfer and proportional
multi-outflow hydraulic transport with deterministic rainfall, deposition,
evaporation, and mass-conservation checks. Regions and ridge preservation are
applied before any map mutation. All four modes are bounded editor authoring
operations, not a runtime water simulation.

Example:

```json
{
  "name": "custom_terrain_erode",
  "arguments": {
    "path": "/TerrainDemo/Valley",
    "algorithm": "hydraulic",
    "iterations": 40,
    "intensity": 0.35,
    "seed": 101
  }
}
```

Natural erosion example limited to a central basin while preserving the ridge
crest:

```json
{
  "name": "custom_terrain_erode",
  "arguments": {
    "path": "/TerrainDemo/Valley",
    "algorithm": "hydraulic_natural",
    "preset": "balanced",
    "iterations": 32,
    "intensity": 0.35,
    "rain": 0.8,
    "erosion": 0.4,
    "deposition": 0.3,
    "evaporation": 0.08,
    "ridge_preservation": 0.75,
    "region": {"center_x": 0.0, "center_z": 0.0, "radius": 24.0},
    "seed": 101
  }
}
```

The same `region` field can select a polyline corridor instead of a circle. The
`points` are ordered terrain-local `{x, z}` coordinates and `radius` is the
corridor half-width:

```json
"region": {
  "points": [
    {"x": -28.0, "z": -8.0},
    {"x": -4.0, "z": 0.0},
    {"x": 26.0, "z": 12.0}
  ],
  "radius": 6.0
}
```

## Persistence and collision

Each managed terrain stores a v3 `TerrainData` resource in its addon metadata.
The resource is the source of truth for the deterministic `base_heights`,
accumulated `edit_offsets`, `holes` mask, persistent four-layer semantic paint
weights, manual-paint coverage, and persisted parameter snapshot.
Because it is stored with the managed scene state, sculpt, hole, erosion, and
regeneration changes survive reopening the scene and are captured by editor
Undo/Redo as one replacement of the managed mesh, material, and collision
children. Existing v1/v2 terrain data migrates to v3 on its first successful
edit; migrated terrain starts with automatic height/slope classification and
keeps its geometry and holes. Terrains saved before the colour-only change
still load: their persisted render-mode and texture keys are ignored.

Collision is a static `HeightMapShape3D` with one map sample per heightmap
vertex. Its `map_width` and `map_depth` are the terrain `size`, and the
collision shape is scaled by `cell_size`. Hole samples are written as `NAN`
in `HeightMapShape3D.map_data`; this removes collision at the open hole in
the same places where the visual mesh omits touching triangles. There are no
side walls, tunnel interiors, dynamic rigid-body shapes, or character-body
helpers.

## Demo

`demo/main.tscn` is a deliberately small scene containing a `Node3D` root, a
camera, and a directional light. Open the repository as a Godot project with
both plugins enabled and use the examples above under `/TerrainDemo` (or omit
`parent_path` to use the scene root). The scene does not commit generated
terrain, so each run starts from a clean, reviewable example.

## Testing

The addon test suites live in `tests/` and use Godot AI's in-project
`McpTestSuite` runner. With the project open and Godot AI enabled, call
`test_run` (or `test_run suite=terrain_tools`) through the connected MCP
client. See Godot AI's [testing
guide](https://github.com/hi-godot/godot-ai/blob/main/docs/testing.md) for
discovery and runner behavior.

## Scope and limitations

This release is intentionally editor-only and limited to regular-grid
heightmaps. Runtime editing, streaming, LOD, caves, interactive sculpting, and
vegetation are explicitly out of scope. Roads and painting are Godot AI
authoring operations, not a live brush UI or runtime editing system. Arbitrary
meshes and overhangs are also not supported.

Generation and editing are bounded and serialized in the editor. Larger grids
can take several frames, and a concurrent request must be retried. 256×256 is
an opt-in authoring maximum; its build, erosion, and collision work scales with
the number of samples. The addon targets the published Godot AI custom-tool API
in Godot AI 4.1+ and does not
promise compatibility with older releases.

## Background and attribution

The terrain generator began as [Godot AI PR #856](https://github.com/hi-godot/godot-ai/pull/856).
It is published here as a standalone addon in response to the maintainer's
custom-tool resolution: [PR #856 maintainer comment](https://github.com/hi-godot/godot-ai/pull/856#issuecomment-5410618075).
The registration follows Godot AI's documented [third-party custom-tool
contract](https://github.com/hi-godot/godot-ai/blob/main/docs/plugin-architecture.md#custom-tools-third-party-addons),
using eight promoted tool specs for frequent terrain operations. The ninth
registered operation, `terrain_material`, remains reachable through
`custom_manage` because of Godot AI's promotion cap.

Terrain is rendered with per-layer palette colours only; the addon bundles no
textures.

Released under the [MIT License](LICENSE).
