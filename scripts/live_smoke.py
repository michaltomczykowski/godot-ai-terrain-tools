"""Exercise the installed addon through a live Godot AI MCP server."""

from __future__ import annotations

import argparse
import asyncio
from contextlib import suppress
from pathlib import Path
import time

from fastmcp import Client
from fastmcp.exceptions import ToolError


async def connect_client(server_url: str, timeout: float) -> Client:
    """Connect after the MCP server becomes ready, or fail at the deadline."""
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        client = Client(server_url)
        try:
            await client.__aenter__()
            return client
        except Exception as error:
            last_error = error
            with suppress(Exception):
                await client.__aexit__(type(error), error, error.__traceback__)
            await asyncio.sleep(1)
    raise RuntimeError(f"Godot AI server at {server_url} did not become ready") from last_error


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
    expected = {"custom_terrain_create", "custom_terrain_regenerate"}
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        names = {tool.name for tool in await client.list_tools()}
        if expected <= names:
            return
        await asyncio.sleep(0.5)
    raise RuntimeError("promoted terrain tools were not exposed by tools/list")


async def invoke_busy(server_url: str, session_id: str, name: str):
    async with Client(server_url) as client:
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
        await wait_for_promoted_tools(client, timeout)

        tests = await client.call_tool(
            "test_run",
            {"suite": "terrain_tools", "session_id": session_id},
        )
        summary = tests.structured_content or {}
        assert summary.get("total") == 21, summary
        assert summary.get("passed") == 21 and summary.get("failed") == 0, summary

        created = await client.call_tool(
            "custom_terrain_create",
            {
                "name": "CITerrain",
                "size": 16,
                "cell_size": 1.25,
                "seed": 41,
                "generate_collision": True,
                "session_id": session_id,
            },
        )
        create_data = created.structured_content or {}
        assert create_data.get("path") == "/TerrainDemo/CITerrain", create_data
        assert create_data.get("vertices") == 256, create_data
        assert create_data.get("triangles") == 450, create_data
        assert create_data.get("undoable") is True, create_data

        collision_shape = await client.call_tool(
            "node_get_properties",
            {
                "path": "/TerrainDemo/CITerrain/TerrainCollision/CollisionShape3D",
                "session_id": session_id,
            },
        )
        assert (collision_shape.structured_content or {}).get("node_type") == "CollisionShape3D"

        regenerated = await client.call_tool(
            "custom_terrain_regenerate",
            {
                "path": "/TerrainDemo/CITerrain",
                "seed": 99,
                "generate_collision": False,
                "session_id": session_id,
            },
        )
        regenerate_data = regenerated.structured_content or {}
        effective = regenerate_data.get("params", {})
        assert effective.get("size") == 16 and effective.get("cell_size") == 1.25, regenerate_data
        assert effective.get("seed") == 99 and effective.get("generate_collision") is False, regenerate_data
        try:
            await client.call_tool(
                "node_get_properties",
                {"path": "/TerrainDemo/CITerrain/TerrainCollision", "session_id": session_id},
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
    assert "terrain_tools.BUSY" in failures[0] and "retryable=True" in failures[0], failures[0]
    print("Live smoke passed: 21 tests, promoted create/regenerate, collision, persistence, BUSY")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-url", default="http://127.0.0.1:8000/mcp")
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args()
    asyncio.run(run(args.server_url, args.project_root, args.timeout))


if __name__ == "__main__":
    main()
