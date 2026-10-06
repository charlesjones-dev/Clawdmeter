#!/usr/bin/env python3
"""Work-hours schedule config: `work_hours` / `work_days` / `screensaver_after` /
`work_brightness` / `off_hours_brightness` parsing and the "sch"/"lt" payload
fields — for both Python daemons, plus the bash daemon's SCHEDULE_PY heredoc,
which must agree with them.

Run: python -m pytest daemon/tests/test_schedule.py -q
"""
import json
import re
import subprocess
import sys
import time
from pathlib import Path

import pytest

import daemon.claude_usage_daemon as macos
import daemon.claude_usage_daemon_windows as win

MODS = [macos, win]
IDS = ["macos", "windows"]

BASH_DAEMON = Path(__file__).resolve().parent.parent / "claude-usage-daemon.sh"
SCHEDULE_PY = re.search(r"read -r -d '' SCHEDULE_PY <<'PYEOF'\n(.*?)\nPYEOF\n",
                        BASH_DAEMON.read_text(), re.S).group(1)


@pytest.mark.parametrize("mod", MODS, ids=IDS)
@pytest.mark.parametrize("spec,want", [
    (None, 0), ("", 0), ("off", 0), ("OFF", 0), ("0", 0),
    ("10", 10), ("10m", 10), ("10 min", 10), ("45 minutes", 45), ("1 minute", 1),
    ("5000", 1440),                       # capped at a day
    ("ten", None), ("10s", None), ("-5", None), ("1.5", None),
])
def test_parse_screensaver_after(mod, spec, want):
    assert mod.parse_screensaver_after(spec) == want


@pytest.mark.parametrize("mod", MODS, ids=IDS)
@pytest.mark.parametrize("spec,want", [
    ("9", 540), ("09:00", 540), ("9:30", 570), ("17:00", 1020), ("0:00", 0),
    ("9am", 540), ("9 AM", 540), ("5pm", 1020), ("5:30 pm", 1050),
    ("12am", 0), ("12pm", 720), ("24:00", 1440),
    ("25:00", None), ("9:60", None), ("13pm", None), ("0am", None),
    ("24:30", None), ("noon", None), ("", None),
])
def test_parse_time_of_day(mod, spec, want):
    assert mod.parse_time_of_day(spec) == want


@pytest.mark.parametrize("mod", MODS, ids=IDS)
@pytest.mark.parametrize("spec,want", [
    (None, (0, 0)), ("", (0, 0)), ("none", (0, 0)),
    ("9:00-17:00", (540, 1020)), ("9am-5pm", (540, 1020)), ("9am - 5pm", (540, 1020)),
    ("9 to 17", (540, 1020)), ("9:00–17:00", (540, 1020)),    # en dash
    ("22:00-06:00", (1320, 360)),        # overnight
    ("17:00-24:00", (1020, 1440)), ("24:00-06:00", (0, 360)),
    ("9-9", None), ("9am", None), ("9-5-6", None), ("nine-five", None),
])
def test_parse_work_hours(mod, spec, want):
    assert mod.parse_work_hours(spec) == want


@pytest.mark.parametrize("mod", MODS, ids=IDS)
@pytest.mark.parametrize("spec,want", [
    (None, 0x7F), ("", 0x7F), ("daily", 0x7F), ("every day", 0x7F),
    ("mon-fri", 0x3E), ("Monday - Friday", 0x3E), ("weekdays", 0x3E),
    ("sat,sun", 0x41), ("weekends", 0x41), ("sun", 0x01), ("sat", 0x40),
    ("mon,wed,fri", 0x2A), ("tues, thurs", 0x14),
    ("fri-mon", 0x63),                   # wraps through the weekend
    ("weekdays, sat", 0x7E),
    ("mo", None), ("funday", None), ("mon,,fri", None), ("mon-wed-fri", None),
])
def test_parse_work_days(mod, spec, want):
    assert mod.parse_work_days(spec) == want


@pytest.mark.parametrize("mod", MODS, ids=IDS)
@pytest.mark.parametrize("spec,want", [
    (None, 3), ("", 3),                  # unset -> the caller's default
    ("1", 1), ("4", 4), ("min", 1), ("MAX", 4), ("brightest", 4), ("dimmest", 1),
    ("manual", 0), ("off", 0),
    ("0", None), ("5", None), ("bright", None), ("50%", None),
])
def test_parse_brightness(mod, spec, want):
    assert mod.parse_brightness(spec, 3) == want


OFF = [0, 0, 0x7F, 0, 0, 0]
CONFIGS = [
    # Nothing set: no schedule at all, so existing setups are untouched.
    ("", OFF),
    # Work hours alone: brightness defaults kick in (brightest at work, dimmest off).
    ("work_hours = 9am-5pm\n", [540, 1020, 0x7F, 0, 4, 1]),
    ("work_hours = 9-17\nwork_days = mon-fri\nscreensaver_after = 10  # minutes\n",
     [540, 1020, 0x3E, 600, 4, 1]),
    ("SCREENSAVER_AFTER=5\r\nwork_hours=9:00-17:00\r\nwork_brightness=3\r\n"
     "off_hours_brightness=2\r\n", [540, 1020, 0x7F, 300, 3, 2]),
    ("work_hours = 22:00-06:00\nwork_days = mon-fri\noff_hours_brightness = manual\n",
     [1320, 360, 0x3E, 0, 4, 0]),
    # Screensaver without work hours: around the clock, brightness left alone.
    ("screensaver_after = 10\n", [0, 0, 0x7F, 600, 0, 0]),
    ("screensaver_after = 10\nwork_brightness = max\n", [0, 0, 0x7F, 600, 0, 0]),
    # Bad schedule -> everything off; bad feature value -> just that feature off.
    ("screensaver_after = 10\nwork_hours = 1\n", OFF),
    ("work_hours = 9-17\nwork_days = funday\n", OFF),
    ("work_hours = 9-17\nscreensaver_after = soon\n", [540, 1020, 0x7F, 0, 4, 1]),
    ("work_hours = 9-17\nwork_brightness = 11\n", [540, 1020, 0x7F, 0, 0, 1]),
]


@pytest.mark.parametrize("mod", MODS, ids=IDS)
@pytest.mark.parametrize("text,want", CONFIGS)
def test_read_schedule_setting(mod, text, want, tmp_path, monkeypatch):
    cfg = tmp_path / "config"
    cfg.write_text(text)
    monkeypatch.setattr(mod, "CONFIG_FILE", cfg)
    mod._NOTED.clear()
    assert mod.read_schedule_setting() == want


def _active(sch):
    return sch[0] != sch[1] or sch[3] != 0


@pytest.mark.parametrize("text,want", CONFIGS)
def test_bash_parser_matches(text, want, tmp_path):
    cfg = tmp_path / "config"
    cfg.write_text(text)
    out = subprocess.run([sys.executable, "-c", SCHEDULE_PY, str(cfg)],
                         capture_output=True, text=True, check=True).stdout
    assert out.startswith(",") and out.count("\n") == 1   # a bare fragment, nothing else
    frag = json.loads("{" + out.strip()[1:] + "}")
    assert frag["sch"] == want
    assert ("lt" in frag) == _active(want)


def test_bash_parser_missing_config(tmp_path):
    out = subprocess.run([sys.executable, "-c", SCHEDULE_PY, str(tmp_path / "nope")],
                         capture_output=True, text=True, check=True).stdout
    assert out == ',"sch":[0,0,127,0,0,0]\n'


@pytest.mark.parametrize("mod", MODS, ids=IDS)
def test_payload_fields(mod, tmp_path, monkeypatch):
    cfg = tmp_path / "config"
    monkeypatch.setattr(mod, "CONFIG_FILE", cfg)

    cfg.write_text("chime = on\n")
    payload = {}
    mod.add_schedule_fields(payload)
    assert payload == {"sch": OFF}            # no local time when nothing is scheduled

    cfg.write_text("work_hours = 9-17\n")
    payload = {}
    mod.add_schedule_fields(payload)
    assert payload["sch"] == [540, 1020, 0x7F, 0, 4, 1]
    local = int(time.time()) + time.localtime().tm_gmtoff
    assert abs(payload["lt"] - local) <= 2
