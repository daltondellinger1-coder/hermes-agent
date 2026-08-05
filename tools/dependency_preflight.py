"""Dependency preflight for configured MCP servers and cron entrypoints.

The checks are deliberately side-effect free: Python files are parsed for
imports and those modules are resolved by the exact interpreter that will run
the entrypoint.  Results are persisted for the Windows host supervisor, which
owns the sole out-of-band alert transport.
"""

from __future__ import annotations

import ast
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any


PROBE_INTERVAL_SECONDS = 600.0
_PACKAGE_FIXES = {
    "composio_client": "composio-client",
    "websocket": "websocket-client",
    "yaml": "PyYAML",
    "cv2": "opencv-python",
}
_probe_cache: dict[str, tuple[float, list[dict[str, str]]]] = {}
_report_lock = threading.Lock()


def _hermes_home() -> Path:
    return Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes")).expanduser()


def _report_path() -> Path:
    return _hermes_home() / "state" / "dependency-preflight.json"


def _imports(path: Path, *, top_level_only: bool = False) -> set[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    found: set[str] = set()

    def visit(node: ast.AST) -> None:
        if isinstance(node, ast.Import):
            found.update(alias.name.split(".", 1)[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            found.add(node.module.split(".", 1)[0])
        elif top_level_only and isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
            return
        for child in ast.iter_child_nodes(node):
            visit(child)

    visit(tree)
    return found


def _missing_modules(interpreter: str, script: Path, *, top_level_only: bool = False) -> list[str]:
    modules = sorted(_imports(script, top_level_only=top_level_only))
    if not modules:
        return []
    helper = (
        "import importlib.util,json,sys;"
        "sys.path.insert(0,sys.argv[2]);"
        "print(json.dumps([m for m in json.loads(sys.argv[1]) "
        "if importlib.util.find_spec(m) is None]))"
    )
    result = subprocess.run(
        [interpreter, "-c", helper, json.dumps(modules), str(script.parent)],
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        return ["<interpreter-unavailable>"]
    return list(json.loads(result.stdout))


def _issue(kind: str, name: str, module: str, interpreter: str) -> dict[str, str]:
    package = _PACKAGE_FIXES.get(module, module)
    return {
        "id": f"{kind}:{name}:{module}",
        "kind": kind,
        "name": name,
        "module": module,
        "fix": f"{interpreter} -m pip install {package}",
    }


def probe_mcp_server(name: str, config: dict[str, Any], *, force: bool = False) -> list[dict[str, str]]:
    """Return dependency issues for one stdio Python MCP server.

    Results, including success, are cached for ten minutes.  A quarantined
    server is therefore auto-probed on a slow interval rather than on every
    agent session.
    """
    now = time.monotonic()
    cached = _probe_cache.get(name)
    if cached and not force and now - cached[0] < PROBE_INTERVAL_SECONDS:
        return cached[1]
    command = str(config.get("command") or "")
    args = [str(value) for value in config.get("args", [])]
    script_arg = next((value for value in args if value.endswith(".py")), "")
    issues: list[dict[str, str]] = []
    if script_arg:
        script = Path(script_arg).expanduser()
        if not script.is_file():
            issues.append(_issue("mcp", name, "<entrypoint-missing>", command))
        else:
            for module in _missing_modules(command, script, top_level_only=True):
                issues.append(_issue("mcp", name, module, command))
    _probe_cache[name] = (now, issues)
    return issues


def _cron_issues() -> list[dict[str, str]]:
    jobs_path = _hermes_home() / "cron" / "jobs.json"
    if not jobs_path.is_file():
        return []
    payload = json.loads(jobs_path.read_text(encoding="utf-8"))
    jobs = payload.get("jobs", payload if isinstance(payload, list) else [])
    issues: list[dict[str, str]] = []
    scripts_dir = _hermes_home() / "scripts"
    for job in jobs:
        script_value = job.get("script") if isinstance(job, dict) else None
        if not script_value:
            continue
        path = Path(str(script_value)).expanduser()
        if not path.is_absolute():
            path = scripts_dir / path
        name = str(job.get("name") or job.get("id") or path.name)
        if not path.is_file():
            issues.append(_issue("cron", name, "<entrypoint-missing>", sys.executable))
        elif path.suffix.lower() not in {".sh", ".bash"}:
            for module in _missing_modules(sys.executable, path):
                issues.append(_issue("cron", name, module, sys.executable))
    return issues


def write_report(mcp_servers: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """Run startup preflight and atomically publish its actionable report."""
    issues = _cron_issues()
    for name, config in mcp_servers.items():
        if config.get("enabled", True) and "url" not in config:
            issues.extend(probe_mcp_server(name, config, force=True))
    report = {"schema_version": 1, "checked_at": time.time(), "issues": issues}
    _write_report(report)
    return report


def _write_report(report: dict[str, Any]) -> None:
    path = _report_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _mutate_report(change: Any) -> None:
    with _report_lock:
        path = _report_path()
        try:
            report = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            report = {"schema_version": 1, "checked_at": time.time(), "issues": []}
        change(report["issues"])
        report["checked_at"] = time.time()
        _write_report(report)


def record_runtime_quarantine(name: str) -> None:
    """Publish one actionable issue after repeated MCP connection failures."""
    issue = {
        "id": f"mcp-runtime:{name}:server-startup",
        "kind": "mcp",
        "name": name,
        "module": "<server-startup>",
        "fix": "Correct the server command, credentials, or dependencies; automatic probing retries within 10 minutes.",
    }

    def add(issues: list[dict[str, str]]) -> None:
        if not any(value.get("id") == issue["id"] for value in issues):
            issues.append(issue)

    _mutate_report(add)


def clear_runtime_quarantine(name: str) -> None:
    issue_id = f"mcp-runtime:{name}:server-startup"
    _mutate_report(lambda issues: issues.__setitem__(slice(None), [
        value for value in issues if value.get("id") != issue_id
    ]))


def filter_quarantined_servers(servers: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Exclude dependency-broken servers until their slow probe succeeds."""
    probes = {name: probe_mcp_server(name, config) for name, config in servers.items()}

    def reconcile(issues: list[dict[str, str]]) -> None:
        names = set(servers)
        issues[:] = [
            value for value in issues
            if not (value.get("kind") == "mcp" and value.get("name") in names
                    and not str(value.get("id", "")).startswith("mcp-runtime:"))
        ]
        for found in probes.values():
            issues.extend(found)

    _mutate_report(reconcile)
    return {name: config for name, config in servers.items() if not probes[name]}
