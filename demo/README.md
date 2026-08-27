# Terrain demo

This scene is intentionally empty of generated terrain. Open the repository's
root project (which uses `demo/main.tscn`) with Godot AI and Godot AI Terrain
Tools enabled, then create terrain under `/TerrainDemo` (or omit
`parent_path` to use the scene root):

```json
{
  "name": "custom_terrain_create",
  "arguments": {
    "parent_path": "/TerrainDemo",
    "name": "Valley",
    "size": 64,
    "cell_size": 1.5,
    "seed": 1337,
    "noise_type": "simplex_smooth",
    "frequency": 0.05,
    "octaves": 3,
    "height_scale": 10.0,
    "material_preset": "natural",
    "generate_collision": true
  }
}
```

The returned path can be used for the editor-only batch operations. For
example, apply two strokes in one undoable action:

```json
{
  "name": "custom_terrain_sculpt",
  "arguments": {
    "path": "/TerrainDemo/Valley",
    "strokes": [
      {"center_x": -8.0, "center_z": 3.0, "radius": 6.0, "mode": "raise", "strength": 1.5},
      {"center_x": 7.0, "center_z": -5.0, "radius": 4.0, "mode": "smooth", "strength": 0.6}
    ]
  }
}
```

Cut an open hole and run deterministic hydraulic erosion with separate
undoable actions:

```json
{
  "name": "custom_terrain_holes",
  "arguments": {
    "path": "/TerrainDemo/Valley",
    "areas": [
      {"center_x": 4.0, "center_z": 2.0, "radius": 2.5, "mode": "cut"}
    ]
  }
}
```

```json
{
  "name": "custom_terrain_erode",
  "arguments": {
    "path": "/TerrainDemo/Valley",
    "algorithm": "hydraulic",
    "iterations": 20,
    "intensity": 0.35,
    "seed": 101
  }
}
```

Use `custom_terrain_regenerate` with the returned path to change a seed,
palette, or other persisted setting. Same-size sculpting, erosion, and holes
are preserved by default. A size change is rejected when modifications exist
unless the request includes `"reset_modifications": true`; that flag clears
the edit offsets and hole mask before rebuilding. `custom_terrain_holes` cuts
the visual mesh and writes `NAN` height samples into the matching
`HeightMapShape3D`, so an open hole has no collision or side walls.

The included camera looks toward the origin from above. Frame the generated
terrain with the editor camera or use the demo camera, then use Godot's
Undo/Redo buttons to review each complete replacement.

Runtime editing, streaming, LOD, caves, interactive sculpting, texture assets,
and vegetation are not part of this demo or addon.
