"""Exercise the installed addon through a live Godot AI MCP server."""

from __future__ import annotations

import argparse
import asyncio
import os
import time
from contextlib import suppress
from pathlib import Path
from urllib.parse import urlsplit

from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport
from fastmcp.exceptions import ToolError

## Godot AI promotes at most eight addon tools. Material remains in the
## complete custom-tool catalog and is exercised through custom_manage.
PROMOTED_TERRAIN_TOOLS = {
    "custom_terrain_create",
    "custom_terrain_regenerate",
    "custom_terrain_sculpt",
    "custom_terrain_holes",
    "custom_terrain_erode",
    "custom_terrain_road",
    "custom_terrain_paint",
    "custom_terrain_landform",
}

REGISTERED_TERRAIN_TOOLS = {
    "terrain_create",
    "terrain_regenerate",
    "terrain_sculpt",
    "terrain_holes",
    "terrain_erode",
    "terrain_road",
    "terrain_paint",
    "terrain_material",
    "terrain_landform",
}


def authorization_headers(server_url: str) -> dict[str, str]:
    """Resolve the bearer capability Godot AI 4 requires on every HTTP request.

    The server publishes the capability in a private record for its HTTP port;
    a loopback URL reads that record directly, mirroring the upstream CI
    helpers. Non-loopback targets must supply GODOT_AI_HTTP_CAPABILITY.
    """
    from godot_ai.transport.capability import (
        HTTP_CAPABILITY_ENV,
        read_capabilities,
        validate_capability,
    )

    parsed = urlsplit(server_url)
    loopback = parsed.hostname in {"127.0.0.1", "localhost", "::1"}
    if loopback:
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        record = read_capabilities(port)
        if record is None:
            raise RuntimeError(
                f"missing Godot AI HTTP capability record for port {port}"
            )
        capability = record.http
    else:
        capability = validate_capability(os.environ.get(HTTP_CAPABILITY_ENV, ""))
    return {"Authorization": f"Bearer {capability}"}


def make_client(server_url: str) -> Client:
    """Build an MCP client that carries Godot AI's HTTP bearer capability."""
    return Client(
        StreamableHttpTransport(url=server_url, headers=authorization_headers(server_url))
    )


async def connect_client(server_url: str, timeout: float) -> Client:
    """Connect after the MCP server becomes ready, or fail at the deadline."""
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        client = make_client(server_url)
        try:
            await client.__aenter__()
            return client
        except Exception as error:  # noqa: BLE001 - transport startup failures vary
            last_error = error
            with suppress(Exception):
                await client.__aexit__(type(error), error, error.__traceback__)
            await asyncio.sleep(1)
    raise RuntimeError(
        f"Godot AI server at {server_url} did not become ready"
    ) from last_error


async def wait_for_session(client: Client, project_root: Path, timeout: float) -> str:
    expected = project_root.resolve().as_posix().rstrip("/").lower()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = await client.call_tool("session_manage", {"op": "list"})
        for session in (result.structured_content or {}).get("sessions", []):
            actual = str(session.get("project_path", "")).rstrip("/").lower()
            if actual == expected and session.get("readiness") == "ready":
                return str(session["session_id"])
        await asyncio.sleep(1)
    raise RuntimeError(f"Godot session for {expected} did not become ready")


async def wait_for_promoted_tools(client: Client, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        names = {tool.name for tool in await client.list_tools()}
        if PROMOTED_TERRAIN_TOOLS <= names:
            return
        await asyncio.sleep(0.5)
    raise RuntimeError("promoted terrain tools were not exposed by tools/list")


async def wait_for_registered_tools(
    client: Client, session_id: str, timeout: float
) -> dict:
    """Wait for all nine registry entries exposed by custom_manage(list)."""
    deadline = time.monotonic() + timeout
    last_names: set[str] = set()
    while time.monotonic() < deadline:
        result = await client.call_tool(
            "custom_manage",
            {"op": "list", "params": {}, "session_id": session_id},
        )
        data = result.structured_content or {}
        tools = data.get("tools", [])
        last_names = {
            str(tool.get("name"))
            for tool in tools
            if isinstance(tool, dict) and tool.get("name")
        }
        if REGISTERED_TERRAIN_TOOLS <= last_names:
            return data
        await asyncio.sleep(0.5)
    missing = sorted(REGISTERED_TERRAIN_TOOLS - last_names)
    raise RuntimeError(
        f"custom_manage list did not expose all nine terrain tools; missing {missing}"
    )


def _schema_dict(value):
    """Return a fastmcp/Pydantic schema as a plain dictionary."""
    if value is None:
        return {}
    if isinstance(value, dict):
        return value
    model_dump = getattr(value, "model_dump", None)
    if callable(model_dump):
        return model_dump()
    return {}


def _schema_value(name: str, schema: dict):
    if "default" in schema:
        return schema["default"]
    enum = schema.get("enum")
    if enum:
        return enum[0]
    schema_type = schema.get("type")
    if schema_type == "object":
        properties = schema.get("properties", {})
        return {
            child_name: _schema_value(child_name, child_schema)
            for child_name, child_schema in properties.items()
            if child_name in schema.get("required", [])
        }
    if schema_type == "array":
        item_schema = schema.get("items", {})
        return [_schema_value("item", item_schema)] if item_schema else []
    if schema_type == "integer":
        return 1
    if schema_type == "number":
        return 1.0
    if schema_type == "boolean":
        return False
    return ""


def _tool_schema(tool) -> dict:
    # fastmcp has used both inputSchema and parameters on Tool across releases.
    return _schema_dict(
        getattr(tool, "inputSchema", None)
        or getattr(tool, "input_schema", None)
        or getattr(tool, "parameters", None)
    )


def _operation_args(tool, path: str, mode: str) -> dict:
    """Build a valid small brush request from the published JSON schema.

    Terrain brush argument names intentionally stay schema-driven here.  This
    keeps the smoke useful across the addon versions that used ``center`` vs
    ``position`` while still exercising the real promoted contract.
    """
    schema = _tool_schema(tool)
    properties = schema.get("properties", {})
    required = set(schema.get("required", []))
    args = {
        name: _schema_value(name, prop)
        for name, prop in properties.items()
        if name in required
    }

    for name in ("path", "terrain_path"):
        if name in properties:
            args[name] = path
    for name in ("mode", "operation", "kind", "algorithm"):
        if name in properties:
            prop = properties[name]
            values = prop.get("enum", [])
            if values:
                preferred = next(
                    (value for value in values if value == mode), values[0]
                )
                args[name] = preferred
    for name in ("radius", "brush_radius"):
        if name in properties:
            args[name] = 3.0
    for name in ("strength", "amount", "delta"):
        if name in properties:
            args[name] = 0.35
    for name in ("iterations", "steps"):
        if name in properties:
            args[name] = 2
    for name in ("seed",):
        if name in properties:
            args[name] = 101

    if "strokes" in properties and args.get("strokes"):
        stroke = args["strokes"][0]
        stroke.update(
            {"center_x": 0.0, "center_z": 0.0, "radius": 3.0, "strength": 0.35}
        )
        stroke_schema = properties["strokes"].get("items", {})
        mode_values = (
            stroke_schema.get("properties", {}).get("mode", {}).get("enum", [])
        )
        if mode_values:
            stroke["mode"] = mode if mode in mode_values else mode_values[0]
    if "areas" in properties and args.get("areas"):
        area = args["areas"][0]
        area.update({"center_x": 0.0, "center_z": 0.0, "radius": 3.0})
        area_schema = properties["areas"].get("items", {})
        mode_values = area_schema.get("properties", {}).get("mode", {}).get("enum", [])
        if mode_values:
            area["mode"] = mode if mode in mode_values else mode_values[0]

    for name in ("center", "position", "origin", "point"):
        if name not in properties:
            continue
        prop = properties[name]
        if prop.get("type") == "array":
            args[name] = [8.0, 8.0]
        elif prop.get("type") == "object":
            args[name] = {
                child_name: 8.0
                for child_name, child_schema in prop.get("properties", {}).items()
                if child_schema.get("type") in ("integer", "number")
            }
        else:
            args[name] = 8.0
    return args


def _schema_enum(tool, property_name: str):
    schema = _tool_schema(tool)
    prop = schema.get("properties", {}).get(property_name, {})
    enum = prop.get("enum", [])
    return enum[0] if enum else None


async def invoke_promoted_edit(client: Client, tool, path: str, mode: str) -> dict:
    args = _operation_args(tool, path, mode)
    result = await client.call_tool(tool.name, args)
    data = result.structured_content or {}
    if data.get("status") == "error" or data.get("error"):
        raise AssertionError(f"{tool.name} rejected smoke request: {data}")
    return data


async def invoke_busy(server_url: str, session_id: str, name: str):
    async with make_client(server_url) as client:
        try:
            result = await client.call_tool(
                "custom_terrain_create",
                {
                    "name": name,
                    "size": 128,
                    "generate_collision": False,
                    "session_id": session_id,
                },
            )
            return ("ok", result.structured_content or {})
        except ToolError as error:
            return ("error", str(error))


async def run(server_url: str, project_root: Path, timeout: float) -> None:
    client = await connect_client(server_url, timeout)
    try:
        session_id = await wait_for_session(client, project_root, timeout)
        # Promoted custom tools intentionally route through the active editor;
        # pin it explicitly so local multi-project servers cannot steal calls.
        await client.call_tool("session_activate", {"session_id": session_id})
        await wait_for_promoted_tools(client, timeout)
        promoted = {
            tool.name: tool
            for tool in await client.list_tools()
            if tool.name.startswith("custom_terrain_")
        }
        assert PROMOTED_TERRAIN_TOOLS <= promoted.keys(), promoted.keys()
        assert "custom_terrain_material" not in promoted, promoted.keys()
        registered_catalog = await wait_for_registered_tools(
            client, session_id, timeout
        )
        registered_names = {
            str(tool.get("name"))
            for tool in registered_catalog.get("tools", [])
            if isinstance(tool, dict) and tool.get("name")
        }
        assert REGISTERED_TERRAIN_TOOLS <= registered_names, registered_names

        tests = await client.call_tool(
            "test_run",
            {"suite": "terrain_tools", "session_id": session_id},
        )
        summary = tests.structured_content or {}
        suite_total = int(summary.get("total", 0))
        assert suite_total >= 21, summary
        assert summary.get("passed") == suite_total and summary.get("failed") == 0, (
            summary
        )

        create_args = {
            "name": "CITerrain",
            "size": 16,
            "cell_size": 1.25,
            "seed": 41,
            "generate_collision": True,
            "session_id": session_id,
        }
        material_preset = _schema_enum(
            promoted["custom_terrain_create"], "material_preset"
        )
        if material_preset is not None:
            create_args["material_preset"] = material_preset

        created = await client.call_tool(
            "custom_terrain_create",
            create_args,
        )
        create_data = created.structured_content or {}
        assert create_data.get("path") == "/TerrainDemo/CITerrain", create_data
        assert create_data.get("vertices") == 256, create_data
        assert create_data.get("triangles") == 450, create_data
        assert create_data.get("undoable") is True, create_data

        operation_results = {}
        for tool_name, mode in (
            ("custom_terrain_sculpt", "raise"),
            ("custom_terrain_holes", "cut"),
            ("custom_terrain_erode", "thermal"),
            ("custom_terrain_erode", "hydraulic"),
            ("custom_terrain_erode", "thermal_natural"),
            ("custom_terrain_erode", "hydraulic_natural"),
        ):
            args = _operation_args(promoted[tool_name], "/TerrainDemo/CITerrain", mode)
            if tool_name == "custom_terrain_sculpt":
                args["strokes"] = [
                    {
                        "center_x": 0.0,
                        "center_z": 0.0,
                        "radius": 3.0,
                        "mode": "raise",
                        "strength": 0.35,
                    },
                    {
                        "center_x": -9.0,
                        "center_z": -9.0,
                        "radius": 3.0,
                        "mode": "lower",
                        "strength": 0.2,
                        "falloff": "linear",
                    },
                    {
                        "center_x": 1.0,
                        "center_z": 1.0,
                        "radius": 2.5,
                        "mode": "smooth",
                        "strength": 0.4,
                    },
                    {
                        "center_x": 3.0,
                        "center_z": -2.0,
                        "radius": 2.0,
                        "mode": "flatten",
                        "strength": 0.5,
                        "target_height": 1.0,
                    },
                    {
                        "center_x": -2.0,
                        "center_z": 3.0,
                        "radius": 2.0,
                        "mode": "noise",
                        "strength": 0.25,
                        "seed": 17,
                    },
                ]
            args["session_id"] = session_id
            result = await client.call_tool(tool_name, args)
            result_data = result.structured_content or {}
            assert result_data.get("status") != "error", result_data
            assert not result_data.get("error"), result_data
            operation_results[mode] = result_data
        assert operation_results["raise"].get("affected_vertices", 0) > 0
        assert operation_results["cut"].get("hole_vertices", 0) > 0
        assert operation_results["thermal"].get("affected_vertices", 0) > 0
        assert operation_results["hydraulic"].get("affected_vertices", 0) > 0
        assert operation_results["thermal_natural"].get("affected_vertices", 0) > 0
        assert operation_results["hydraulic_natural"].get("affected_vertices", 0) > 0

        landform_result = await client.call_tool(
            "custom_terrain_landform",
            {
                "path": "/TerrainDemo/CITerrain",
                "features": [
                    {
                        "type": "ridge",
                        "points": [
                            {"x": -7.0, "z": -5.0},
                            {"x": 0.0, "z": 0.0},
                            {"x": 7.0, "z": 5.0},
                        ],
                        "width": 2.0,
                        "falloff_width": 2.0,
                        "profile": "sharp",
                        "height": 1.5,
                        "roughness": 0.15,
                        "scale": 3.0,
                        "seed": 31,
                    },
                    {
                        "type": "valley",
                        "points": [{"x": -7.0, "z": 6.0}, {"x": 7.0, "z": 6.0}],
                        "width": 2.5,
                        "falloff_width": 1.5,
                        "profile": "smooth",
                        "height": -0.5,
                        "seed": 32,
                    },
                ],
                "session_id": session_id,
            },
        )
        landform_data = landform_result.structured_content or {}
        assert landform_data.get("status") != "error" and not landform_data.get(
            "error"
        ), landform_data
        assert landform_data.get("affected_vertices", 0) > 0, landform_data

        road_result = await client.call_tool(
            "custom_terrain_road",
            {
                "path": "/TerrainDemo/CITerrain",
                "points": [
                    {"x": -7.0, "z": -6.0},
                    {"x": 0.0, "z": 0.0},
                    {"x": 7.0, "z": 6.0},
                ],
                "width": 2.5,
                "shoulder_width": 1.5,
                "elevation_mode": "follow_smooth",
                "max_grade": 1.0,
                "smoothing_passes": 2,
                "falloff": "smooth",
                "paint_road": True,
                "session_id": session_id,
            },
        )
        road_data = road_result.structured_content or {}
        assert road_data.get("status") != "error" and not road_data.get("error"), (
            road_data
        )
        assert road_data.get("affected_vertices", 0) > 0, road_data
        assert road_data.get("painted_vertices", 0) > 0, road_data

        paint_result = await client.call_tool(
            "custom_terrain_paint",
            {
                "path": "/TerrainDemo/CITerrain",
                "strokes": [
                    {
                        "points": [
                            {"x": -6.0, "z": 0.0},
                            {"x": 0.0, "z": 0.0},
                            {"x": 6.0, "z": 0.0},
                        ],
                        "radius": 1.5,
                        "strength": 0.8,
                        "falloff": "smooth",
                        "layer": "road",
                    }
                ],
                "session_id": session_id,
            },
        )
        paint_data = paint_result.structured_content or {}
        assert paint_data.get("status") != "error" and not paint_data.get("error"), (
            paint_data
        )
        assert paint_data.get("affected_vertices", 0) > 0, paint_data

        material_result = await client.call_tool(
            "custom_manage",
            {
                "op": "invoke",
                "params": {
                    "tool_name": "terrain_material",
                    "params": {
                        "path": "/TerrainDemo/CITerrain",
                        "material_preset": "desert",
                    },
                },
                "session_id": session_id,
            },
        )
        material_data = material_result.structured_content or {}
        assert material_data.get("status") != "error" and not material_data.get(
            "error"
        ), material_data
        material_params = material_data.get("params", {})
        assert material_params.get("material_preset") == "desert", material_data
        assert "render_mode" not in material_params, material_data

        fill_args = _operation_args(
            promoted["custom_terrain_holes"], "/TerrainDemo/CITerrain", "fill"
        )
        fill_args["session_id"] = session_id
        filled = await client.call_tool("custom_terrain_holes", fill_args)
        fill_data = filled.structured_content or {}
        assert fill_data.get("hole_vertices") == 0, fill_data

        try:
            await client.call_tool(
                "custom_terrain_regenerate",
                {
                    "path": "/TerrainDemo/CITerrain",
                    "size": 20,
                    "session_id": session_id,
                },
            )
        except ToolError as error:
            assert "terrain_tools.MODIFICATIONS_EXIST" in str(error), error
        else:
            raise AssertionError("size change did not require reset_modifications")

        collision_shape = await client.call_tool(
            "node_get_properties",
            {
                "path": "/TerrainDemo/CITerrain/TerrainCollision/CollisionShape3D",
                "session_id": session_id,
            },
        )
        assert (collision_shape.structured_content or {}).get(
            "node_type"
        ) == "CollisionShape3D"

        material_values = (
            _tool_schema(promoted["custom_terrain_regenerate"])
            .get("properties", {})
            .get("material_preset", {})
            .get("enum", [])
        )
        replacement_material = (
            material_values[1] if len(material_values) > 1 else "desert"
        )
        regenerated = await client.call_tool(
            "custom_terrain_regenerate",
            {
                "path": "/TerrainDemo/CITerrain",
                "seed": 99,
                "size": 20,
                "generate_collision": False,
                "material_preset": replacement_material,
                "reset_modifications": True,
                "session_id": session_id,
            },
        )
        regenerate_data = regenerated.structured_content or {}
        effective = regenerate_data.get("params", {})
        assert effective.get("size") == 20 and effective.get("cell_size") == 1.25, (
            regenerate_data
        )
        assert (
            effective.get("seed") == 99 and effective.get("generate_collision") is False
        ), regenerate_data
        assert effective.get("material_preset") == replacement_material, regenerate_data
        try:
            await client.call_tool(
                "node_get_properties",
                {
                    "path": "/TerrainDemo/CITerrain/TerrainCollision",
                    "session_id": session_id,
                },
            )
        except ToolError as error:
            assert "NODE_NOT_FOUND" in str(error), error
        else:
            raise AssertionError("regeneration did not remove TerrainCollision")
    finally:
        await client.__aexit__(None, None, None)

    busy_results = await asyncio.gather(
        invoke_busy(server_url, session_id, "CIBusyA"),
        invoke_busy(server_url, session_id, "CIBusyB"),
    )
    successes = [value for status, value in busy_results if status == "ok"]
    failures = [value for status, value in busy_results if status == "error"]
    assert len(successes) == 1, busy_results
    assert len(failures) == 1, busy_results
    assert "terrain_tools.BUSY" in failures[0] and "retryable=True" in failures[0], (
        failures[0]
    )
    print(
        f"Live smoke passed: {suite_total} tests, 8 promoted/9 registered terrain tools, "
        "landforms, road grading, semantic paint, colour palettes, collision, "
        "persistence, compatibility/natural erosion, BUSY"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-url", default="http://127.0.0.1:8000/mcp")
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args()
    asyncio.run(run(args.server_url, args.project_root, args.timeout))


if __name__ == "__main__":
    main()
