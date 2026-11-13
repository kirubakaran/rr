# rr

A text interface to Apple Reminders. The Reminders UI is infuriating and Siri
can't do complex recurring reminders, so: type a sentence, check the
interpretation, accept or reject.

```
$ rr "pay estimated taxes every quarter on the 10th, remind me 3 days before"
Pay estimated taxes
  list:    Reminders
  due:     Sun, Jan 10, 2027, 9:00 AM
  repeats: every 3 months on the 10th
  alert:   3 days before (first: Thu, Jan 7, 2027, 9:00 AM)
  next:    Jan 10, 2027 · Apr 10, 2027 · Jul 10, 2027 · Oct 10, 2027
  assumed: quarters start in January; due at 9:00 AM (default; an early alert needs a time)
Create? [y/n]
```

## Install and use

```
make install        # builds a release binary and copies it to ~/.local/bin/rr
make test
```

Needs macOS 14 or later and Xcode's Swift toolchain. The first run that touches
Reminders shows the macOS permission prompt for your terminal.

```
rr "take out the trash every other thursday at 7pm"
rr --dry-run "..."      # interpretation only; never opens Reminders
rr --show-intent "..."  # also print the JSON the model returned
rr --intent FILE        # skip the model and use an intent JSON file
rr --lists              # your Reminders lists
rr --config             # settings in effect
```

Nothing is written until you answer `y`. A request outside the supported
shapes is refused with a reason; nothing is guessed.

## Settings

Optional file `~/.config/rr/config.json`; `RR_PROVIDER`, `RR_MODEL` and
`RR_ENDPOINT` override it for one run.

```json
{
  "provider": "anthropic",
  "model": "claude-sonnet-5-5",
  "endpoint": "https://api.anthropic.com",
  "api_key_env": "ANTHROPIC_API_KEY",
  "effort": "low",
  "default_time": "09:00",
  "preview_count": 4
}
```

Those are the defaults.

The API key is never read from the file. Store it once in the macOS Keychain:

```
rr --set-key
```

The environment variable named by `api_key_env` takes precedence when it is
set, which suits CI or a one-off override. To remove the stored key:
`security delete-generic-password -s rr -a anthropic`.

The Keychain item is read through `/usr/bin/security`, so other programs
running as you can read it the same way; it is kept out of your shell
environment and dotfiles, not locked to rr.
 For a local model through Ollama:

```json
{ "provider": "openai", "model": "gemma4:31b-mxfp8" }
```

`provider: "openai"` means any OpenAI-compatible endpoint and defaults to
Ollama at `http://localhost:11434/v1`.

## Why build it

Existing CLIs manage Reminders programmatically: you translate your intention
into flags. This tool is for the step before that: saying a complicated
reminder in one sentence and seeing what it will actually do before it exists.

| | rr | [rem](https://github.com/BRO3886/rem) | [remi](https://github.com/mattheworiordan/remi) | [remindctl](https://github.com/steipete/remindctl) | [reminders-cli](https://github.com/keith/reminders-cli) | [Raycast Apple Reminders](https://www.raycast.com/raycast/apple-reminders) |
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

1. An LLM turns the sentence into a small JSON object (title, list, start,
   time, recurrence, alerts, assumptions made), with output constrained to a
   schema. It is told today's date and your list names, nothing else.
2. Code, not the model, resolves that into a plan: the first due date, an
   explicit recurrence rule and alert offsets. It prints the next few
   occurrences from that rule. That list is what makes accept/reject trustworthy.
3. On `y`, the same rule is converted to an EventKit recurrence rule and saved,
   and iCloud syncs it to the phone.

Code layout: `Sources/RRCore` holds everything except EventKit (`Intent`,
`Rule`, `Plan`, preview, model call) and is unit tested. `Sources/rr` is the
command and the EventKit writer.

### Recurrence shapes supported

- every N days
- every N weeks on chosen weekdays
- every N months on days of the month (including the last day), or on the
  1st to 4th or last weekday ("the 2nd Tuesday")
- every N years in chosen months, on one day of the month or an ordinal weekday.
  This covers several fixed dates a year that share a day, such as the 15th of
  January, April, June and September.
- an end after a count, on a date, or after a length of time ("for 10 weeks")
- early alerts as minutes, hours, days or weeks before the due time

A timed reminder also gets an alarm at the due time itself; without one,
Reminders shows the time but does not notify.

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
- **Local: a model via Ollama.** Reminder text stays on the machine. Tried with
  `gemma4:31b-mxfp8`: about 35 seconds for the first call while the model
  loads. A 3–4B model should be faster but has not been tried.

## Constraints found so far

- **EventKit is required.** AppleScript's Reminders support has no recurrence,
  so the whole tool is one Swift binary. It needs a one-time macOS permission
  prompt for Reminders access; the usage string is embedded at link time.
- **Not in EventKit:** tags, subtasks, sections. `rem` reaches tags and `remi`
  reaches sections through Apple's private ReminderKit framework (`remi` also
  writes the Reminders SQLite database directly). Possible, but unsupported by
  Apple and liable to break on an OS update, so out of scope for now.
- **Mac only.** Siri remains the phone input.

## Still to test

Unit tests cover the date arithmetic (month ends, leap years, a daylight-saving
change, cycle alignment) and the conversion to EventKit rules. The model path
was run end to end against a local Ollama model in dry-run mode. Not yet done:

- **A real write.** No reminder has been created yet. Create one recurring
  reminder with a three-day-early alert, complete it on the iPhone, and check
  that the next occurrence and both alerts appear. Apple documents the APIs,
  not that end-to-end behaviour.
- **Apple's dates against the preview** for the less common shapes: yearly
  rules in several months, the 31st in short months, and every-N-weeks rules
  that include Sunday (the preview flags that last one as an assumption).
- **The Anthropic request.** No API key was available while building, so the
  default provider has not been called. The request sets the server-side
  fallback option for refusals on Claude Sonnet 5.5.

## Status

Built 2026-11-13, version 0.1.0, installed at `~/.local/bin/rr`.

The name `rr` clashes only with Mozilla's Linux-only record-and-replay
debugger. `rem` and `remi` were ruled out because both are existing Apple
Reminders CLIs.

## License

Copyright 2026 Insstant LLC. Licensed under the Apache License 2.0; see
[LICENSE](LICENSE) and [NOTICE](NOTICE).
