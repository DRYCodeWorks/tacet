"""Accuracy and latency eval for tacet's whisper-server setup.

    uv run python eval/tacet_eval.py [--model PATH] [--json]
        [--prompt TEXT] [--beam-size N] [--server-arg=FLAG ...]
        [--voices A,B] [--corpus PATH] [--details PATH]

Speaks every utterance in eval/corpus.toml with macOS `say` in several
voices, converts it with `afconvert` to the 16 kHz mono 16-bit WAV tacet's
Recorder sends, starts a PRIVATE whisper-server on a free loopback port with
the flags install-server.sh renders, and POSTs each clip to /inference the way
WhisperClient.swift does. It reports word error rate, request latency, and how
many silence clips came back with text, then stops the server. The live tacet
services (ports 8910 and 8911) are never contacted.

Standard library only. Generated audio is cached in eval/.cache/ (gitignored).
Progress goes to stderr; with --json, stdout carries exactly one JSON object.

--server-arg takes a whisper-server flag with its value, shell-split, and can
be repeated. Write it with `=` so argparse does not read the flag as its own:
    --server-arg=--no-fallback --server-arg="--entropy-thold 2.8"
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import hashlib
import http.client
import json
import math
import os
import platform
import random
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import tomllib
import unicodedata
import uuid
import wave
from dataclasses import dataclass, field
from pathlib import Path

EVAL_DIR = Path(__file__).resolve().parent
DEFAULT_CORPUS = EVAL_DIR / "corpus.toml"
CACHE_DIR = EVAL_DIR / ".cache"
DEFAULT_MODEL = Path.home() / ".local/share/whisper-cpp/ggml-large-v3-turbo.bin"

# tacet's own services. The harness refuses to run a server on either.
LIVE_PORTS = frozenset({8910, 8911})

# The flags install-server.sh renders into the whisper plist, minus --model and
# --port, which the harness supplies. --prompt is added only when non-empty,
# exactly as the installer does.
PRODUCTION_FLAGS = (
    "--host",
    "127.0.0.1",
    "--language",
    "en",
    "--no-timestamps",
    "--suppress-nst",
)

# The form fields WhisperClient.makeMultipart sends after the file part.
REQUEST_FIELDS = (("response_format", "json"), ("temperature", "0.0"))

SAMPLE_RATE = 16000
# tacet's server drops audio whose RMS is below this before whisper sees it
# (audio.silence_rms_threshold, Config.swift).
SILENCE_RMS_GATE = 150.0
REQUEST_TIMEOUT_S = 60.0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        corpus = load_corpus(args.corpus)
        voices = args.voices or corpus.voices
        clips = prepare_audio(corpus, voices)
        settings = run_settings(args, voices)
        with WhisperServer(settings, args.model, args.load_timeout) as server:
            results = transcribe_all(server, clips)
    except EvalError as e:
        print(f"tacet_eval: {e}", file=sys.stderr)
        return 1
    report = build_report(args.model, settings, results)
    _write_details(args.details, report, results)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(format_summary(report, results))
    return 0


class EvalError(RuntimeError):
    """A failure that ends the run with a message rather than a traceback."""


@dataclass(frozen=True)
class Utterance:
    id: str
    text: str
    spoken: str


@dataclass(frozen=True)
class Silence:
    id: str
    kind: str
    seconds: float
    dbfs: float | None


@dataclass(frozen=True)
class Corpus:
    voices: list[str]
    utterances: list[Utterance]
    silences: list[Silence]


@dataclass(frozen=True)
class Clip:
    """One WAV to send: a spoken utterance in one voice, or a silence clip."""

    id: str
    voice: str | None
    reference: str
    path: Path

    @property
    def is_silence(self) -> bool:
        return self.voice is None


@dataclass(frozen=True)
class ClipResult:
    clip: Clip
    text: str
    ms: float
    rms: float

    @property
    def reference_words(self) -> list[str]:
        return normalize(self.clip.reference)

    @property
    def errors(self) -> int:
        return word_errors(self.reference_words, normalize(self.text))


@dataclass(frozen=True)
class Settings:
    """What was measured: the server command line and the request fields."""

    binary: str
    prompt: str
    beam_size: int | None
    server_args: list[str]
    voices: list[str]
    corpus: str
    flags: list[str] = field(init=False)

    def __post_init__(self) -> None:
        flags = list(PRODUCTION_FLAGS)
        if self.prompt:
            flags += ["--prompt", self.prompt]
        if self.beam_size is not None:
            flags += ["--beam-size", str(self.beam_size)]
        object.__setattr__(self, "flags", flags + self.server_args)

    def as_dict(self) -> dict:
        return {
            "whisper_server": self.binary,
            "flags": self.flags,
            "prompt": self.prompt,
            "beam_size": self.beam_size,
            "server_args": self.server_args,
            "request": dict(REQUEST_FIELDS),
            "voices": self.voices,
            "corpus": self.corpus,
            "host": platform.node(),
            "date": datetime.date.today().isoformat(),
        }


class WhisperServer:
    """A private whisper-server on a free loopback port, stopped on exit."""

    def __init__(self, settings: Settings, model: Path, load_timeout: float):
        self.settings = settings
        self.model = model
        self.load_timeout = load_timeout
        self.port = 0
        self.proc: subprocess.Popen | None = None
        self.log_path = CACHE_DIR / "whisper-server.log"

    def __enter__(self) -> WhisperServer:
        if not self.model.is_file():
            raise EvalError(f"model not found: {self.model}")
        if not os.access(self.settings.binary, os.X_OK):
            raise EvalError(f"whisper-server not found: {self.settings.binary}")
        self.port = _free_port()
        command = [
            self.settings.binary,
            "--model",
            str(self.model),
            "--port",
            str(self.port),
            *self.settings.flags,
        ]
        _log(f"starting whisper-server on 127.0.0.1:{self.port}")
        with open(self.log_path, "wb") as log:
            self.proc = subprocess.Popen(
                command,
                cwd=CACHE_DIR,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
        return self

    def __exit__(self, *exc: object) -> None:
        if self.proc is None or self.proc.poll() is not None:
            return
        self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()

    def wait_until_ready(self, probe: bytes) -> None:
        """POST a speech clip until it succeeds: that is load plus warm-up."""
        deadline = time.monotonic() + self.load_timeout
        while time.monotonic() < deadline:
            self._check_alive()
            try:
                self.transcribe(probe)
                return
            except (ConnectionError, socket.timeout, _NotReady):
                time.sleep(0.5)
        raise EvalError(f"whisper-server did not load in {self.load_timeout:.0f}s")

    def transcribe(self, wav: bytes) -> tuple[str, float]:
        """Send one WAV; return the text and the request's wall time in ms."""
        boundary = f"TacetBoundary{str(uuid.uuid4()).upper()}"
        body = multipart_body(boundary, wav)
        conn = http.client.HTTPConnection(
            "127.0.0.1", self.port, timeout=REQUEST_TIMEOUT_S
        )
        headers = {"Content-Type": f"multipart/form-data; boundary={boundary}"}
        start = time.perf_counter()
        try:
            conn.request("POST", "/inference", body=body, headers=headers)
            response = conn.getresponse()
            payload = response.read()
        finally:
            conn.close()
        ms = (time.perf_counter() - start) * 1000
        if response.status == 503:
            raise _NotReady()
        return _response_text(response.status, payload), ms

    def _check_alive(self) -> None:
        assert self.proc is not None
        if self.proc.poll() is not None:
            tail = self.log_path.read_text(errors="replace").splitlines()[-15:]
            raise EvalError(
                f"whisper-server exited with {self.proc.returncode}:\n"
                + "\n".join(tail)
            )


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Measure tacet's whisper-server accuracy and latency.",
        epilog="Pass whisper-server flags as --server-arg=FLAG (with '=').",
    )
    p.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    p.add_argument("--json", action="store_true", help="print one JSON object")
    p.add_argument("--prompt", default="", help="whisper-server --prompt")
    p.add_argument("--beam-size", type=int, help="whisper-server --beam-size")
    p.add_argument(
        "--server-arg",
        action="append",
        default=[],
        dest="server_args",
        help="extra whisper-server flag, shell-split; repeatable",
    )
    p.add_argument("--voices", type=_voice_list, help="comma-separated say voices")
    p.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    p.add_argument("--whisper-server", dest="binary", default=_default_binary())
    p.add_argument("--details", type=Path, default=CACHE_DIR / "last-run.json")
    p.add_argument("--load-timeout", type=float, default=300.0)
    args = p.parse_args(argv)
    args.server_args = [token for arg in args.server_args for token in shlex.split(arg)]
    return args


def load_corpus(path: Path) -> Corpus:
    data = tomllib.loads(path.read_text())
    utterances = [
        Utterance(u["id"], u["text"], u.get("spoken", u["text"]))
        for u in data.get("utterance", [])
    ]
    silences = [
        Silence(s["id"], s["kind"], float(s["seconds"]), s.get("dbfs"))
        for s in data.get("silence", [])
    ]
    ids = [x.id for x in utterances + silences]
    duplicates = sorted({i for i in ids if ids.count(i) > 1})
    if duplicates:
        raise EvalError(f"duplicate corpus ids: {', '.join(duplicates)}")
    unknown = sorted({s.kind for s in silences} - set(_SILENCE_KINDS))
    if unknown:
        raise EvalError(f"unknown silence kinds: {', '.join(unknown)}")
    return Corpus(list(data.get("voices", [])), utterances, silences)


def prepare_audio(corpus: Corpus, voices: list[str]) -> list[Clip]:
    """Generate any WAV missing from the cache; return every clip to send."""
    if not voices:
        raise EvalError("no voices: set `voices` in the corpus or pass --voices")
    _check_tools(voices)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    jobs = [(u, v) for v in voices for u in corpus.utterances]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        paths = list(pool.map(lambda job: _speech_wav(*job), jobs))
    clips = [Clip(u.id, v, u.text, path) for (u, v), path in zip(jobs, paths)]
    clips += [Clip(s.id, None, "", _silence_wav(s)) for s in corpus.silences]
    return clips


def run_settings(args: argparse.Namespace, voices: list[str]) -> Settings:
    try:
        corpus = str(args.corpus.resolve().relative_to(EVAL_DIR.parent))
    except ValueError:
        corpus = str(args.corpus)
    return Settings(
        binary=os.path.realpath(args.binary),
        prompt=args.prompt,
        beam_size=args.beam_size,
        server_args=args.server_args,
        voices=voices,
        corpus=corpus,
    )


def transcribe_all(server: WhisperServer, clips: list[Clip]) -> list[ClipResult]:
    """Send every clip one at a time, as tacet does, after an untimed warm-up."""
    first_speech = next(c for c in clips if not c.is_silence)
    server.wait_until_ready(first_speech.path.read_bytes())
    _log(f"server ready; transcribing {len(clips)} clips")
    results = []
    for n, clip in enumerate(clips, 1):
        wav = clip.path.read_bytes()
        try:
            text, ms = server.transcribe(wav)
        except (OSError, _NotReady) as e:
            raise EvalError(
                f"request for {clip.id} ({clip.voice}) failed: {e!r}"
            ) from e
        results.append(ClipResult(clip, text, ms, wav_rms(wav)))
        if n % 20 == 0 or n == len(clips):
            _log(f"  {n}/{len(clips)}")
    return results


def build_report(model: Path, settings: Settings, results: list[ClipResult]) -> dict:
    speech = [r for r in results if not r.clip.is_silence]
    silence = [r for r in results if r.clip.is_silence]
    latencies = [r.ms for r in speech]
    return {
        "model": str(model),
        "settings": settings.as_dict(),
        "utterances": len({r.clip.id for r in speech}),
        "wer": round(corpus_wer(speech), 4),
        "per_voice": {
            voice: _voice_score([r for r in speech if r.clip.voice == voice])
            for voice in settings.voices
        },
        "latency_ms": {
            "p50": round(percentile(latencies, 50), 1),
            "p95": round(percentile(latencies, 95), 1),
        },
        "silence": {
            "clips": len(silence),
            "false_text": sum(has_text(r.text) for r in silence),
            "false_text_past_gate": sum(
                has_text(r.text) and r.rms >= SILENCE_RMS_GATE for r in silence
            ),
        },
    }


def format_summary(report: dict, results: list[ClipResult], worst: int = 12) -> str:
    lat, sil = report["latency_ms"], report["silence"]
    lines = [
        f"model      {report['model']}",
        f"flags      {shlex.join(report['settings']['flags'])}",
        f"WER        {report['wer']:.2%} over {report['utterances']} utterances",
    ]
    for voice, score in report["per_voice"].items():
        lines.append(
            f"  {voice:<10} {score['wer']:.2%} ({score['errors']}/{score['words']} words)"
        )
    lines.append(f"latency    p50 {lat['p50']} ms, p95 {lat['p95']} ms")
    lines.append(
        f"silence    {sil['false_text']}/{sil['clips']} clips came back with text "
        f"({sil['false_text_past_gate']} loud enough to pass tacet's RMS gate)"
    )
    speech = [r for r in results if not r.clip.is_silence]
    misses = sorted((r for r in speech if r.errors), key=lambda r: -r.errors)
    if misses:
        lines.append(f"\nworst clips (of {len(misses)} with errors):")
    for r in misses[:worst]:
        lines.append(f"  [{r.errors}] {r.clip.id} ({r.clip.voice})")
        lines.append(f"      ref: {r.clip.reference}")
        lines.append(f"      hyp: {r.text.strip()}")
    return "\n".join(lines)


def normalize(text: str) -> list[str]:
    """Reduce a transcript to comparable words. Applied to both sides.

    1. Unicode NFKC; curly apostrophes become straight ones.
    2. Symbols become the words people say for them, so a path or flag scores
       the same written or spoken: "/" slash, "." inside a token dot (between
       digits, point), a leading "-" or "--" dash, "_" underscore, "~" tilde,
       "@" at, "%" percent, "&" and, "+" plus, "=" equals.
    3. Hyphenated compounds are closed up ("stand-up" -> "standup", "T-Mux"
       -> "tmux"), except inside a flag ("--dry-run" -> "dash dash dry run")
       and between number words ("twenty-five" -> "25").
    4. Lowercase. Apostrophes are deleted ("don't" -> "dont"); every other
       punctuation mark becomes a space, so case and punctuation never count.
    5. Numbers: thousands separators are dropped ("1,000" -> "1000"), a clock
       time reads as two numbers ("7:15" and "7.15" -> "7 15"), and spelled-out
       cardinals become digits ("twenty five" -> "25", "three thousand and"
       -> "3000 and"). Runs that are not one number stay split ("seven
       fifteen" -> "7 15"). Ordinals and "oh" are left alone.
    """
    text = unicodedata.normalize("NFKC", text).replace("’", "'").replace("‘", "'")
    text = re.sub(r"(?<![\d.])(\d{1,2})[.:]([0-5]\d)(?![\d.])", r"\1 \2", text)
    text = _speak_dots(text).lower()
    text = re.sub(r"(?<=\d),(?=\d{3}\b)", "", text)
    text = re.sub(r"(?<![\w-])(--?)(\w[\w-]*)", _speak_flag, text)
    text = re.sub(r"\w+(?:-\w+)+", _close_compound, text)
    for symbol, word in _SYMBOL_WORDS.items():
        text = text.replace(symbol, f" {word} ")
    text = re.sub(r"[^\w\s]|_", " ", text.replace("'", ""))
    return _words_to_numbers(text.split())


def word_errors(reference: list[str], hypothesis: list[str]) -> int:
    """Levenshtein distance over words: substitutions + deletions + insertions."""
    previous = list(range(len(hypothesis) + 1))
    for i, ref_word in enumerate(reference, 1):
        current = [i]
        for j, hyp_word in enumerate(hypothesis, 1):
            current.append(
                min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (ref_word != hyp_word),
                )
            )
        previous = current
    return previous[-1]


def corpus_wer(results: list[ClipResult]) -> float:
    """Micro-averaged WER: total word errors over total reference words."""
    words = sum(len(r.reference_words) for r in results)
    return sum(r.errors for r in results) / words if words else 0.0


def percentile(values: list[float], pct: float) -> float:
    """Nearest-rank percentile: the smallest value with pct% at or below it."""
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(1, math.ceil(pct / 100 * len(ordered)))
    return ordered[rank - 1]


def has_text(transcript: str) -> bool:
    """tacet pastes a transcript only if it holds a letter or digit."""
    return any(ch.isalnum() for ch in transcript)


def multipart_body(boundary: str, wav: bytes) -> bytes:
    """The body WhisperClient.makeMultipart builds, byte for byte."""
    parts = [
        f"--{boundary}\r\n".encode(),
        b'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n',
        b"Content-Type: audio/wav\r\n\r\n",
        wav,
        b"\r\n",
    ]
    for name, value in REQUEST_FIELDS:
        parts.append(f"--{boundary}\r\n".encode())
        parts.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        parts.append(f"{value}\r\n".encode())
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts)


def wav_rms(wav: bytes) -> float:
    """RMS of the 16-bit samples after a canonical 44-byte header, as tacet measures."""
    data = wav[44:]
    pcm = memoryview(data[: len(data) - len(data) % 2]).cast("h")
    return math.sqrt(sum(s * s for s in pcm) / len(pcm)) if len(pcm) else 0.0


class _NotReady(Exception):
    """whisper-server answered 503: still loading the model."""


class _NumberRun:
    """Accumulates consecutive spelled-out number words into one integer."""

    def __init__(self) -> None:
        self.total = 0
        self.current = 0
        self.last: str | None = None

    def take(self, word: str) -> bool:
        """Absorb `word` if it extends this number; False if it cannot."""
        kind, value = _number_word(word)
        if kind is None or self.last not in _CAN_FOLLOW[kind]:
            return False
        if kind == "hundred":
            if self.current >= 100:
                return False
            self.current = (self.current or 1) * 100
        elif kind == "scale":
            self.total += (self.current or 1) * value
            self.current = 0
        else:
            self.current += value
        self.last = kind
        return True

    def flush(self) -> list[str]:
        if self.last is None:
            return []
        value = self.total + self.current
        self.total, self.current, self.last = 0, 0, None
        return [str(value)]


_SYMBOL_WORDS = {
    "/": "slash",
    "_": "underscore",
    "~": "tilde",
    "@": "at",
    "%": "percent",
    "&": "and",
    "+": "plus",
    "=": "equals",
}

_UNITS = {
    w: i
    for i, w in enumerate(
        "zero one two three four five six seven eight nine ten eleven twelve "
        "thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
    )
}
_TENS = {
    w: 10 * i
    for i, w in enumerate(
        "twenty thirty forty fifty sixty seventy eighty ninety".split(), 2
    )
}
_SCALES = {"thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000}

# Which word kinds may follow which, inside one number. `None` is "nothing yet".
_CAN_FOLLOW = {
    "zero": {None},
    "unit": {None, "tens", "hundred", "scale"},
    "teen": {None, "hundred", "scale"},
    "tens": {None, "hundred", "scale"},
    "hundred": {None, "unit", "teen", "tens"},
    "scale": {None, "unit", "teen", "tens", "hundred"},
}

_SILENCE_KINDS = ("zero", "white", "brown", "hum")


def _voice_list(value: str) -> list[str]:
    return [v.strip() for v in value.split(",") if v.strip()]


def _default_binary() -> str:
    return shutil.which("whisper-server") or "/opt/homebrew/bin/whisper-server"


def _check_tools(voices: list[str]) -> None:
    for tool in ("say", "afconvert"):
        if shutil.which(tool) is None:
            raise EvalError(f"`{tool}` not found; the eval needs macOS")
    listing = subprocess.run(
        ["say", "-v", "?"], capture_output=True, text=True, check=True
    )
    installed = {
        m.group(1) for m in re.finditer(r"^(.+?)\s{2,}\w\w_\w+", listing.stdout, re.M)
    }
    missing = [v for v in voices if v not in installed]
    if missing:
        raise EvalError(f"say voices not installed: {', '.join(missing)}")


def _speech_wav(utterance: Utterance, voice: str) -> Path:
    key = _digest(voice, utterance.spoken)
    dest = CACHE_DIR / "audio" / _slug(voice) / f"{utterance.id}-{key}.wav"
    if dest.exists():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=CACHE_DIR) as tmp:
        script, aiff, converted = (
            Path(tmp, "text.txt"),
            Path(tmp, "say.aiff"),
            Path(tmp, "c.wav"),
        )
        script.write_text(utterance.spoken)
        _run(["say", "-v", voice, "-o", str(aiff), "-f", str(script)])
        _run(
            [
                "afconvert",
                "-f",
                "WAVE",
                "-d",
                f"LEI16@{SAMPLE_RATE}",
                "-c",
                "1",
                str(aiff),
                str(converted),
            ]
        )
        _canonical_wav(converted, dest)
    return dest


def _canonical_wav(source: Path, dest: Path) -> None:
    """Re-wrap afconvert's output (which carries a FLLR pad chunk) in the plain
    44-byte header tacet's Recorder writes."""
    with wave.open(str(source), "rb") as w:
        shape = (w.getnchannels(), w.getsampwidth(), w.getframerate())
        if shape != (1, 2, SAMPLE_RATE):
            raise EvalError(f"afconvert produced {shape}, not 16 kHz mono 16-bit")
        frames = w.readframes(w.getnframes())
    _write_wav(dest, frames)


def _silence_wav(clip: Silence) -> Path:
    key = _digest(clip.kind, str(clip.seconds), str(clip.dbfs))
    dest = CACHE_DIR / "audio" / "silence" / f"{clip.id}-{key}.wav"
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        samples = _silence_samples(clip)
        _write_wav(
            dest, b"".join(s.to_bytes(2, "little", signed=True) for s in samples)
        )
    return dest


def _silence_samples(clip: Silence) -> list[int]:
    """Deterministic samples scaled to the clip's RMS level in dBFS."""
    n = int(clip.seconds * SAMPLE_RATE)
    if clip.kind == "zero":
        return [0] * n
    rng = random.Random(clip.id)
    if clip.kind == "white":
        raw = [rng.gauss(0.0, 1.0) for _ in range(n)]
    elif clip.kind == "brown":
        raw, level = [], 0.0
        for _ in range(n):
            level = 0.995 * level + rng.gauss(0.0, 1.0)
            raw.append(level)
    else:
        hz = 2 * math.pi / SAMPLE_RATE
        raw = [math.sin(60 * hz * t) + 0.3 * math.sin(120 * hz * t) for t in range(n)]
    rms = math.sqrt(sum(x * x for x in raw) / n)
    gain = 32768 * 10 ** ((clip.dbfs if clip.dbfs is not None else -60) / 20) / rms
    return [max(-32768, min(32767, round(x * gain))) for x in raw]


def _write_wav(dest: Path, frames: bytes) -> None:
    partial = dest.with_name(dest.name + ".part")
    with wave.open(str(partial), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(frames)
    partial.replace(dest)


def _free_port() -> int:
    """A free loopback port from the kernel, never one of tacet's own."""
    for _ in range(20):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        if port not in LIVE_PORTS:
            return port
    raise EvalError("could not find a free loopback port")


def _response_text(status: int, payload: bytes) -> str:
    if not 200 <= status < 300:
        raise EvalError(f"whisper-server returned HTTP {status}: {payload[:200]!r}")
    try:
        text = json.loads(payload)["text"]
    except (ValueError, KeyError, TypeError) as e:
        raise EvalError(
            f"malformed response from whisper-server: {payload[:200]!r}"
        ) from e
    if not isinstance(text, str):
        raise EvalError(f"malformed response from whisper-server: {payload[:200]!r}")
    return text


def _voice_score(results: list[ClipResult]) -> dict:
    return {
        "wer": round(corpus_wer(results), 4),
        "errors": sum(r.errors for r in results),
        "words": sum(len(r.reference_words) for r in results),
    }


def _write_details(path: Path, report: dict, results: list[ClipResult]) -> None:
    """Every clip's reference, hypothesis, errors and latency, for diffing runs."""
    clips = [
        {
            "id": r.clip.id,
            "voice": r.clip.voice,
            "reference": r.clip.reference,
            "hypothesis": r.text,
            "errors": r.errors,
            "words": len(r.reference_words),
            "ms": round(r.ms, 1),
            "rms": round(r.rms, 1),
        }
        for r in results
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({**report, "clips": clips}, indent=2) + "\n")
    _log(f"per-clip detail written to {path}")


def _speak_dots(text: str) -> str:
    """Read "." the way it is spoken. Runs before lowercasing, because a period
    followed by a capital is a sentence break whisper glued shut."""
    text = re.sub(r"(?<=\d)\.(?=\d)", " point ", text)
    text = re.sub(r"\.(?=[A-Z])", " ", text)
    return re.sub(r"(?<!\.)\.(?=[a-z0-9])", " dot ", text)


def _speak_flag(match: re.Match) -> str:
    return " dash " * len(match.group(1)) + match.group(2).replace("-", " ")


def _close_compound(match: re.Match) -> str:
    parts = match.group(0).split("-")
    if all(_number_word(part)[0] for part in parts):
        return " ".join(parts)
    return "".join(parts)


def _words_to_numbers(words: list[str]) -> list[str]:
    out: list[str] = []
    run = _NumberRun()
    for word in words:
        if run.take(word):
            continue
        out += run.flush()
        if not run.take(word):
            out.append(word)
    return out + run.flush()


def _number_word(word: str) -> tuple[str | None, int]:
    if word in _UNITS:
        value = _UNITS[word]
        return ("zero" if value == 0 else "unit" if value < 10 else "teen"), value
    if word in _TENS:
        return "tens", _TENS[word]
    if word == "hundred":
        return "hundred", 100
    if word in _SCALES:
        return "scale", _SCALES[word]
    return None, 0


def _digest(*parts: str) -> str:
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()[:12]


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def _run(command: list[str]) -> None:
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise EvalError(f"{command[0]} failed: {result.stderr.strip()}")


def _log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


if __name__ == "__main__":
    sys.exit(main())
