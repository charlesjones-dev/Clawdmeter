#!/usr/bin/env python3
"""Side-button key bindings: name -> HID parsing, config reading with defaults
and fallbacks, and the "bl"/"br" payload fields — for both Python daemons.

Run: python -m pytest daemon/tests/test_buttons.py -q
"""
import pytest

import daemon.claude_usage_daemon as macos
import daemon.claude_usage_daemon_windows as win

MODS = [macos, win]
IDS = ["macos", "windows"]


@pytest.mark.parametrize("mod", MODS, ids=IDS)
@pytest.mark.parametrize("spec,want", [
    ("space", (0x2C, 0)),
    ("tab", (0x2B, 0)),
    ("enter", (0x28, 0)),
    ("return", (0x28, 0)),
    ("shift+tab", (0x2B, 0x02)),
    ("Shift + Tab", (0x2B, 0x02)),
    ("ctrl+shift+p", (0x13, 0x03)),
    ("cmd+k", (0x0E, 0x08)),
    ("alt+f4", (0x3D, 0x04)),
    ("ctrl+alt+delete", (0x4C, 0x05)),
    ("a", (0x04, 0)), ("z", (0x1D, 0)), ("1", (0x1E, 0)), ("0", (0x27, 0)),
    ("f1", (0x3A, 0)), ("f12", (0x45, 0)),
    ("up", (0x52, 0)), ("esc", (0x29, 0)),
    ("shift", (0, 0x02)),            # modifier-only chord
    ("none", (0, 0)), ("OFF", (0, 0)),
])
def test_parse_key_spec_valid(mod, spec, want):
    assert mod.parse_key_spec(spec) == want


@pytest.mark.parametrize("mod", MODS, ids=IDS)
@pytest.mark.parametrize("spec", ["bogus", "tab+ctrl", "ctrl+", "+", "", "shift+bogus", "ctrl++p", None])
def test_parse_key_spec_invalid(mod, spec):
    assert mod.parse_key_spec(spec) is None


@pytest.mark.parametrize("mod", MODS, ids=IDS)
def test_defaults_when_config_missing(mod, tmp_path, monkeypatch):
    monkeypatch.setattr(mod, "CONFIG_FILE", tmp_path / "config")
    assert mod.read_button_setting("left") == (0x2C, 0)
    assert mod.read_button_setting("right") == (0x2B, 0x02)


@pytest.mark.parametrize("mod", MODS, ids=IDS)
def test_config_values_and_fallback(mod, tmp_path, monkeypatch):
    cfg = tmp_path / "config"
    cfg.write_text("chime = on\nbutton_left = tab   # comment\nBUTTON_RIGHT = Enter\n")
    monkeypatch.setattr(mod, "CONFIG_FILE", cfg)
    assert mod.read_button_setting("left") == (0x2B, 0)
    assert mod.read_button_setting("right") == (0x28, 0)
    cfg.write_text("button_left = nonsense\nbutton_right = none\n")
    mod._NOTED.clear()
    assert mod.read_button_setting("left") == (0x2C, 0)     # unparseable -> default
    assert mod.read_button_setting("right") == (0, 0)       # disabled


@pytest.mark.parametrize("mod", MODS, ids=IDS)
def test_add_button_fields_always_present(mod, tmp_path, monkeypatch):
    cfg = tmp_path / "config"
    cfg.write_text("button_left = ctrl+shift+p\n")
    monkeypatch.setattr(mod, "CONFIG_FILE", cfg)
    payload = {"s": 1}
    mod.add_button_fields(payload)
    assert payload["bl"] == [0x13, 0x03]
    assert payload["br"] == [0x2B, 0x02]
    # JSON-serialisable and compact enough for the 512-byte BLE buffer
    import json
    assert len(json.dumps(payload)) < 60
