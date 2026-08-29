"""Build and validate the addon-only release archive.

The archive deliberately has one top-level path, ``addons/godot_ai_terrain_tools``.
That makes the artifact safe to extract into a Godot project and keeps repository
files (README and CI configuration) out of the install. The addon's license is
included inside the packaged directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import tempfile
import zipfile
from pathlib import Path

ADDON_ROOT = Path("addons") / "godot_ai_terrain_tools"
ASSET_ROOT = ADDON_ROOT / "assets"
ASSET_METADATA = (
    ASSET_ROOT / "README.md",
    ASSET_ROOT / "LICENSE-CC0.txt",
    ASSET_ROOT / "GENERATED_ASSET_PROVENANCE.md",
    ASSET_ROOT / "GENERATED_ASSET_CHECKSUMS.sha256",
    ASSET_ROOT / "GENERATED_ASSET_MANIFEST.json",
)


def validate_asset_metadata(addon_root: Path, require_generated: bool) -> None:
    """Validate the asset contract without inventing missing map digests.

    The normal package job accepts the manifest's pending state so source and
    CI archives can be built while the independently generated HD maps are in
    progress. Release archives opt into ``require_generated`` and therefore
    fail closed until all nine variants have real files and SHA-256 digests.
    """

    asset_root = addon_root / "assets"
    for relative in (path.relative_to(ADDON_ROOT) for path in ASSET_METADATA):
        if not (addon_root / relative).is_file():
            raise SystemExit(f"required asset metadata is missing: {addon_root / relative}")

    manifest_path = asset_root / "GENERATED_ASSET_MANIFEST.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"invalid generated asset manifest: {manifest_path}: {error}") from error

    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        raise SystemExit("generated asset manifest has an unsupported schema_version")
    materials = manifest.get("materials")
    if not isinstance(materials, list) or len(materials) != 9:
        raise SystemExit("generated asset manifest must list exactly nine materials")

    if not require_generated:
        return

    if manifest.get("status") not in {"generated", "validated", "complete"}:
        raise SystemExit(
            "HD surface pack is not ready; set manifest status to generated, validated, or complete"
        )

    required_maps = {"albedo.png", "height.png", "normal_opengl.png", "roughness.png"}
    expected_dimensions = manifest.get("requirements", {}).get("dimensions")
    if expected_dimensions != [2048, 2048]:
        raise SystemExit("generated asset manifest must require 2048x2048 maps")
    manifest_root = manifest.get("root")
    if not isinstance(manifest_root, str) or not manifest_root:
        raise SystemExit("generated asset manifest must define a relative root")
    root_path = Path(manifest_root)
    if root_path.is_absolute() or ".." in root_path.parts:
        raise SystemExit("generated asset manifest root must stay inside the addon")
    expected_checksums = {}
    for material in materials:
        if not isinstance(material, dict):
            raise SystemExit(f"material entry must be an object: {material!r}")
        if material.get("status") not in {"generated", "validated", "complete"}:
            raise SystemExit(f"material is not ready: {material.get('variant')}")
        relative_dir = material.get("path")
        if not isinstance(relative_dir, str) or not relative_dir:
            raise SystemExit(f"material has no relative path: {material!r}")
        files = material.get("files")
        if not isinstance(files, list) or any(not isinstance(entry, dict) for entry in files):
            raise SystemExit(f"material map entries must be objects: {material.get('variant')}")
        if {entry.get("name") for entry in files} != required_maps:
            raise SystemExit(f"material must provide all four maps: {material.get('variant')}")
        for entry in files:
            name = entry.get("name")
            digest = entry.get("sha256")
            if not isinstance(digest, str) or len(digest) != 64:
                raise SystemExit(f"missing SHA-256 digest for {relative_dir}/{name}")
            path = asset_root / root_path / relative_dir / name
            if not path.is_file():
                raise SystemExit(f"generated texture is missing: {path}")
            payload = path.read_bytes()
            actual_digest = hashlib.sha256(payload).hexdigest()
            if actual_digest != digest.lower():
                raise SystemExit(f"SHA-256 mismatch for generated texture: {path}")
            if path.suffix.lower() == ".png":
                if len(payload) < 24 or payload[:8] != b"\x89PNG\r\n\x1a\n":
                    raise SystemExit(f"generated texture is not a valid PNG: {path}")
                width, height = struct.unpack(">II", payload[16:24])
                if [width, height] != expected_dimensions:
                    raise SystemExit(
                        f"generated texture must be 2048x2048: {path} ({width}x{height})"
                    )
            if "bytes" in entry and entry["bytes"] != len(payload):
                raise SystemExit(f"byte-size mismatch for generated texture: {path}")
            expected_checksums[
                (root_path / relative_dir / name).as_posix()
            ] = digest.lower()

    checksum_path = asset_root / "GENERATED_ASSET_CHECKSUMS.sha256"
    actual_checksums = {}
    for line in checksum_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split(None, 1)
        if len(fields) != 2 or len(fields[0]) != 64:
            raise SystemExit(f"invalid checksum manifest line: {line}")
        actual_checksums[fields[1]] = fields[0].lower()
    if actual_checksums != expected_checksums:
        raise SystemExit("generated asset checksum manifest does not match the JSON manifest")


def build_archive(repository_root: Path, output: Path) -> None:
    addon_root = repository_root / ADDON_ROOT
    plugin_cfg = addon_root / "plugin.cfg"
    if not addon_root.is_dir():
        raise SystemExit(f"addon directory is missing: {addon_root}")
    if not plugin_cfg.is_file():
        raise SystemExit(f"required plugin metadata is missing: {plugin_cfg}")
    validate_asset_metadata(addon_root, require_generated=False)

    files = sorted(path for path in addon_root.rglob("*") if path.is_file())
    if not files:
        raise SystemExit(f"addon directory is empty: {addon_root}")

    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        dir=output.parent,
        prefix=f".{output.name}.",
        suffix=".tmp",
        delete=False,
    ) as temporary:
        temporary_path = Path(temporary.name)

    try:
        with zipfile.ZipFile(
            temporary_path,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        ) as archive:
            for path in files:
                relative = path.relative_to(repository_root).as_posix()
                archive.write(path, relative)

        with zipfile.ZipFile(temporary_path) as archive:
            names = archive.namelist()
            expected_prefix = f"{ADDON_ROOT.as_posix()}/"
            if any(not name.startswith(expected_prefix) for name in names):
                raise SystemExit("release archive contains a path outside the addon")
            if f"{ADDON_ROOT.as_posix()}/plugin.cfg" not in names:
                raise SystemExit("release archive does not contain plugin.cfg")
            for required in ASSET_METADATA:
                archive_name = required.relative_to(Path(".")).as_posix()
                if archive_name not in names:
                    raise SystemExit(f"release archive does not contain {archive_name}")
            if not names:
                raise SystemExit("release archive is empty")

        temporary_path.replace(output)
    finally:
        temporary_path.unlink(missing_ok=True)

    print(f"Built {output} ({len(files)} addon files)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("dist") / "godot-ai-terrain-tools.zip",
        help="archive path (default: dist/godot-ai-terrain-tools.zip)",
    )
    parser.add_argument(
        "--require-generated-assets",
        action="store_true",
        help="fail unless all nine generated HD materials and their SHA-256 digests are present",
    )
    args = parser.parse_args()
    repository_root = Path(__file__).resolve().parents[1]
    validate_asset_metadata(
        repository_root / ADDON_ROOT,
        require_generated=args.require_generated_assets,
    )
    build_archive(repository_root, args.output)


if __name__ == "__main__":
    main()
