# Terrain demo

This scene is intentionally empty of generated terrain. Open the repository's
root project (which uses `demo/main.tscn`) with Godot AI and Godot AI Terrain
Tools enabled, then invoke `custom_terrain_create` with no
`parent_path` or with `/TerrainDemo`.

The included camera looks toward the origin from above. After creation, use
`custom_terrain_regenerate` with the returned terrain path to try another seed
or height scale. Creation and regeneration are single undoable editor actions.
