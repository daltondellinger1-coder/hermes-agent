from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import venv

from tools import dependency_preflight


def _venv_python(root: Path) -> Path:
    return root / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")


def test_scratch_venv_quarantines_names_and_recovers(tmp_path, monkeypatch):
    home = tmp_path / "home"
    scripts = home / "scripts"
    scripts.mkdir(parents=True)
    server = scripts / "broken_server.py"
    server.write_text("import wp7_missing_fixture\n", encoding="utf-8")
    environment = tmp_path / "venv"
    venv.EnvBuilder(with_pip=False).create(environment)
    python = _venv_python(environment)
    config = {"broken": {"command": str(python), "args": [str(server)]}}
    monkeypatch.setenv("HERMES_HOME", str(home))
    dependency_preflight._probe_cache.clear()

    report = dependency_preflight.write_report(config)
    assert report["issues"] == [{
        "id": "mcp:broken:wp7_missing_fixture",
        "kind": "mcp",
        "name": "broken",
        "module": "wp7_missing_fixture",
        "fix": f"{python} -m pip install wp7_missing_fixture",
    }]
    assert dependency_preflight.filter_quarantined_servers(config) == {}
    persisted = json.loads((home / "state/dependency-preflight.json").read_text())
    assert persisted["issues"] == report["issues"]

    site_packages = subprocess.check_output(
        [str(python), "-c", "import sysconfig; print(sysconfig.get_paths()['purelib'])"],
        text=True,
    ).strip()
    Path(site_packages, "wp7_missing_fixture.py").write_text("VALUE = 1\n", encoding="utf-8")
    assert dependency_preflight.probe_mcp_server("broken", config["broken"], force=True) == []
    assert dependency_preflight.filter_quarantined_servers(config) == config


def test_cron_entrypoint_uses_runtime_interpreter(tmp_path, monkeypatch):
    home = tmp_path / "home"
    scripts = home / "scripts"
    scripts.mkdir(parents=True)
    (scripts / "job.py").write_text("import definitely_missing_wp7_cron\n", encoding="utf-8")
    cron = home / "cron"
    cron.mkdir()
    (cron / "jobs.json").write_text(json.dumps({"jobs": [{
        "id": "occupancy", "name": "Occupancy", "script": "job.py"
    }]}), encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(home))
    report = dependency_preflight.write_report({})
    assert [(item["kind"], item["name"], item["module"]) for item in report["issues"]] == [
        ("cron", "Occupancy", "definitely_missing_wp7_cron")
    ]


def test_runtime_quarantine_is_single_and_clears(tmp_path, monkeypatch):
    home = tmp_path / "home"
    monkeypatch.setenv("HERMES_HOME", str(home))
    dependency_preflight.record_runtime_quarantine("unstable")
    dependency_preflight.record_runtime_quarantine("unstable")
    path = home / "state/dependency-preflight.json"
    report = json.loads(path.read_text())
    assert [issue["id"] for issue in report["issues"]] == [
        "mcp-runtime:unstable:server-startup"
    ]
    dependency_preflight.clear_runtime_quarantine("unstable")
    assert json.loads(path.read_text())["issues"] == []
