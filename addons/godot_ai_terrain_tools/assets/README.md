# Bundled terrain textures

This directory documents two material sets:

* `textures/` is the checked-in 1K **legacy** fallback pack. It is kept for
  compatibility with existing scenes and projects.
* `generated/` contains the free 2K surface pack
  produced by the terrain-tools asset pipeline. Its image files, validation
  report, and checksums are recorded in `GENERATED_ASSET_MANIFEST.json` and
  `GENERATED_ASSET_PROVENANCE.md`.

The legacy fallback has three 1024×1024 maps per semantic layer:

| Layer | Albedo | OpenGL normal | Roughness |
| --- | --- | --- | --- |
| `ground` | `textures/ground/albedo.jpg` | `textures/ground/normal_opengl.jpg` | `textures/ground/roughness.jpg` |
| `road` | `textures/road/albedo.jpg` | `textures/road/normal_opengl.jpg` | `textures/road/roughness.jpg` |
| `rock` | `textures/rock/albedo.jpg` | `textures/rock/normal_opengl.jpg` | `textures/rock/roughness.jpg` |
| `snow` | `textures/snow/albedo.jpg` | `textures/snow/normal_opengl.jpg` | `textures/snow/roughness.jpg` |

The legacy source maps were downloaded at 1K JPEG resolution from the following
Poly Haven assets. The source names are retained here so the compact files can
be audited or refreshed without ambiguity:

| Layer | Poly Haven asset | Source map names |
| --- | --- | --- |
| `ground` | [Forest Ground 01](https://polyhaven.com/a/forrest_ground_01) | `forrest_ground_01_diff_1k.jpg`, `forrest_ground_01_nor_gl_1k.jpg`, `forrest_ground_01_rough_1k.jpg` |
| `road` | [Dirt](https://polyhaven.com/a/dirt) | `dirt_diff_1k.jpg`, `dirt_nor_gl_1k.jpg`, `dirt_rough_1k.jpg` |
| `rock` | [Rock Surface](https://polyhaven.com/a/rock_surface) | `rock_surface_diff_1k.jpg`, `rock_surface_nor_gl_1k.jpg`, `rock_surface_rough_1k.jpg` |
| `snow` | [Snow 02](https://polyhaven.com/a/snow_02) | `snow_02_diff_1k.jpg`, `snow_02_nor_gl_1k.jpg`, `snow_02_rough_1k.jpg` |

The packaged JPEGs retain the source bytes (MD5 checksums are included for
refresh/audit tooling):

| Packaged layer | Albedo MD5 | OpenGL normal MD5 | Roughness MD5 |
| --- | --- | --- | --- |
| `ground` | `236e7d928f5e357a194fd92de189cbe4` | `ba4265df25aea293913d004b69ef9ab0` | `72dacf5b829cafc025f08ca64e92e5eb` |
| `road` | `cb37e24797597b1dd1ae3819fa80f076` | `362610edf09fd31735958eecec823a84` | `d936d6760ce0f899b131d30626d52ce9` |
| `rock` | `a7285f02b40e8ed6f15f8e97e357031d` | `2243da682fc9181016d0b5bb0b684786` | `ee0bbfad5c8acedbe1d68e4ae5686f6e` |
| `snow` | `fc54766c6b36ff298699115a619d440b` | `f16b5701f9ad521cdd6af10c1d6d2b48` | `1dbae0269e53dbf80d4fd1c4335f25a2` |

Download endpoints are documented by the Poly Haven API at
`https://api.polyhaven.com/files/<asset-slug>` and use the corresponding
`dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/...` URLs. The normal maps are
the OpenGL (`nor_gl`) variants, as expected by Godot's normal-map convention.

All four legacy source assets are released under the [Poly Haven CC0
license](https://polyhaven.com/license). Attribution is not required by that
license, but this notice is included to preserve provenance. The addon code
and these notices remain covered by the repository's MIT license; the texture
copyright/license status is governed by Poly Haven's CC0 dedication.

## Free HD surface pack

The precision upgrade contains nine independently generated, seamless
2048×2048 materials. Each completed material contains the following maps:

| Family | Variants (zero-based indices) |
| --- | --- |
| `rock` | `0 stratified_dark_rock`, `1 weathered_granite`, `2 rugged_limestone` |
| `ground` | `0 meadow_grass`, `1 mossy_forest_floor`, `2 dry_mountain_grass` |
| `dirt` | `0 compact_earth`, `1 pale_sand`, `2 gravelly_loam` |

For every variant, the pipeline provides `albedo`, `height`,
`normal_opengl`, and `roughness` maps. The layout is:

```text
generated/<family>/<variant>/
  albedo.png
  height.png
  normal_opengl.png
  roughness.png
```

These maps were created independently of the supplied landscape reference; no
reference-image pixels were reused. Their exact source IDs, prompts, processing
record, and SHA-256 checksums are in `GENERATED_ASSET_MANIFEST.json`.
The matching normal and roughness maps are derived by the deterministic asset
pipeline from the generated height/albedo sources.

The generated-pack license is CC0 1.0. The exact prompts, generation date,
processing settings, source-image provenance, dimensions, and SHA-256 digests
are recorded in `GENERATED_ASSET_MANIFEST.json` and duplicated in
`GENERATED_ASSET_CHECKSUMS.sha256`; the human-readable QA record is
`GENERATED_ASSET_PROVENANCE.md`. `LICENSE-CC0.txt` accompanies the maps.

## Validation requirements

Every generated variant was validated as follows:

1. Confirm all four maps are 2048×2048 and import cleanly in Godot. The local
   generation run used Godot 4.5; the addon release target is Godot 4.7.
2. Compare opposing edges after a 2×2 tile preview; the seam difference must
   stay within the tolerance recorded by the validation report.
3. Check OpenGL normal orientation, finite channel values, and sensible
   roughness ranges.
4. Record SHA-256 checksums for every map and update the manifest atomically
   with the asset files. The completed manifest contains those digests.

The package builder includes the maps, previews, documentation, and manifest in
addon archives. Release packaging verifies every map's SHA-256 digest, PNG
dimensions, and complete four-map set.
