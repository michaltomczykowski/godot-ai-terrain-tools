# HD surface-pack provenance

This file is the human-readable companion to
`GENERATED_ASSET_MANIFEST.json`. It records the nine independently generated
2048×2048 materials under `generated/`.

## Current status

The manifest status is `complete`. All 36 maps and nine 2×2 previews are
present in the addon. The checked-in 1K files under `textures/` are a separate
legacy fallback set sourced from Poly Haven and are documented in `README.md`.

The generation run used the local Godot 4.5 console binary available in this
workspace. The script targets Godot 4.x and the addon release/CI target is
Godot 4.7.

## Generation record

For each generated variant, the manifest records:

* the generation tool, runtime, and UTC generation timestamp;
* the complete processing prompt and source-image ID pair. The supplied PNGs
  contain no embedded model or seed metadata, so none is asserted here;
* confirmation that the supplied landscape reference was not used as an image
  source and that no reference pixels were reused;
* deterministic post-processing used to derive height, OpenGL normal, and
  roughness maps;
* the Godot import target and the result of the 2×2 seam, normal-orientation,
  finite-channel, and roughness-range checks; and
* the SHA-256 digest and byte size of each shipped map.

The manifest records the exact source IDs and canonical processing prompts for
all nine pairs. No supplied reference-image pixels were reused. A release
build runs `scripts/package_release.py --require-generated-assets`; that command
rejects a pending manifest, missing maps, incomplete map sets, wrong PNG
dimensions, digest mismatches, or missing 64-character SHA-256 digests.

## QA results

The seam values below are maximum absolute per-channel differences between
opposing edges, measured on the final PNGs. The acceptance tolerance is
`2/255 = 0.0078431373`. Normal G is the encoded OpenGL Y channel; Normal B is
the mean encoded Z channel. All values are finite.

| Family | Variant | Albedo seam max | Height seam max | Normal G min-max | Normal B mean | Roughness min-max | Valid |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `rock` | `stratified_dark_rock` | 0.000000000 | 0.003921598 | 0.068266-0.937553 | 0.980159 | 0.634605-0.980000 | true |
| `rock` | `weathered_granite` | 0.003921568 | 0.000000000 | 0.068313-0.918173 | 0.962269 | 0.567377-0.980000 | true |
| `rock` | `rugged_limestone` | 0.000000000 | 0.000000000 | 0.058769-0.931516 | 0.977179 | 0.561524-0.980000 | true |
| `ground` | `meadow_grass` | 0.003921576 | 0.003921568 | 0.071798-0.929876 | 0.947635 | 0.576267-0.980000 | true |
| `ground` | `mossy_forest_floor` | 0.003921583 | 0.003921568 | 0.052760-0.945373 | 0.949943 | 0.634256-0.980000 | true |
| `ground` | `dry_mountain_grass` | 0.003921568 | 0.003921598 | 0.046098-0.955878 | 0.943679 | 0.598216-0.980000 | true |
| `dirt` | `compact_earth` | 0.003921568 | 0.003921568 | 0.055112-0.950757 | 0.946721 | 0.607963-0.980000 | true |
| `dirt` | `pale_sand` | 0.000000000 | 0.000000000 | 0.072606-0.922909 | 0.979141 | 0.551185-0.960940 | true |
| `dirt` | `gravelly_loam` | 0.003921583 | 0.003921598 | 0.055161-0.938231 | 0.949068 | 0.578206-0.980000 | true |

The local Godot 4.5 run produced nine 1024×1024 albedo 2×2 previews under
`previews/{family}/`; their individual SHA-256 digests are recorded in the
manifest beside each material.

The generated map license is CC0 1.0 as described in `LICENSE-CC0.txt`. The
addon source code remains under the repository MIT License.
