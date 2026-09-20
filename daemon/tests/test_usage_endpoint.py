#!/usr/bin/env python3
"""Tests for the OAuth usage endpoint path (GET /api/oauth/usage) in both Python
daemons: payload projection, the model-scoped weekly row ("m"/"mr"/"ml"), and the
fallback to the rate-limit-header probe. No network — httpx is mocked.

Run: python -m pytest daemon/tests/test_usage_endpoint.py -q
"""
import asyncio
import json
import time
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

import daemon.claude_usage_daemon as macos
import daemon.claude_usage_daemon_windows as win

FIXTURE = Path(__file__).parent / "fixtures" / "oauth_usage_promax.json"


def _fixture(now: float) -> dict:
    """Fixture with reset times re-anchored relative to `now` so the minute
    arithmetic is deterministic: 5h resets in 3h, weekly rows in 4d 5h."""
    d = json.loads(FIXTURE.read_text())
    import datetime
    iso = lambda secs: datetime.datetime.fromtimestamp(now + secs, datetime.timezone.utc).isoformat()
    d["five_hour"]["resets_at"] = iso(3 * 3600)
    d["seven_day"]["resets_at"] = iso(4 * 86400 + 5 * 3600)
    for row in d["limits"]:
        row["resets_at"] = d["five_hour"]["resets_at"] if row["kind"] == "session" else d["seven_day"]["resets_at"]
    return d


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def _resp(status=200, body=None, headers=None):
    r = MagicMock()
    r.status_code = status
    r.text = "mocked"
    r.json = lambda: body
    hdrs = {k.lower(): v for k, v in (headers or {}).items()}
    r.headers = MagicMock()
    r.headers.get = lambda name, default=None: hdrs.get(name.lower(), default)
    return r


def _client(get_resp=None, post_resp=None):
    c = AsyncMock()
    c.__aenter__ = AsyncMock(return_value=c)
    c.__aexit__ = AsyncMock(return_value=False)
    c.get = AsyncMock(return_value=get_resp if get_resp is not None else _resp(404, {}))
    c.post = AsyncMock(return_value=post_resp if post_resp is not None else _resp(500, {}))
    return c


@pytest.mark.parametrize("mod", [macos, win], ids=["macos", "windows"])
def test_projection_promax_with_scoped_row(mod):
    now = time.time()
    p = mod._payload_from_usage_json(_fixture(now), now)
    assert p["s"] == 4 and p["w"] == 18
    assert p["acct"] == "pro" and p["ok"] is True and p["st"] == "allowed"
    assert abs(p["sr"] - 180) <= 1
    assert abs(p["wr"] - (4 * 1440 + 300)) <= 1
    # model-scoped weekly row
    assert p["m"] == 32 and p["ml"] == "Fable"
    assert abs(p["mr"] - (4 * 1440 + 300)) <= 1


@pytest.mark.parametrize("mod", [macos, win], ids=["macos", "windows"])
def test_projection_without_scoped_row_omits_m_keys(mod):
    now = time.time()
    d = _fixture(now)
    d["limits"] = [r for r in d["limits"] if r["kind"] != "weekly_scoped"]
    p = mod._payload_from_usage_json(d, now)
    assert "m" not in p and "mr" not in p and "ml" not in p


@pytest.mark.parametrize("mod", [macos, win], ids=["macos", "windows"])
def test_projection_label_clipped_and_bad_rows_skipped(mod):
    now = time.time()
    d = _fixture(now)
    d["limits"] = [
        {"kind": "weekly_scoped", "group": "weekly", "percent": 10, "scope": None},           # no model
        {"kind": "weekly_scoped", "group": "weekly", "percent": None,                        # no percent
         "scope": {"model": {"display_name": "Nope"}}},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 77.4,
         "scope": {"model": {"display_name": "A Very Long Model Name"}}, "resets_at": None},
    ]
    p = mod._payload_from_usage_json(d, now)
    assert p["m"] == 77 and p["ml"] == "A Very Long Mod" and len(p["ml"]) == 15
    assert p["mr"] == 0


@pytest.mark.parametrize("mod", [macos, win], ids=["macos", "windows"])
def test_projection_enterprise_shape_returns_none(mod):
    d = {"five_hour": None, "seven_day": None, "limits": [], "extra_usage": {"utilization": 40}}
    assert mod._payload_from_usage_json(d, time.time()) is None
    assert mod._payload_from_usage_json("garbage", time.time()) is None


@pytest.mark.parametrize("mod", [macos, win], ids=["macos", "windows"])
def test_projection_at_limit_reports_rejected(mod):
    now = time.time()
    d = _fixture(now)
    d["five_hour"]["utilization"] = 100.0
    assert mod._payload_from_usage_json(d, now)["st"] == "rejected"


@pytest.mark.parametrize("mod", [macos, win], ids=["macos", "windows"])
def test_iso_parsing_variants(mod):
    import datetime
    now = 1_800_000_000.0
    want = datetime.datetime(2027, 1, 15, tzinfo=datetime.timezone.utc).timestamp()
    assert mod._iso_to_epoch("2027-01-15T00:00:00Z") == want
    assert mod._iso_to_epoch("2027-01-15T00:00:00+00:00") == want
    assert mod._iso_to_epoch("2027-01-15T00:00:00.123456+00:00") == want + 0.123456
    assert mod._iso_to_epoch(None) is None and mod._iso_to_epoch("") is None
    assert mod._iso_to_epoch("not a date") is None
    assert mod._minutes_until(now - 5, now) == 0
    assert mod._minutes_until(None, now) == 0


@pytest.mark.parametrize("mod", [macos, win], ids=["macos", "windows"])
def test_poll_api_uses_endpoint_and_skips_probe(mod):
    now = time.time()
    client = _client(get_resp=_resp(200, _fixture(now)))
    with patch("httpx.AsyncClient", return_value=client):
        payload = _run(mod.poll_api("fake-token"))
    assert payload["s"] == 4 and payload["m"] == 32 and payload["ml"] == "Fable"
    client.get.assert_awaited_once()
    client.post.assert_not_awaited()
    args, kwargs = client.get.await_args
    assert args[0] == mod.USAGE_URL
    assert kwargs["headers"]["Authorization"] == "Bearer fake-token"
    assert kwargs["headers"]["anthropic-beta"] == "oauth-2025-04-20"


@pytest.mark.parametrize("mod", [macos, win], ids=["macos", "windows"])
def test_poll_api_falls_back_to_headers_when_endpoint_fails(mod):
    now = time.time()
    probe = _resp(200, headers={
        "anthropic-ratelimit-unified-5h-utilization": "0.42",
        "anthropic-ratelimit-unified-5h-reset": str(now + 3600),
        "anthropic-ratelimit-unified-7d-utilization": "0.10",
        "anthropic-ratelimit-unified-7d-reset": str(now + 86400),
        "anthropic-ratelimit-unified-5h-status": "allowed",
    })
    for get_resp in (_resp(500, {}), _resp(403, {}), _resp(200, {"five_hour": None, "limits": []})):
        client = _client(get_resp=get_resp, post_resp=probe)
        with patch("httpx.AsyncClient", return_value=client):
            payload = _run(mod.poll_api("fake-token"))
        assert payload["s"] == 42 and payload["w"] == 10 and "m" not in payload
        client.post.assert_awaited_once()


@pytest.mark.parametrize("mod", [macos, win], ids=["macos", "windows"])
def test_poll_api_falls_back_on_endpoint_network_error(mod):
    import httpx
    now = time.time()
    probe = _resp(200, headers={
        "anthropic-ratelimit-unified-5h-utilization": "0.5",
        "anthropic-ratelimit-unified-5h-reset": str(now + 3600),
        "anthropic-ratelimit-unified-7d-utilization": "0.5",
        "anthropic-ratelimit-unified-7d-reset": str(now + 86400),
    })
    client = _client(post_resp=probe)
    client.get = AsyncMock(side_effect=httpx.ConnectError("boom"))
    with patch("httpx.AsyncClient", return_value=client):
        payload = _run(mod.poll_api("fake-token"))
    assert payload["s"] == 50


@pytest.mark.parametrize("mod", [macos, win], ids=["macos", "windows"])
def test_poll_api_endpoint_auth_error_defers_to_probe(mod):
    """A 401 on the usage endpoint alone must not be read as an expired token —
    the probe owns that verdict (a token could lack user:profile scope)."""
    client = _client(get_resp=_resp(401, {}), post_resp=_resp(401, {}))
    err = macos.TokenExpired if mod is macos else win.AuthError
    with patch("httpx.AsyncClient", return_value=client):
        with pytest.raises(err):
            _run(mod.poll_api("fake-token"))
    client.post.assert_awaited_once()
