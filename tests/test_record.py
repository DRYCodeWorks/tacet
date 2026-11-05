"""eval/record.py's decisions: what to record next and what to warn about.

The capture itself needs macOS and a microphone, so it is exercised by hand;
eval/recorder.swift --selftest checks its WAV writer without one.
"""

import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("record", ROOT / "eval" / "record.py")
rec = importlib.util.module_from_spec(_spec)
sys.modules["record"] = rec
_spec.loader.exec_module(rec)
te = rec.te

LINE = te.Utterance("r1", "merge it", "merge it", "tune", "short")
QUIET = te.Quiet("q1", "Say nothing.", "tune")


def test_session_name_is_host_and_input():
    name = rec.session_name("Dans-Mac-Studio.local", "MacBook Pro Microphone")
    assert name == "dans-mac-studio-macbook-pro-microphone"


def test_pending_skips_recorded_takes_unless_redone(tmp_path):
    (tmp_path / "r1.wav").write_bytes(b"")
    assert rec.pending([LINE, QUIET], tmp_path, []) == [QUIET]
    assert rec.pending([LINE, QUIET], tmp_path, ["r1"]) == [LINE, QUIET]


def test_redo_of_an_unknown_id_is_an_error(tmp_path):
    with pytest.raises(te.EvalError, match="r9"):
        rec.pending([LINE], tmp_path, ["r9"])


@pytest.mark.parametrize(
    "take, expected",
    [
        (rec.Take(0, 0.0, 0), "no audio arrived"),
        (rec.Take(16000, 0.0, 0), "every sample is zero"),
        (rec.Take(16000, 80.0, 400), "quieter than tacet's gate"),
        (rec.Take(4000, 900.0, 9000), "very short"),
    ],
)
def test_bad_speech_takes_are_flagged(take, expected):
    assert any(expected in w for w in rec.check_take(LINE, take))


def test_a_good_take_and_a_quiet_take_pass():
    assert rec.check_take(LINE, rec.Take(40000, 1200.0, 14000)) == []
    assert rec.check_take(QUIET, rec.Take(32000, 40.0, 300)) == []


def test_take_seconds():
    assert rec.Take(24000, 1.0, 1).seconds == 1.5
