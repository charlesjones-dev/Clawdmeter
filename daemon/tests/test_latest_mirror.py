#!/usr/bin/env python3
"""latest.json mirror for the desktop simulator's live mode: written atomically
on every device send (both Python daemons) and by the macOS daemon's headless
poller when no device is reachable."""
import asyncio
import json
import time
from unittest.mock import AsyncMock, patch

import pytest

import daemon.claude_usage_daemon as macos
import daemon.claude_usage_daemon_windows as win


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


@pytest.mark.parametrize("mod", [macos, win], ids=["macos", "windows"])
def test_write_latest_creates_dir_and_is_compact(mod, tmp_path, monkeypatch):
    target = tmp_path / "nested" / "latest.json"
    monkeypatch.setattr(mod, "LATEST_FILE", target)
    mod.write_latest({"s": 1, "ok": True})
    assert json.loads(target.read_text()) == {"s": 1, "ok": True}
    assert target.read_text() == '{"s":1,"ok":true}\n'
    assert not (tmp_path / "nested" / "latest.json.tmp").exists()   # renamed, not left behind


@pytest.mark.parametrize("mod", [macos, win], ids=["macos", "windows"])
def test_write_payload_mirrors_before_ble_write(mod, tmp_path, monkeypatch):
    target = tmp_path / "latest.json"
    monkeypatch.setattr(mod, "LATEST_FILE", target)
    client = AsyncMock()
    client.write_gatt_char = AsyncMock(side_effect=RuntimeError("ble down"))
    session = mod.Session(client)
    # Even a failed BLE write leaves the mirror updated — the sim must not be
    # held hostage by the radio.
    with pytest.raises(RuntimeError):
        _run(session.write_payload({"s": 42, "ok": True}))
    assert json.loads(target.read_text())["s"] == 42


def test_write_latest_failure_is_logged_not_raised(tmp_path, monkeypatch):
    monkeypatch.setattr(macos, "LATEST_FILE", tmp_path)   # a directory: write fails
    logs = []
    monkeypatch.setattr(macos, "log", logs.append)
    macos.write_latest({"ok": False})
    assert any("Could not write" in m for m in logs)


def test_headless_poller_respects_interval_and_writes(tmp_path, monkeypatch):
    target = tmp_path / "latest.json"
    monkeypatch.setattr(macos, "LATEST_FILE", target)
    monkeypatch.setattr(macos, "POLL_INTERVAL", 60)
    calls = []

    async def fake_poll_active():
        calls.append(time.time())
        return ({"s": 7, "ok": True}, False)

    with patch.object(macos, "poll_active", new=fake_poll_active):
        hp = macos.HeadlessPoller()
        _run(hp.tick())
        _run(hp.tick())          # within the interval: no second poll
    assert len(calls) == 1
    assert json.loads(target.read_text())["s"] == 7


def test_headless_poller_dead_token_writes_no_data_beat(tmp_path, monkeypatch):
    target = tmp_path / "latest.json"
    monkeypatch.setattr(macos, "LATEST_FILE", target)

    async def fake_poll_active():
        return (None, True)

    with patch.object(macos, "poll_active", new=fake_poll_active):
        _run(macos.HeadlessPoller().tick())
    assert json.loads(target.read_text()) == {"ok": False}
