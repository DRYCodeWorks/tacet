# Vocabulary design: a word list you can grow from Claude Code

Issue: [#30](https://github.com/DRYCodeWorks/tacet/issues/30). Supersedes #23 (phrase repair) and #24 (empty default prompt).
Date: 2026-11-06
Revision: 3. D1–D4 are agreed (see "Decided"). Terms are built; corrections (D2's second kind, D3) are not yet.

## Why

Users spend real time correcting proper nouns and jargon after a dictation lands.
A live example: "tacet" comes back as "tacit". The vocabulary prompt doesn't list
"Tacet", and "tacit" is an ordinary English word, so whisper prefers it.

What exists today:

- One server-wide prompt, `whisper.prompt` in `~/.config/tacet/config.toml`.
  `install-server.sh:300-311` renders it into the whisper-server plist as `--prompt`.
- Changing it means editing the config on the server and re-running `install-server.sh`.
- A fresh install ships `prompt = ""` (#24), so new users get no biasing at all.
- Nothing repairs words after decoding (#23).

## Assumed setup

These are the maintainer's answers from 2026-11-06. The design depends on them.

- One server, with 2 or 3 client Macs dictating to it. A single Mac running both
  roles is the same thing with one client.
- One person per server. The server has a single key (`~/.config/tacet/key`)
  and can't tell people apart, so one server means one list.
- Claude Code runs mostly on the client Macs, and sometimes on the server host.
  A session on a machine with no tacet installed is out of scope.
- The list should hold **hundreds** of entries.
- Entries should be added and fixed **from inside a Claude Code session**, for example
  "add ClickHouse, Tacet to my vocab list" right after a dictation.

## Decisions

The maintainer agreed to all four on 2026-11-06. The specific answers are under "Decided" at the end.

### D1. The server owns the list

The list is one file on the server. The server builds the prompt from it and
applies corrections. Clients send nothing extra with a dictation.

- **Every client is in sync by construction.** There is one copy.
- **Nothing size-limited travels per request.** An earlier idea sent the list
  in a request header. The header would have held it, but whisper wouldn't (see D2).

### D2. Two kinds of entry, because the prompt can't hold hundreds

Verified in whisper.cpp v1.8.4 (`src/whisper.cpp`):

- **The prompt budget is small.** It is `min(n_max_text_ctx, n_text_ctx/2)` tokens
  (line 6897). That is 224 for every Whisper model, and one token goes to a marker
  (lines 7087 and 7097).
- **Overflow is silent.** Past the budget, whisper keeps the *last* tokens and drops
  the start (line 7098). Nothing warns.
- **`max_context 0` (`-mc 0`) also drops the prompt.** The prompt is only built when
  `n_max_text_ctx > 0` (line 7081). `-mc 0` is the usual fix for whisper looping on
  long audio. Tacet must never adopt it without moving the vocabulary somewhere else first.

So the list has two kinds of entry:

- **Terms** (`Tacet`, `ClickHouse`). The server puts as many into the prompt as fit
  (see "Prompt selection"). Terms that don't fit are kept and shown as "not in prompt".
- **Corrections** (`replacing merge tree -> ReplacingMergeTree`). These are applied
  to the transcript after decoding, in any number. They are deterministic and cost
  nothing at decode time.

A term that has neither a correction nor a place in the prompt gets no help. That
is the honest limit of v1.

Expect the prompt to help, not to fix everything. An internal long-form eval (not
dictation) found that a glossary prompt cut name errors by roughly a fifth on clean
audio, and hurt on noisy multi-speaker audio.

### D3. Corrections are a write path into the terminal, so the server bounds them

The authority this grants was approved on 2026-11-06.

A correction rewrites every later transcript, and tacet pastes into terminals. If a
Claude session were hijacked by text it read, such as a README or a web page, it could
try to add a rule that turns a common word into a command. The server enforces these
limits. Neither the CLI nor the skill is the boundary.

1. **Corrections run before `Sanitize`.** They are applied at `TacetServer.swift:312`
   before `Sanitize.sanitize`, so control-character and newline stripping always runs last.
2. **A replacement must be a respelling of its trigger. This is the guard that matters.**
   Both sides are lowercased and stripped to letters and digits. The edit distance
   between them must be at most 40% of the longer one.

   | Trigger | Replacement | Distance | Result |
   |---|---|---:|---|
   | replacing merge tree | ReplacingMergeTree | 0.00 | accepted |
   | click house | ClickHouse | 0.00 | accepted |
   | post gress | Postgres | 0.11 | accepted |
   | a lambic | Alembic | 0.14 | accepted |
   | cloud code | Claude Code | 0.20 | accepted |
   | cuber netties | Kubernetes | 0.25 | accepted |
   | tea mux | tmux | 0.33 | accepted |
   | sequel | SQL | 0.50 | **refused**: a legitimate rule that is lost; put `SQL` in the prompt instead |
   | remove | rm -rf | 0.67 | refused |
   | ls | rm -rf / | 1.00 | refused |
   | of the | rm -rf | 1.00 | refused |

   **Residual risk.** A rule can only respell something the user actually said into
   something that looks like it. `rm rf -> rm -rf /` would pass, but only fires if the
   user dictates "rm rf". The threshold is a choice; a phonetic key such as Double
   Metaphone is the alternative.
3. **Character and length limits stay as a backstop.**
   - Replacements are limited to letters, digits, spaces and `- _ . + # / @ :`, with
     no shell metacharacters such as `; | & $ ~` or backticks.
   - They can be at most 64 characters and at most 3 words.
   - A correction's replacement also becomes a term, so it is visible in `list`.
4. **Real words are refused as single-word triggers.** If the trigger is one word found
   in `/usr/share/dict/words`, the correction is refused. That file ships with macOS
   (web2, 235k words) and needs no AppKit inside a launchd job. The replacement is
   added as a term instead, and the response says why.
   - "tacit -> Tacet" becomes the term "Tacet", because a rule would rewrite "tacit agreement".
   - `NSSpellChecker` is a possible alternative, but whether it works in `tacet serve`
     under launchd, with no `NSApplication`, is unverified.

**New authority, for explicit approval.** The endpoint in D4 lets anyone holding the
key change *future* transcripts. Today the key only lets you transcribe your own audio.
With guard 2, a change is limited to respelling what was said. Without it, the only
remaining protections are that no newline survives and that the user sees the text
before pressing Enter.

### D4. Claude Code reaches the list through a CLI and a skill

Both are thin. The server validates everything.

- **Endpoint.** `GET` and `POST /vocabulary` on `tacet serve`. They require
  `X-Tacet-Key`, like `/dictate`. `POST` requires `Content-Type: application/json`,
  which a browser can't send cross-site without a preflight. That's the same reasoning
  as `/dictate`'s `audio/wav` check at `TacetServer.swift:265-271`.
- **CLI.** `tacet vocab list | add TERM... | fix WRONG RIGHT | remove ENTRY...`, as
  a third role beside `serve` and `agent` in `main.swift`.
  - It finds the server from `~/.config/tacet/client.json`, taking scheme, host and
    port from the stored `/dictate` URL.
  - On a server-only Mac with no `client.json`, it falls back to `~/.config/tacet/key`
    and loopback on the configured port.
  - It prints every change and every refusal with its reason.
- **Skill.** `tacet-vocab` ships in the repo, and `install-client.sh` offers to install it.
  It tells Claude three things:
  - Edit the vocabulary only when the user asks in the current turn.
  - For "you heard X, I meant Y", find the mistranscribed text in the conversation,
    propose the pair, then run `tacet vocab fix`.
  - Relay the CLI's output, including refusals, verbatim.

  The skill is guidance, not a security boundary (D3 is).
- **No MCP server and no menu UI in v1.** Anything Claude can reach with a shell can
  reach the CLI. A menu item can come later on top of the same endpoint.

## Defaults the implementer may change

- **File.** `~/.config/tacet/vocabulary.txt` on the server. The path is configurable as
  `[vocabulary] path` in `config.toml`.
  - One entry per line: a term, or `wrong -> Right`. `#` starts a comment.
  - Written atomically (temp file and rename), and re-read when its mtime changes, so hand
    edits work.
- **Preamble.** The prompt is a configurable `[vocabulary] preamble` (migrated from
  today's "Technical dictation.") plus `Vocabulary: ` and the terms, comma-separated.
- **Prompt selection.**
  - Terms with no correction rule go in first, because the prompt is their only help.
    A homophone like "Tacet", whose correction is refused, is exactly this case.
  - Within each group, newest first.
  - In the prompt string, the most important terms go *last*. The budget is an
    estimate, and whisper keeps the tail if it overflows.
- **Per-request prompt.** whisper-server 1.8.4 reads a `prompt` field on each
  `/inference` request (`examples/server/server.cpp:561`) and resets parameters after
  every request (`server.cpp:1125`). `WhisperClient.makeMultipart` adds `prompt` beside
  `response_format` and `temperature` (`WhisperClient.swift:79`).
  - This reverses the "never per request" comment at `install-server.sh:300-304`, on
    purpose: the prompt must change without a reinstall.
- **Budget.** v1 has no access to whisper's tokenizer at run time, so it estimates tokens
  from characters.
  - The ratio is unmeasured. Calibrate it once against the existing prompt with whisper's
    tokenizer before fixing it. Short jargon such as `tmux` tokenizes worse than prose.
  - Start with a cap well below whisper's 223 until longer prompts are measured on real
    recordings. `list` shows the estimate and the cap.
- **Matching.** Corrections match case-insensitively on whole words, with flexible
  whitespace. They are applied longest-trigger first in a single pass, so one rule's
  output is never fed to another.
- **Interaction with sentence spacing.** `Sanitize` adds a space after `.`, `!` or `?`
  before an uppercase letter. That splits `ASP.NET` into `ASP. NET` and `U.S.` into
  `U. S.`, both in whisper's own output today and in any dotted replacement. Fix it
  separately; it isn't specific to vocabulary.
- **Health.** `/health` is unchanged, because the doctor and the agent both probe it.
  Instead the server logs the term count at start and the prompt's term and token
  counts on every dictation, `tacet vocab list` reports the budget and any ignored
  lines, and `install-server.sh --doctor` fails if the file exists but is unreadable.
  - Losing the vocabulary silently is the 2026-08-05 failure mode: the prompt fell out
    of the plist and nothing reported it.
- **CLI on PATH.** Not done. The binary lives inside `Tacet.app`, and the skill finds it
  in `~/Applications` or `/Applications` itself; the README suggests an alias.

## Migration

- **Server start.** `tacet serve` checks whether `whisper.prompt` is non-empty and no
  vocabulary file exists. If so, it splits the `Vocabulary:` list into terms, writes
  the file and logs what it did. It warns if the text before the list differs from
  `[vocabulary] preamble`, which defaults to "Technical dictation.".
  - The server does this, not the installer, so it is unit-tested in Swift and also
    covers a server whose binary was updated without re-running the installer.
  - Until the file exists, the server serves the legacy prompt's terms. Its prompt field
    always overrides the plist's `--prompt`, so sending an empty prompt then would
    silently drop the biasing.
- **One copy of the prompt.** The whisper-server plist stops getting `--prompt` in the
  same change, so it never exists in two places.
- **Tests.** The drift-guard tests at `tests/test_install_server_doctor.py:272-300` are
  rewritten to assert the plist has no `--prompt` and that the migration ran.
- **Doctor.** `--doctor` warns if `whisper.prompt` is still set once the file exists.
- **Eval harness.** PR #29's harness passes `--prompt` as a server argument. It must send
  the prompt per request instead, or it measures a different path from production.

## Waits on real recordings

The plumbing above is deterministic and testable now. These need the recorded-voice
corpus from PR #29's harness:

- **Prompt size.** How large the prompt can grow before it creates text on silence.
  On synthetic audio, false texts went from 2 to 4 out of 7 silent clips once a prompt
  was added.
- **Starter pack.** Whether to ship an opt-in software-engineering term list, and its contents.
- **Preamble wording.**

## Out of scope for v1

- Separate lists for different people on one server. That needs per-person keys.
- Two servers sharing one list. `[vocabulary] path` pointed at a synced folder is a
  possible escape hatch. Whether a launchd job can read iCloud Drive files that macOS
  has offloaded is unverified.
- Sound-alike matching and re-decoding for terms beyond the prompt budget. This becomes
  worth measuring if real recordings show those terms still fail.
- An LLM cleanup pass. That question stays open.
- Claude Code sessions on hosts without tacet installed.

## Decided (2026-11-06)

1. **The new authority in D3 is approved.** A key holder can change future transcripts,
   limited to respellings.
2. **Single dictionary-word triggers are refused, with no override flag.**
3. **The respelling threshold is 40%, letter-based.** This is a default, not a settled
   value. Revisit it, or add sound-based matching, if refused acronyms such as
   `sequel -> SQL` turn out to be a nuisance in practice.
4. **Tracking is #30**, which supersedes #23 and #24.
