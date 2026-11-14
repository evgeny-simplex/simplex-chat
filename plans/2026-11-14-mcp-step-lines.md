# Quieter step lines

Status: the user's rules of 2026-11-14, implemented on `ep/mcp-step-lines-simple` from master. Changes the step lines of `plans/2026-11-12-mcp-activity.md`. Grouping of consecutive steps moves to the apps, through the status message type that the core adds; once the core has it, the plugin sends step lines as `{type: "status", text}`.

## 1. Rules

1. Icons: Edit and Write share ✏️, as `✏️ Edit PATH` and `✏️ Write PATH`. Grep, Glob and WebSearch share 🔍, as `🔍 Grep PATTERN in PATH` and `🔍 Search QUERY`.
2. A completed step has no ✅. Its time is in small print: `💻 Read how translated pages and their keys are defined !- 43 ms!`. A failure keeps ❌, an interruption ⏹️, and a launch in the background `(in background)`.

## 2. Decisions

1. The hook sends the step's text without an outcome. At the end it adds `ms`, from `duration_ms`, and `mark`: ❌, ⏹️ or `(in background)`.
2. The hub completes the line with `stepLine`: the text, the mark, and the duration of `ms` in small print, each when given.
3. A step end from an older hook, with its outcome in the text and without `ms`, is posted as its text.

## 3. Tests

- `test/unit/hook.test.ts`: the icons ✏️ and 🔍, and the end of a step as `{id, text, end, ms, mark}`.
- `test/unit/sessions.test.ts`: "shows a step's time in small print, keeps ❌ for a failure, ⏹️ for an interruption and (in background) for a launch, and drops ✅", and the first step test with the time in small print. Both fail without `stepLine`.
- `test/e2e/service.test.ts`: the Bash step ends as `💻 Run the tests !- 2.0 s!`, no longer live and not edited.
- `TESTING.md` check 4: durations in small print without ✅, and the ✏️ and 🔍 lines.
