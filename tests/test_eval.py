"""The eval harness's scoring: normalization, WER, percentiles, and its inputs.

None of this needs macOS or a whisper-server. The harness is loaded from its
file because eval/ is a directory of scripts, not a package (and `eval` would
shadow the builtin if it were one).
"""

import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "tacet_eval", ROOT / "eval" / "tacet_eval.py"
)
te = importlib.util.module_from_spec(_spec)
sys.modules["tacet_eval"] = te
_spec.loader.exec_module(te)


def result(reference: str, hypothesis: str, voice: str = "Samantha"):
    clip = te.Clip("x", voice, reference, Path("/nonexistent.wav"))
    return te.ClipResult(clip, hypothesis, ms=1.0, rms=1000.0)


class TestNormalizeCaseAndPunctuation:
    def test_case_and_punctuation_never_count(self):
        assert te.normalize("Hello, World!") == te.normalize("hello world")

    def test_apostrophes_are_deleted_not_spaced(self):
        assert te.normalize("Don't") == ["dont"]
        assert te.normalize("I’ll") == ["ill"]

    def test_empty_and_punctuation_only(self):
        assert te.normalize("") == []
        assert te.normalize(" . ") == []

    def test_sentence_glued_by_whisper_splits(self):
        assert te.normalize("Done.Next line") == ["done", "next", "line"]

    def test_hyphenated_compound_closes_up(self):
        assert te.normalize("stand-up") == te.normalize("standup")
        assert te.normalize("T-Mux") == ["tmux"]


class TestNormalizeSymbols:
    def test_written_path_scores_as_spoken_path(self):
        assert te.normalize("/etc/hosts") == te.normalize("slash etc slash hosts")

    def test_dotted_filename(self):
        assert te.normalize("README.md") == ["readme", "dot", "md"]

    def test_dotfile_in_a_home_path(self):
        assert te.normalize("~/.config") == ["tilde", "slash", "dot", "config"]

    def test_long_flag_keeps_its_words(self):
        spoken = "dash dash force with lease"
        assert te.normalize("--force-with-lease") == te.normalize(spoken)

    def test_short_flag(self):
        assert te.normalize("-v") == ["dash", "v"]

    def test_free_standing_dash_is_punctuation(self):
        assert te.normalize("a - b") == ["a", "b"]

    def test_underscore(self):
        assert te.normalize("DATABASE_URL") == ["database", "underscore", "url"]


class TestNormalizeNumbers:
    @pytest.mark.parametrize(
        "spoken, digits",
        [
            ("ten", "10"),
            ("twenty five", "25"),
            ("twenty-five", "25"),
            ("one hundred five", "105"),
            ("three thousand five hundred twenty one", "3521"),
        ],
    )
    def test_spelled_cardinals_become_digits(self, spoken, digits):
        assert te.normalize(spoken) == [digits]

    def test_thousands_separator_dropped(self):
        assert te.normalize("8,080") == ["8080"]

    def test_runs_that_are_not_one_number_stay_split(self):
        assert te.normalize("seven fifteen") == ["7", "15"]
        assert te.normalize("nineteen eighty four") == ["19", "84"]
        assert te.normalize("one two three") == ["1", "2", "3"]

    def test_clock_time_either_separator(self):
        assert (
            te.normalize("7:15")
            == te.normalize("7.15")
            == te.normalize("seven fifteen")
        )

    def test_decimal_reads_as_point(self):
        assert te.normalize("3.5") == te.normalize("three point five")

    def test_numbers_inside_words_are_left_alone(self):
        assert te.normalize("ten minutes late") == ["10", "minutes", "late"]
        assert te.normalize("tenant") == ["tenant"]


class TestWordErrors:
    def test_identical(self):
        assert te.word_errors(["a", "b"], ["a", "b"]) == 0

    def test_substitution(self):
        assert te.word_errors(["a", "b", "c"], ["a", "x", "c"]) == 1

    def test_deletion(self):
        assert te.word_errors(["a", "b", "c"], ["a", "c"]) == 1

    def test_insertion(self):
        assert te.word_errors(["a", "c"], ["a", "b", "c"]) == 1

    def test_empty_hypothesis_deletes_everything(self):
        assert te.word_errors(["a", "b", "c"], []) == 3

    def test_empty_reference_counts_insertions(self):
        assert te.word_errors([], ["you"]) == 1


class TestCorpusWer:
    def test_micro_average_weights_by_reference_words(self):
        # One error in a 1-word clip and none in a 3-word clip: 1/4, not the
        # 0.5 a per-clip average would give.
        results = [result("hello", "goodbye"), result("one two three", "1 2 3")]
        assert te.corpus_wer(results) == pytest.approx(0.25)

    def test_normalization_applies_to_both_sides(self):
        assert (
            te.corpus_wer(
                [result("Add it to /etc/hosts.", "add it to slash etc slash hosts")]
            )
            == 0.0
        )

    def test_insertions_can_push_past_one(self):
        # Not clamped: WER above 1 is a real signal (a hallucinating model).
        assert te.corpus_wer([result("yes", "yes yes yes")]) == pytest.approx(2.0)

    def test_no_reference_words(self):
        assert te.corpus_wer([]) == 0.0


class TestPercentile:
    def test_nearest_rank(self):
        values = list(range(1, 101))
        assert te.percentile(values, 50) == 50
        assert te.percentile(values, 95) == 95

    def test_small_sample(self):
        assert te.percentile([30.0, 10.0, 20.0], 50) == 20.0
        assert te.percentile([30.0, 10.0, 20.0], 95) == 30.0

    def test_empty(self):
        assert te.percentile([], 50) == 0.0


class TestSilenceText:
    @pytest.mark.parametrize("text", ["", " ", ".", " . "])
    def test_punctuation_is_not_text(self, text):
        assert not te.has_text(text)

    @pytest.mark.parametrize("text", ["you", " Thank you.", "[BLANK_AUDIO]"])
    def test_any_letter_is_text(self, text):
        assert te.has_text(text)


class TestCorpus:
    def test_shipped_corpus_meets_the_floor(self):
        corpus = te.load_corpus(te.DEFAULT_CORPUS)
        assert len({u.id for u in corpus.utterances}) >= 40
        assert len(corpus.silences) >= 5
        assert len(corpus.voices) >= 3

    def test_shipped_corpus_has_loud_silence(self):
        # Clips under tacet's RMS gate never reach whisper in production, so a
        # silence set made only of those would measure nothing that matters.
        corpus = te.load_corpus(te.DEFAULT_CORPUS)
        loud = [s for s in corpus.silences if s.dbfs is not None and s.dbfs > -47]
        assert loud

    def test_spoken_defaults_to_text(self, tmp_path):
        path = tmp_path / "c.toml"
        path.write_text('voices = ["A"]\n[[utterance]]\nid = "u"\ntext = "hi"\n')
        assert te.load_corpus(path).utterances[0].spoken == "hi"

    def test_duplicate_ids_are_refused(self, tmp_path):
        path = tmp_path / "c.toml"
        path.write_text(
            '[[utterance]]\nid = "u"\ntext = "a"\n[[utterance]]\nid = "u"\ntext = "b"\n'
        )
        with pytest.raises(te.EvalError, match="duplicate"):
            te.load_corpus(path)

    def test_unknown_silence_kind_is_refused(self, tmp_path):
        path = tmp_path / "c.toml"
        path.write_text('[[silence]]\nid = "s"\nkind = "pink"\nseconds = 1.0\n')
        with pytest.raises(te.EvalError, match="pink"):
            te.load_corpus(path)

    def test_silence_samples_hit_their_level(self):
        clip = te.Silence("s", "white", 0.5, -40)
        samples = te._silence_samples(clip)
        rms = (sum(s * s for s in samples) / len(samples)) ** 0.5
        assert rms == pytest.approx(327.7, rel=0.01)
        assert te._silence_samples(clip) == samples  # seeded: same bytes every run


class TestArguments:
    def test_server_args_are_shell_split_and_repeatable(self):
        args = te.parse_args(
            ["--server-arg=--no-fallback", "--server-arg=--entropy-thold 2.8"]
        )
        assert args.server_args == ["--no-fallback", "--entropy-thold", "2.8"]

    def test_production_flags_by_default(self):
        settings = te.run_settings(te.parse_args([]), ["Samantha"])
        assert settings.flags == list(te.PRODUCTION_FLAGS)
        assert "--prompt" not in settings.flags

    def test_prompt_and_beam_size_pass_through(self):
        args = te.parse_args(
            ["--prompt", "tmux, kubectl", "--beam-size", "5", "--server-arg=-nf"]
        )
        flags = te.run_settings(args, ["Samantha"]).flags
        assert flags[-5:] == ["--prompt", "tmux, kubectl", "--beam-size", "5", "-nf"]

    def test_voices_override(self):
        assert te.parse_args(["--voices", "Daniel, Karen"]).voices == [
            "Daniel",
            "Karen",
        ]


class TestRequest:
    def test_multipart_matches_whisper_client(self):
        body = te.multipart_body("B", b"RIFF")
        assert body == (
            b"--B\r\n"
            b'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
            b"Content-Type: audio/wav\r\n\r\n"
            b"RIFF\r\n"
            b'--B\r\nContent-Disposition: form-data; name="response_format"\r\n\r\njson\r\n'
            b'--B\r\nContent-Disposition: form-data; name="temperature"\r\n\r\n0.0\r\n'
            b"--B--\r\n"
        )

    def test_free_port_is_never_a_live_tacet_port(self):
        assert te._free_port() not in te.LIVE_PORTS


SCRIPT = """
voices = ["A"]
[[utterance]]
id = "u1"
split = "tune"
kind = "short"
text = "merge it"
[[utterance]]
id = "u2"
split = "holdout"
kind = "ids"
text = "Close TKT-1618."
[[quiet]]
id = "q1"
split = "tune"
do = "Say nothing."
"""


def write_take(
    folder: Path, clip_id: str, samples: list[int], note: dict | None = None
):
    folder.mkdir(parents=True, exist_ok=True)
    frames = b"".join(s.to_bytes(2, "little", signed=True) for s in samples)
    te._write_wav(folder / f"{clip_id}.wav", frames)
    if note is not None:
        (folder / f"{clip_id}.json").write_text(te.json.dumps(note))


class TestSpacingAlignment:
    @pytest.mark.parametrize(
        "reference, hypothesis",
        [
            ("Bump ch-migrate.", "Bump CH migrate."),
            ("Move TKT-1687 to Backlog.", "Move TKT 1687 to backlog."),
            ("the standup", "the stand up"),
            ("Try large-v3-turbo.", "Try large V3 turbo."),
        ],
    )
    def test_spacing_inside_a_word_never_counts(self, reference, hypothesis):
        assert result(reference, hypothesis).errors == 0

    def test_a_wrong_word_still_counts(self):
        # Nothing joins to "chmigrate", so it is a substitution plus an insertion.
        assert result("Bump ch-migrate.", "Bump CH migrant.").errors == 2

    def test_gluing_two_words_still_counts(self):
        assert result("Rebase onto main.", "Rebase Ontomain.").errors == 2


class TestSplitsAndQuiet:
    def corpus(self, tmp_path):
        path = tmp_path / "script.toml"
        path.write_text(SCRIPT)
        return te.load_corpus(path)

    def test_split_kind_and_quiet_are_read(self, tmp_path):
        corpus = self.corpus(tmp_path)
        assert [(u.id, u.split, u.kind) for u in corpus.utterances] == [
            ("u1", "tune", "short"),
            ("u2", "holdout", "ids"),
        ]
        assert corpus.quiet == [te.Quiet("q1", "Say nothing.", "tune")]

    def test_select_split_keeps_one_side(self, tmp_path):
        tune = te.select_split(self.corpus(tmp_path), "tune")
        assert [u.id for u in tune.utterances] == ["u1"]
        assert [q.id for q in tune.quiet] == ["q1"]

    def test_a_split_nobody_marked_is_an_error(self, tmp_path):
        path = tmp_path / "c.toml"
        path.write_text('[[utterance]]\nid = "u"\ntext = "hi"\n')
        with pytest.raises(te.EvalError, match="no utterances"):
            te.select_split(te.load_corpus(path), "holdout")

    def test_unknown_split_is_refused(self, tmp_path):
        path = tmp_path / "c.toml"
        path.write_text('[[utterance]]\nid = "u"\ntext = "hi"\nsplit = "dev"\n')
        with pytest.raises(te.EvalError, match="dev"):
            te.load_corpus(path)


class TestRecordings:
    def setup_corpus(self, tmp_path):
        path = tmp_path / "script.toml"
        path.write_text(SCRIPT)
        return te.load_corpus(path), tmp_path / "recordings"

    def record_all(self, root: Path, session: str):
        write_take(root / session, "u1", [900, -900] * 800, {"script_text": "merge it"})
        write_take(
            root / session, "u2", [900, -900] * 800, {"script_text": "Close TKT-1618."}
        )
        write_take(root / session, "q1", [3, -3] * 800, {"script_text": "Say nothing."})

    def test_every_take_becomes_a_clip_per_session(self, tmp_path):
        corpus, root = self.setup_corpus(tmp_path)
        self.record_all(root, "studio-mic")
        clips = te.load_recordings(corpus, root, ["studio-mic"])
        assert [(c.id, c.voice, c.is_silence, c.kind) for c in clips] == [
            ("u1", "studio-mic", False, "short"),
            ("u2", "studio-mic", False, "ids"),
            ("q1", "studio-mic", True, None),
        ]

    def test_missing_takes_stop_the_run(self, tmp_path):
        corpus, root = self.setup_corpus(tmp_path)
        write_take(root / "s", "u1", [900] * 1600)
        with pytest.raises(te.EvalError, match="s/u2: not recorded"):
            te.load_recordings(corpus, root, ["s"])

    def test_a_take_recorded_for_other_text_is_stale(self, tmp_path):
        corpus, root = self.setup_corpus(tmp_path)
        self.record_all(root, "s")
        write_take(root / "s", "u1", [900] * 1600, {"script_text": "merge that"})
        with pytest.raises(te.EvalError, match="different text"):
            te.load_recordings(corpus, root, ["s"])

    def test_sessions_are_discovered_or_checked(self, tmp_path):
        _, root = self.setup_corpus(tmp_path)
        self.record_all(root, "laptop")
        self.record_all(root, "studio")
        assert te.recorded_sessions(root, None) == ["laptop", "studio"]
        with pytest.raises(te.EvalError, match="no takes for desk"):
            te.recorded_sessions(root, ["desk"])

    def test_report_scores_sessions_kinds_and_quiet_takes(self, tmp_path):
        corpus, root = self.setup_corpus(tmp_path)
        self.record_all(root, "s")
        clips = te.load_recordings(corpus, root, ["s"])
        hyps = {"u1": "merge it", "u2": "Close TKT 1618.", "q1": "you"}
        results = [te.ClipResult(c, hyps[c.id], 100.0, 160.0) for c in clips]
        settings = te.Settings(
            "ws", "", None, [], ["s"], "script.toml", "tune", str(root)
        )
        report = te.build_report(Path("m.bin"), settings, results)
        assert report["per_voice"]["s"]["errors"] == 0
        assert set(report["per_kind"]) == {"short", "ids"}
        assert report["silence"] == {
            "clips": 1,
            "false_text": 1,
            "false_text_past_gate": 1,
        }
        assert report["settings"]["split"] == "tune"
