"""Build and validate the addon-only release archive.

The archive deliberately has one top-level path, ``addons/godot_ai_terrain_tools``.
That makes the artifact safe to extract into a Godot project and keeps repository
files (README and CI configuration) out of the install. The addon's license is
included inside the packaged directory.
"""

from __future__ import annotations

import argparse
import tempfile
import zipfile
from pathlib import Path

ADDON_ROOT = Path("addons") / "godot_ai_terrain_tools"


def build_archive(repository_root: Path, output: Path) -> None:
    addon_root = repository_root / ADDON_ROOT
    plugin_cfg = addon_root / "plugin.cfg"
    if not addon_root.is_dir():
        raise SystemExit(f"addon directory is missing: {addon_root}")
    if not plugin_cfg.is_file():
        raise SystemExit(f"required plugin metadata is missing: {plugin_cfg}")

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
    args = parser.parse_args()
    repository_root = Path(__file__).resolve().parents[1]
    build_archive(repository_root, args.output)


if __name__ == "__main__":
    main()
