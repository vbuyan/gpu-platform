"""Tests for the subtitles job: file discovery and SRT output (the model itself is not loaded)."""
import importlib.util
import os
import pathlib
import time

import pytest

SRC = pathlib.Path(__file__).resolve().parents[1] / "images/subtitles/subtitles.py"


@pytest.fixture
def sub(tmp_path, monkeypatch):
    monkeypatch.setenv("MEDIA_IN", str(tmp_path / "in"))
    monkeypatch.setenv("MEDIA_OUT", str(tmp_path / "out"))
    (tmp_path / "in").mkdir()
    (tmp_path / "out").mkdir()
    spec = importlib.util.spec_from_file_location("subtitles", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod, tmp_path


def touch(path, age_s):
    path.write_bytes(b"x")
    t = time.time() - age_s
    os.utime(path, (t, t))


def test_pending_skips_done_fresh_and_foreign(sub):
    mod, d = sub
    touch(d / "in/a.mp4", 600)
    touch(d / "in/b.MOV", 600)
    touch(d / "in/c.mp4", 600)
    (d / "out/c.srt").write_text("done")
    touch(d / "in/d.mp4", 5)          # still being copied
    touch(d / "in/notes.txt", 600)    # not media
    assert [f.name for f in mod.pending()] == ["a.mp4", "b.MOV"]


def test_precheck_exit_codes(sub):
    mod, d = sub
    assert mod.main(["--pending"]) == 1
    touch(d / "in/a.wav", 600)
    assert mod.main(["--pending"]) == 0


def test_srt_format(sub):
    mod, _ = sub
    srt = mod.to_srt([
        {"timestamp": (0.0, 2.5), "text": " If you ever  hear this sound,"},
        {"timestamp": (2.5, None), "text": "get out."},
        {"timestamp": (4.0, 5.0), "text": "   "},
        {"timestamp": (3661.25, 3662.0), "text": "an hour later"},
    ])
    assert srt.split("\n\n") == [
        "1\n00:00:00,000 --> 00:00:02,500\nIf you ever hear this sound,",
        "2\n00:00:02,500 --> 00:00:04,500\nget out.",
        "3\n01:01:01,250 --> 01:01:02,000\nan hour later\n",
    ]


def test_srt_time_rounding(sub):
    mod, _ = sub
    assert mod.srt_time(0.0004) == "00:00:00,000"
    assert mod.srt_time(59.9996) == "00:01:00,000"
    assert mod.srt_time(-1) == "00:00:00,000"
