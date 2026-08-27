# Godot AI Terrain Tools

Godot AI Terrain Tools gives an AI assistant two editor tools for creating and
regenerating deterministic 3D heightmaps in Godot. A seed and the same
settings always produce the same mesh, which makes iteration reproducible.
The generated terrain can include a matching static collision mesh and every
write is undoable in the Godot editor.

This is a lightweight heightmap authoring addon. It is not a replacement for a
full terrain system with streaming, LODs, erosion simulation, foliage
instancing, or sculpting.

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
3. Connect your MCP client using the Godot AI dock. The two promoted tools
   appear as `custom_terrain_create` and `custom_terrain_regenerate`.

The addon uses Godot AI's published custom-tool registry interface. It does
not import Godot AI's private Python handlers or require a fork of Godot AI.

## Tools

Both tools are editor writes. They require a writable editor, create one
undoable action, and may reply asynchronously while a larger terrain is built.
Only one terrain build runs at a time. If another build is already running,
the second request returns a retryable `terrain_tools.BUSY` error. If the
edited scene changes before a build commits, the build is discarded rather
than attached to the wrong scene.

### `custom_terrain_create`

Creates a managed `Node3D` under the requested parent. The node contains a
`TerrainMesh` `MeshInstance3D` and, when enabled, a `TerrainCollision`
`StaticBody3D` with a `ConcavePolygonShape3D` made from the same triangles.

Parameters:

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `parent_path` | string | edited scene root | Node3D parent scene path. |
| `scene_file` | string | omitted | Optional edited-scene guard, such as `res://demo/main.tscn`. |
| `name` | string | `Terrain` | Name for the generated container. |
| `size` | integer | `48` | Grid width and depth, inclusive range `4..128`. |
| `cell_size` | number | `2.0` | Distance between samples; must be finite and greater than zero. |
| `seed` | integer | `1337` | Deterministic noise seed. |
| `noise_type` | string | `simplex` | One of `simplex`, `simplex_smooth`, `perlin`, `ridged`, `value`. |
| `frequency` | number | `0.05` | Noise frequency; must be finite and greater than zero. |
| `octaves` | integer | `3` | Fractal octaves, inclusive range `1..6`. |
| `height_scale` | number | `8.0` | Vertical amplitude; must be finite and greater than zero. |
| `base_height` | number | `0.0` | Vertical offset; must be finite. |
| `generate_collision` | boolean | `true` | Add the matching static collision body. |

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
    "generate_collision": true
  }
}
```

The response includes the generated path, effective settings, vertex and
triangle counts, collision state, and `undoable: true`.

### `custom_terrain_regenerate`

Regenerates an existing terrain created by this addon. The `path` must point
to a managed terrain container with valid addon metadata; arbitrary `Node3D`
nodes are rejected. Omitted settings are read from the terrain's persisted
settings, so an update can change only the seed or another selected option.

Parameters:

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `path` | string | required | Managed terrain container scene path. |
| `scene_file` | string | omitted | Optional edited-scene guard. |
| `size` | integer | persisted | Replacement grid size, `4..128`. |
| `cell_size` | number | persisted | Finite, greater than zero. |
| `seed` | integer | persisted | Deterministic noise seed. |
| `noise_type` | string | persisted | `simplex`, `simplex_smooth`, `perlin`, `ridged`, or `value`. |
| `frequency` | number | persisted | Finite, greater than zero. |
| `octaves` | integer | persisted | Fractal octaves, `1..6`. |
| `height_scale` | number | persisted | Finite, greater than zero. |
| `base_height` | number | persisted | Finite vertical offset. |
| `generate_collision` | boolean | persisted | Add/remove matching collision. |

Example MCP call:

```json
{
  "name": "custom_terrain_regenerate",
  "arguments": {
    "path": "/TerrainDemo/Valley",
    "seed": 42,
    "height_scale": 6.0,
    "generate_collision": false
  }
}
```

Regeneration replaces only the addon-managed mesh and collision children. The
new result is prepared once and reused for commit and redo. Undo and redo
restore the mesh, collision, metadata, and effective settings as one action.

## Demo

`demo/main.tscn` is a deliberately small scene containing a `Node3D` root, a
camera, and a directional light. Open the repository as a Godot project with
both plugins enabled and ask
your MCP client to create terrain under `/TerrainDemo` (or omit
`parent_path` to use the scene root). The scene does not commit generated
terrain, so each run starts from a clean, reviewable example.

Suggested first prompt:

> Open `demo/main.tscn` and create a 64×64 terrain named `Valley` under the
> scene root with seed 1337, `simplex_smooth` noise, and collision enabled.

Frame the created terrain with the editor camera or use the demo camera. Then
regenerate it with a different seed and use Godot's Undo/Redo buttons to see
the whole replacement revert and reapply.

## Testing

The addon test suites live in `tests/` and use Godot AI's in-project
`McpTestSuite` runner. With the project open and Godot AI enabled, call
`test_run` (or `test_run suite=terrain_tools`) through the connected MCP
client. See Godot AI's [testing
guide](https://github.com/hi-godot/godot-ai/blob/main/docs/testing.md) for
discovery and runner behavior.

## Background and attribution

The terrain generator began as [Godot AI PR #856](https://github.com/hi-godot/godot-ai/pull/856).
It is published here as a standalone addon in response to the maintainer's
custom-tool resolution: [PR #856 maintainer comment](https://github.com/hi-godot/godot-ai/pull/856#issuecomment-5410618075).
The registration follows Godot AI's documented [third-party custom-tool
contract](https://github.com/hi-godot/godot-ai/blob/main/docs/plugin-architecture.md#custom-tools-third-party-addons),
using promoted tool specs so clients can call the terrain operations directly.

## Limitations

- Only deterministic heightmap terrain is generated; arbitrary meshes,
  sculpting, holes, caves, erosion, streaming, and runtime terrain editing are
  outside this addon.
- Collision is a static `ConcavePolygonShape3D`; dynamic rigid or character
  body generation is not provided.
- Generation is intentionally bounded and serialized in the editor. Large
  grids can take several frames, and a concurrent request must be retried.
- The addon targets the published Godot AI custom-tool API in Godot AI 3.2.2+
  and does not promise compatibility with older releases.

Released under the [MIT License](LICENSE).
