# Godot AI Terrain Tools

Godot AI Terrain Tools is an editor-only heightmap authoring addon for Godot
4. It exposes five promoted Godot AI custom tools for deterministic terrain
creation, regeneration, batch sculpting, open-hole masks, and bounded erosion.
All changes are made to the edited scene as one undoable editor action.

This is a lightweight heightmap authoring tool, not a runtime terrain system.
The terrain remains a regular grid: it can be raised, lowered, smoothed,
flattened, or noise-sculpted in the editor, but it does not provide overhangs
or volumetric terrain.

## Requirements

- Godot 4.5 or newer.
- [Godot AI](https://github.com/hi-godot/godot-ai) 3.2.2 or newer.
- An MCP client connected through the Godot AI plugin (for example Claude
  Code, Codex, or another MCP-compatible client).

Godot AI 3.2.2 is the minimum because it provides the published
`McpToolRegistry` custom-tool interface used by this addon.

## Installation

1. Copy this repository's `addons/godot_ai_terrain_tools` directory into your
   project's `addons/` directory. Install Godot AI's `addons/godot_ai`
   directory beside it. To try the included scene directly, open this
   repository as a Godot project; its root `project.godot` points at
   `demo/main.tscn`.
2. Open the project in Godot and enable **Godot AI** and **Godot AI Terrain
   Tools** in **Project > Project Settings > Plugins**.
3. Connect your MCP client using the Godot AI dock. The promoted tools appear
   as `custom_terrain_create`, `custom_terrain_regenerate`,
   `custom_terrain_sculpt`, `custom_terrain_holes`, and
   `custom_terrain_erode`.

The addon uses Godot AI's published custom-tool registry interface. It does
not import Godot AI's private Python handlers or require a fork of Godot AI.

## Editor tools

All five tools are promoted, require a writable editor, are deferred for
larger builds, and are undoable. Only one terrain operation runs at a time;
while one is running, another request receives the retryable
`terrain_tools.BUSY` error. `scene_file` is an optional edited-scene guard on
every tool that targets a scene path.

### Common creation and regeneration settings

`custom_terrain_create` and `custom_terrain_regenerate` share these settings:

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `size` | integer | `48` | Square grid width/depth, inclusive range `4..128`. |
| `cell_size` | number | `2.0` | Positive distance between height samples. |
| `seed` | integer | `1337` | Deterministic noise seed. |
| `noise_type` | string | `simplex` | One of `simplex`, `simplex_smooth`, `perlin`, `ridged`, `value`. |
| `frequency` | number | `0.05` | Positive noise frequency. |
| `octaves` | integer | `3` | Fractal octaves, inclusive range `1..6`. |
| `height_scale` | number | `8.0` | Positive vertical amplitude. |
| `base_height` | number | `0.0` | Finite vertical offset. |
| `generate_collision` | boolean | `true` | Add the matching static heightfield collision body. |
| `material_preset` | string | `natural` | One of `natural`, `desert`, `snow`, `volcanic`, `alien`; selects a built-in vertex-color palette. |

The presets are palettes, not texture assets. They change the generated
vertex colors while keeping the mesh deterministic.

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
| `reset_modifications` | boolean | `false` | Clear sculpt offsets, erosion offsets, and hole masks before regeneration. |

When `reset_modifications` is false, same-size regeneration preserves all
sculpting, erosion, and holes. Setting it to true clears them, including when
the grid size is unchanged. If a terrain has any modifications, changing
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
| `algorithm` | string | `thermal` | `thermal` or `hydraulic`. |
| `iterations` | integer | `20` | Inclusive range `1..200`. |
| `intensity` | number | `0.5` | Positive strength, maximum `1.0`. |
| `seed` | integer | `1337` | Deterministic hydraulic rainfall seed. |

Both algorithms skip masked hole samples and are deterministic for the same
TerrainData and settings. They are bounded editor authoring operations, not a
runtime water simulation.

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

## Persistence and collision

Each managed terrain stores a v2 `TerrainData` resource in its addon metadata.
The resource is the source of truth for the deterministic `base_heights`,
accumulated `edit_offsets`, `holes` mask, and persisted parameter snapshot.
Because it is stored with the managed scene state, sculpt, hole, erosion, and
regeneration changes survive reopening the scene and are captured by editor
Undo/Redo as one replacement of the managed mesh and collision children.

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
heightmaps. Runtime editing, streaming, LOD, caves, interactive sculpting,
textures, and vegetation are explicitly out of scope. More specifically, the
addon has no live brush UI or runtime editing, no texture assets or painting,
and no vegetation or foliage instancing. Arbitrary meshes and overhangs are
also not supported.

Generation and editing are bounded and serialized in the editor. Larger grids
can take several frames, and a concurrent request must be retried. The addon
targets the published Godot AI custom-tool API in Godot AI 3.2.2+ and does not
promise compatibility with older releases.

## Background and attribution

The terrain generator began as [Godot AI PR #856](https://github.com/hi-godot/godot-ai/pull/856).
It is published here as a standalone addon in response to the maintainer's
custom-tool resolution: [PR #856 maintainer comment](https://github.com/hi-godot/godot-ai/pull/856#issuecomment-5410618075).
The registration follows Godot AI's documented [third-party custom-tool
contract](https://github.com/hi-godot/godot-ai/blob/main/docs/plugin-architecture.md#custom-tools-third-party-addons),
using promoted tool specs so clients can call the terrain operations directly.

Released under the [MIT License](LICENSE).
