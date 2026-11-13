# rr

A text interface to Apple Reminders. The Reminders UI is infuriating and Siri
can't do complex recurring reminders, so: type a sentence, check the
interpretation, accept or reject.

```
$ rr "pay estimated taxes every quarter on the 10th, remind me 3 days before"
Pay estimated taxes
  list:    Reminders
  repeats: every 3 months on the 10th
  alert:   3 days before, 9:00 AM
  next:    Jan 10, Apr 10, Jul 10, Oct 10
  assumed: quarters start in January; alert time 9:00 AM (default)
Create? [y/n]
```

## Why build it

Existing CLIs manage Reminders programmatically: you translate your intention
into flags. This tool is for the step before that: saying a complicated
reminder in one sentence and seeing what it will actually do before it exists.

| | rr (planned) | [rem](https://github.com/BRO3886/rem) | [remi](https://github.com/mattheworiordan/remi) | [remindctl](https://github.com/steipete/remindctl) | [reminders-cli](https://github.com/keith/reminders-cli) | [Raycast Apple Reminders](https://www.raycast.com/raycast/apple-reminders) |
|---|---|---|---|---|---|---|
| Kind | CLI | CLI | CLI | CLI | CLI | Raycast extension |
| Input | one sentence | flags | flags | flags | flags | one sentence (AI Quick Add) |
| Preview of upcoming dates before creating | yes | no | no | no | no | no; confirms AI-created recurrence |
| Assumptions shown | yes | no | no | no | no | no |
| Recurrence | EventKit rules | `--repeat`, patterns not documented | `every N` units, weekday lists | daily to yearly, `every N` units | not documented | `every N weeks`, weekdays, monthly |
| Day-of-month recurrence ("on the 10th") | yes | not documented | not documented | not documented | no | not documented |
| Alert before the due date | yes, relative, on every occurrence | `--remind-me 15m` | no alarm flag | `--alarm`, absolute time only | not documented | not documented |
| Natural-language due dates | via the model | yes, 30+ patterns | yes | today / tomorrow / yesterday, otherwise ISO | yes | yes |
| Tags | no | yes (private ReminderKit) | no | no | no | not documented |
| Sections | no | no | yes (private ReminderKit and direct SQLite writes) | no | no | no |

From each project's README or site on 2026-11-13; none of them tested, so
"not documented" may still work.

remi and remindctl can probably express the quarterly recurrence above with
flags: a due date on the 10th plus `every 3 months`. The early alert is less
clear. remi documents no alarm flag, remindctl's `--alarm` is one absolute
time, and rem does not say whether `--remind-me` repeats with the reminder.
So the gap is mainly the interface (sentence in, checked schedule out), plus
an early alert that is known to repeat.

## How it works

1. An LLM turns the sentence into a small JSON object (title, list, due date,
   recurrence, alerts, assumptions made), with output constrained to a schema.
2. Code, not the model, computes the actual dates and prints the next few
   occurrences. That list is what makes accept/reject trustworthy.
3. On `y`, the reminder is written through EventKit and iCloud syncs it to the
   phone.

## Design rules

- **Ambiguity is shown, not hidden.** Anything the model had to choose
  (which month a quarter starts, the alert time) appears in the preview.
- **One recurrence representation.** The preview and the writer use the same
  rule object, so the dates you approve are the dates Apple creates.
- **The model does not do date arithmetic.** It only extracts structure.
- **Narrow first.** Start with a small set of recurrence shapes and widen from
  real use. Month ends, leap years and daylight-saving changes need tests.

## Model

The provider is configurable from day one: provider, model and endpoint are
settings, not code. Anthropic's API plus any OpenAI-compatible endpoint (which
is what Ollama exposes) covers nearly everything.

- **Default: Claude Sonnet 5.5** (`claude-sonnet-5-5`), about $0.004 per
  reminder (estimate: ~700 tokens in, ~300 out at $2 / $10 per million).
- **Cheaper: Claude Haiku 5.5**, about $0.0002 per reminder.
- **Local: a 3–4B model via Ollama** (for example Gemma 3 4B), 2–3 GB. Reminder
  text stays on the machine; a few seconds of cold start.

## Constraints found so far

- **EventKit is required.** AppleScript's Reminders support has no recurrence,
  so the writer is a small Swift binary. It needs a one-time macOS permission
  prompt for Reminders access, which needs a usage string embedded in the binary.
- **Not in EventKit:** tags, subtasks, sections. `rem` reaches tags and `remi`
  reaches sections through Apple's private ReminderKit framework (`remi` also
  writes the Reminders SQLite database directly). Possible, but unsupported by
  Apple and liable to break on an OS update, so out of scope for now.
- **Mac only.** Siri remains the phone input.

## First thing to test

Before the parser: create one recurring reminder with a three-day-early alert
through EventKit, complete it on the iPhone, and check that the next occurrence
and its alert appear. Apple documents the APIs, not that end-to-end behaviour.

## Status

The name `rr` clashes only with Mozilla's Linux-only record-and-replay
debugger. `rem` and `remi` were ruled out because both are existing Apple
Reminders CLIs.
