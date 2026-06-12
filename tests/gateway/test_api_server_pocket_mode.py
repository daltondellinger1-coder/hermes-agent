from __future__ import annotations

import json

import pytest
from aiohttp import web

from gateway.config import PlatformConfig
from gateway.platforms.api_server import APIServerAdapter


class _Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)


class _Request:
    def __init__(self, body=None, match_info=None):
        self.headers = _Headers({"Authorization": "Bearer test-key"})
        self.transport = None
        self.remote = "127.0.0.1"
        self.method = "POST"
        self.path_qs = "/test"
        self.match_info = match_info or {}
        self._body = body or {}

    async def json(self):
        return self._body


@pytest.mark.asyncio
async def test_pocket_session_create_get_and_idle_stop():
    adapter = APIServerAdapter(PlatformConfig(enabled=True, extra={"key": "test-key"}))

    created = await adapter._handle_create_pocket_session(
        _Request({"label": "Smoke", "client": "pytest"})
    )
    assert created.status == 201
    created_body = json.loads(created.text)
    session_id = created_body["session_id"]
    assert session_id.startswith("pocket_")
    assert created_body["status"] == "idle"

    fetched = await adapter._handle_get_pocket_session(
        _Request(match_info={"session_id": session_id})
    )
    assert fetched.status == 200
    assert json.loads(fetched.text)["session_id"] == session_id

    stopped = await adapter._handle_stop_pocket_session(
        _Request(match_info={"session_id": session_id})
    )
    assert stopped.status == 200
    assert json.loads(stopped.text)["status"] == "idle"


@pytest.mark.asyncio
async def test_pocket_command_requires_text():
    adapter = APIServerAdapter(PlatformConfig(enabled=True, extra={"key": "test-key"}))
    created = await adapter._handle_create_pocket_session(_Request({}))
    session_id = json.loads(created.text)["session_id"]

    response = await adapter._handle_pocket_command(
        _Request({}, {"session_id": session_id})
    )
    assert response.status == 400
    assert json.loads(response.text)["error"]["code"] == "missing_command"


@pytest.mark.asyncio
async def test_pocket_command_delegates_to_runs_and_returns_session_urls(monkeypatch):
    adapter = APIServerAdapter(PlatformConfig(enabled=True, extra={"key": "test-key"}))
    created = await adapter._handle_create_pocket_session(
        _Request({"session_id": "phone-pocket", "label": "Phone"})
    )
    assert created.status == 201

    captured = {}

    async def fake_handle_runs(request):
        captured["body"] = await request.json()
        captured["headers"] = request.headers
        return web.json_response({"run_id": "run_123", "status": "started"}, status=202)

    monkeypatch.setattr(adapter, "_handle_runs", fake_handle_runs)

    response = await adapter._handle_pocket_command(
        _Request({"command": "status please"}, {"session_id": "phone-pocket"})
    )

    assert response.status == 202
    body = json.loads(response.text)
    assert captured["body"]["input"] == "status please"
    assert captured["body"]["session_id"] == "phone-pocket"
    assert "voice-friendly" in captured["body"]["instructions"]
    assert body["object"] == "hermes.pocket_command"
    assert body["pocket_session_id"] == "phone-pocket"
    assert body["events_url"] == "/v1/pocket/sessions/phone-pocket/events"
    assert body["status_url"] == "/v1/pocket/sessions/phone-pocket"
    assert body["run_events_url"] == "/v1/runs/run_123/events"
    assert body["run_status_url"] == "/v1/runs/run_123"

    session = adapter._pocket_sessions["phone-pocket"]
    assert session["status"] == "running"
    assert session["active_run_id"] == "run_123"
    assert session["last_command"] == "status please"


@pytest.mark.asyncio
async def test_pocket_status_embeds_active_run_status():
    adapter = APIServerAdapter(PlatformConfig(enabled=True, extra={"key": "test-key"}))
    await adapter._handle_create_pocket_session(_Request({"session_id": "phone-pocket"}))
    adapter._pocket_sessions["phone-pocket"]["active_run_id"] = "run_123"
    adapter._set_run_status("run_123", "running", last_event="message.delta")

    response = await adapter._handle_get_pocket_session(
        _Request(match_info={"session_id": "phone-pocket"})
    )

    assert response.status == 200
    body = json.loads(response.text)
    assert body["run_status"]["run_id"] == "run_123"
    assert body["run_status"]["status"] == "running"
    assert body["run_status"]["last_event"] == "message.delta"


@pytest.mark.asyncio
async def test_pocket_events_proxy_requires_active_run_and_delegates(monkeypatch):
    adapter = APIServerAdapter(PlatformConfig(enabled=True, extra={"key": "test-key"}))
    await adapter._handle_create_pocket_session(_Request({"session_id": "phone-pocket"}))

    idle = await adapter._handle_pocket_session_events(
        _Request(match_info={"session_id": "phone-pocket"})
    )
    assert idle.status == 409
    assert json.loads(idle.text)["error"]["code"] == "no_active_run"

    adapter._pocket_sessions["phone-pocket"]["active_run_id"] = "run_123"
    captured = {}

    async def fake_handle_run_events(request):
        captured["match_info"] = dict(request.match_info)
        return web.json_response({"proxied": True})

    monkeypatch.setattr(adapter, "_handle_run_events", fake_handle_run_events)

    response = await adapter._handle_pocket_session_events(
        _Request(match_info={"session_id": "phone-pocket"})
    )

    assert response.status == 200
    assert captured["match_info"] == {"run_id": "run_123"}
    assert json.loads(response.text) == {"proxied": True}


@pytest.mark.asyncio
async def test_pocket_stop_delegates_to_active_run(monkeypatch):
    adapter = APIServerAdapter(PlatformConfig(enabled=True, extra={"key": "test-key"}))
    await adapter._handle_create_pocket_session(_Request({"session_id": "phone-pocket"}))
    adapter._pocket_sessions["phone-pocket"]["active_run_id"] = "run_123"
    captured = {}

    async def fake_handle_stop_run(request):
        captured["match_info"] = dict(request.match_info)
        return web.json_response({"run_id": "run_123", "status": "stopping"}, status=202)

    monkeypatch.setattr(adapter, "_handle_stop_run", fake_handle_stop_run)

    response = await adapter._handle_stop_pocket_session(
        _Request(match_info={"session_id": "phone-pocket"})
    )

    assert response.status == 202
    assert captured["match_info"] == {"run_id": "run_123"}
    assert adapter._pocket_sessions["phone-pocket"]["status"] == "stopping"
