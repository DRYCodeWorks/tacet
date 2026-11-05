"""Record your own voice for tacet's eval, one take per corpus line.

    uv run python eval/record.py --script PATH [--session NAME] [--out DIR]
        [--split tune|holdout] [--redo ID ...]

Shows each line of the script and records it through eval/recorder.swift,
which captures the way tacet does (AVAudioEngine's default input, converted to
16 kHz mono 16-bit). Each take is saved as <out>/<session>/<id>.wav with an
<id>.json note of what was read, on which Mac and which input. Lines already
recorded are skipped, so a second run picks up where the first stopped.

Press Enter and start talking, the way you would with the hotkey; press Enter
again when you are done. Then keep the take, redo it, or play it back.
[[quiet]] lines ask for a take with no speech in it: a breath, typing, the room.

Run it in a plain terminal window (not inside tmux, not over SSH) on the Mac
whose microphone you mean to test. macOS asks once for microphone access for
that terminal app. Score the takes afterwards with:

    uv run python eval/tacet_eval.py --corpus PATH --recordings --split tune
"""

from __future__ import annotations

import argparse
import datetime
import json
import platform
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import tacet_eval as te  # noqa: E402

RECORDER_SOURCE = te.EVAL_DIR / "recorder.swift"
RECORDER_BINARY = te.CACHE_DIR / "tacet-recorder"
SHORT_TAKE_S = 0.6


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        corpus = te.select_split(te.load_corpus(args.script), args.split)
        items = [*corpus.utterances, *corpus.quiet]
        with Microphone(build_recorder()) as mic:
            folder = args.out / (
                args.session or session_name(platform.node(), mic.device)
            )
            todo = pending(items, folder, args.redo)
            print(f"{len(todo)} of {len(items)} takes to record into {folder}")
            print(f"input: {mic.device}\n")
            for n, item in enumerate(todo, 1):
                print(f"[{n}/{len(todo)}] {item.id}")
                if not record_item(mic, item, folder):
                    break
    except te.EvalError as e:
        print(f"record: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nstopped; takes kept so far are saved", file=sys.stderr)
        return 130
    return 0


@dataclass(frozen=True)
class Take:
    """What the recorder reported for one take."""

    frames: int
    rms: float
    peak: int

    @property
    def seconds(self) -> float:
        return self.frames / te.SAMPLE_RATE


class Microphone:
    """The tacet-recorder process: one long-lived capture engine, as in tacet."""

    def __init__(self, binary: Path):
        self.proc = subprocess.Popen(
            [str(binary)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.device = ""

    def __enter__(self) -> Microphone:
        reply = self._read()
        if reply == "denied":
            raise te.EvalError(
                "microphone access is denied for this terminal app: allow it in "
                "System Settings > Privacy & Security > Microphone, then rerun"
            )
        if not reply.startswith("ready "):
            raise te.EvalError(f"recorder did not start: {reply!r}")
        self.device = reply.removeprefix("ready ")
        return self

    def __exit__(self, *exc: object) -> None:
        if self.proc.poll() is None:
            self._send("quit")
            self.proc.wait(timeout=10)

    def start(self) -> None:
        self._send("start")
        reply = self._read()
        if reply != "started":
            raise te.EvalError(f"could not start capture: {reply}")

    def stop(self, path: Path) -> Take:
        self._send(f"stop {path}")
        reply = self._read()
        if not reply.startswith("saved "):
            raise te.EvalError(f"could not save the take: {reply}")
        frames, rms, peak = reply.split()[1:]
        return Take(int(frames), float(rms), int(peak))

    def _send(self, line: str) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def _read(self) -> str:
        assert self.proc.stdout is not None
        line = self.proc.stdout.readline()
        if not line:
            raise te.EvalError(f"recorder exited with {self.proc.wait()}")
        return line.strip()


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Record takes for tacet's eval.")
    p.add_argument("--script", type=Path, required=True, help="the corpus TOML to read")
    p.add_argument("--session", help="name for this mic and Mac (default host-input)")
    p.add_argument("--out", type=Path, default=te.RECORDINGS_DIR)
    p.add_argument("--split", choices=te.SPLITS, help="record one split only")
    p.add_argument(
        "--redo", nargs="+", default=[], metavar="ID", help="re-record these"
    )
    return p.parse_args(argv)


def build_recorder() -> Path:
    """Compile recorder.swift into the cache when it is missing or older."""
    stale = (
        not RECORDER_BINARY.exists()
        or RECORDER_BINARY.stat().st_mtime < RECORDER_SOURCE.stat().st_mtime
    )
    if stale:
        print("building the recorder (once, about 15 s)...", file=sys.stderr)
        RECORDER_BINARY.parent.mkdir(parents=True, exist_ok=True)
        built = subprocess.run(
            ["swiftc", "-O", str(RECORDER_SOURCE), "-o", str(RECORDER_BINARY)],
            capture_output=True,
            text=True,
        )
        if built.returncode != 0:
            raise te.EvalError(f"swiftc failed: {built.stderr.strip()[-800:]}")
    return RECORDER_BINARY


def session_name(host: str, device: str) -> str:
    """'Dans-Mac-Studio.local' + 'MacBook Pro Microphone' -> 'dans-mac-studio-macbook-pro-microphone'."""
    return f"{_slug(host.split('.')[0])}-{_slug(device)}"


def pending(items: list, folder: Path, redo: list[str]) -> list:
    """Lines with no take yet, plus any asked for again, in script order."""
    unknown = sorted(set(redo) - {item.id for item in items})
    if unknown:
        raise te.EvalError(f"--redo names ids not in the script: {', '.join(unknown)}")
    return [i for i in items if i.id in redo or not (folder / f"{i.id}.wav").exists()]


def record_item(mic: Microphone, item: te.Utterance | te.Quiet, folder: Path) -> bool:
    """Record one line until it is kept. False when the speaker quits."""
    _show(item)
    folder.mkdir(parents=True, exist_ok=True)
    draft = folder / f"{item.id}.part.wav"
    while True:
        if input("  Enter to record, q to quit: ").strip().lower() == "q":
            return False
        mic.start()
        input("  ● recording... Enter to stop ")
        take = mic.stop(draft)
        print(
            f"  {take.seconds:.1f} s, level {take.rms:.0f} (tacet drops audio under 150)"
        )
        for warning in check_take(item, take):
            print(f"  ! {warning}")
        choice = _choose(draft)
        if choice == "keep":
            _keep(item, draft, take, mic.device)
            return True
        if choice == "quit":
            draft.unlink(missing_ok=True)
            return False


def check_take(item: te.Utterance | te.Quiet, take: Take) -> list[str]:
    """What a speaker should know before keeping a take."""
    if take.frames == 0:
        return ["no audio arrived: is the input device connected?"]
    if take.peak == 0:
        return [
            "every sample is zero: the input is muted, or this terminal has no "
            "microphone access (System Settings > Privacy & Security > Microphone)"
        ]
    if isinstance(item, te.Quiet):
        return []
    warnings = []
    if take.rms < te.SILENCE_RMS_GATE:
        warnings.append(
            "quieter than tacet's gate, so tacet would drop it: move closer"
        )
    if take.seconds < SHORT_TAKE_S:
        warnings.append("very short: did it cut off?")
    return warnings


def _show(item: te.Utterance | te.Quiet) -> None:
    if isinstance(item, te.Quiet):
        print(f"  (no speech) {item.do}")
        return
    print(f"\n    {item.text}\n")
    if item.spoken != item.text:
        print(f"  read it as: {item.spoken}")


def _choose(draft: Path) -> str:
    while True:
        answer = input("  Enter to keep, r to redo, p to play it back, q to quit: ")
        answer = answer.strip().lower()
        if answer == "":
            return "keep"
        if answer in ("r", "q"):
            return {"r": "redo", "q": "quit"}[answer]
        if answer == "p":
            subprocess.run(["afplay", str(draft)], check=False)


def _keep(item: te.Utterance | te.Quiet, draft: Path, take: Take, device: str) -> None:
    wav = draft.with_name(f"{item.id}.wav")
    draft.replace(wav)
    note = {
        "id": item.id,
        "script_text": te.script_text(item),
        "split": item.split,
        "kind": getattr(item, "kind", None),
        "session": wav.parent.name,
        "host": platform.node(),
        "device": device,
        "seconds": round(take.seconds, 2),
        "rms": round(take.rms, 1),
        "peak": take.peak,
        "recorded_at": datetime.datetime.now()
        .astimezone()
        .isoformat(timespec="seconds"),
    }
    wav.with_suffix(".json").write_text(json.dumps(note, indent=2) + "\n")


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


if __name__ == "__main__":
    sys.exit(main())
