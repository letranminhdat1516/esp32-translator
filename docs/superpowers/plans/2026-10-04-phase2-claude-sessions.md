# Phase 2: Claude Sessions Near the Mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track every Claude Code session on the Mac, let the board pick and focus one (PWR ×3), show its state and last line on the Claude screen, notify per the spec, and answer permission requests (Allow / Deny / Always allow) and AskUserQuestion multiple choice (one page per question) from the touch screen.

**Architecture:** A spike (Task 1) first settles, on the real `claude` CLI, the exact hook JSON for AskUserQuestion answers, deny messages, "always allow" and session events; every later choice reads its Decisions table. The Mac daemon gains a pure `SessionTracker` (state per `session_id`), a `SessionHub` actor that pushes small session deltas only while the board reports Claude/picker mode, a generalised `RequestQueue` (permission and question requests, only the shown one answerable) and `AnswerMapping` (board answer → hook JSON, with both the preferred `updatedInput` path and the deny-with-reason fallback written out). The board gains pure, host-tested `sessions.c` (session table, order, badge) and `question.c` (pages, selection, answer bytes), a real picker list, a session view and Always allow on the Claude screen, and question pages (`question_ui.c`). Everything rides the existing encrypted Claude characteristics with new message kinds and a compatible extension of the 5-byte answer.

**Tech Stack:** Swift 6 package with Swift Testing (`mac/`), Python 3 standard library (installer + its unittest, spike scripts), ESP-IDF 5.5, FreeRTOS, LVGL 9.6 (esp_lvgl_adapter), NimBLE; host C tests compiled with `cc`; tmux + the `claude` CLI for the spike and the end-to-end check; `bleak` (already used by `firmware/test/claude_ble_test.py`) for the on-device fake-Mac script.

**Spec:** `docs/superpowers/specs/2026-10-04-board-modes-claude-sessions-design.md` (section "Phase 2: Claude sessions near the Mac (BLE)"), plus the board UI agreed in conversation (copied into Global Constraints below; binding). Phase 1 plan for conventions: `docs/superpowers/plans/2026-10-04-phase1-board-shell.md`.

## Global Constraints

- Hooks (spec, verbatim): "Additional hooks, all `async: true` except the existing PermissionRequest: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`, `Notification` (all types). The hook CLI also forwards `$TMUX_PANE` (and tmux socket) from its environment when present."
- Per session (spec): "`session_id`, project (basename of cwd), state, started/updated time, last assistant line (from the transcript on Stop), `tmux_pane` (optional)."
- States (spec): "**working** (after UserPromptSubmit), **needs you** (pending PermissionRequest or AskUserQuestion), **idle** (after Stop / idle_prompt), **ended** (SessionEnd; dropped after 10 min). If SessionStart/SessionEnd hooks are not available in settings hooks, sessions are created on first event and ended after 2 h without events."
- Session picker (agreed): PWR ×3; ≤ 6 rows, "needs you" first, then most recent; dot colours red = needs you, yellow = working, green = idle, grey = ended; tap a row → focus it → Claude screen; a badge counts unseen "done" events of non-focused sessions.
- Claude screen (agreed): focused session's project, state, elapsed time, last assistant line.
- Notifications (agreed): focused session done → chime + last line; focused session needs you → wake + show; non-focused session done → silent, badge only; any session's permission request or question → shown with the project tag, and it must not stall Claude (timeouts fall through to the terminal).
- Permission (agreed): Allow / Deny / **Always allow** — the third button only when a usable suggestion exists and the spike verified a working "always allow" field.
- Question (agreed): one page per question ("1/3" header with the project name); each option a full-width row; single-select: tap highlights, **Send** confirms (disabled until something is selected); multi-select: checkboxes + **Send**; long-press shows the option's description; vertical scroll for long lists; with several questions, Send on the last page sends all; the "Other 🎤" slot is Phase 3 and is **not rendered** in Phase 2.
- Answer controls: the existing 700 ms arming (`ARM_DELAY_US`) and dark-panel tap rejection apply to every answer control (Allow, Deny, Always allow, option rows, Next/Send, Back).
- Never auto-approve: the Mac decides nothing on its own; every answer comes from a board tap; any failure (no board, timeout, hook gone, unsupported question shape) prints nothing and Claude shows its normal terminal prompt.
- Answer delivery (spec): "Preferred: allow with `updatedInput` carrying the answers. Fallback (documented, always works): **deny with a reason** "The user answered on the board: <question> → <choice>" so Claude proceeds with that choice." "Always allow": "use the documented rule mechanism if verified; otherwise the button is not shown." The spike's Decisions table picks; both code paths exist.
- Battery (spec + agreed): session list/state go to the board only while it reports Claude or picker mode (the board tells the Mac its mode), as small deltas; requests, cancels and the focused session's "done" go in any mode. No new board timers except a 30 s elapsed-time refresh that exists only while the Claude screen is loaded and skips work while the panel is dark.
- Wire (spec): "New board message kinds on the existing encrypted Claude characteristics (same chunking) … Ids are never 0; only the request shown on the board can be answered." Request text is at most `CLAUDE_TEXT_MAX` = 400 bytes (the Mac cuts fields UTF-8-safely to fit, the board cuts again as a backstop); one write is at most 512 bytes; board → Mac notifications are at most 10 bytes (fit the 20-byte default-MTU notify). Session handles are never 0 either; id 0 on the answer characteristic marks board events (mode, focus).
- Board UI text is English and uses only `font_vi_22` / `font_vi_36` (ASCII + Vietnamese + `·` `…` `—`; no emoji, no `×`; write "PWR x3").
- LVGL threading (Phase 1, unchanged): calls from non-LVGL tasks only between `bsp_display_lock((uint32_t)-1)` and `bsp_display_unlock()`; never take that lock inside LVGL event callbacks or `lv_timer` callbacks (they already run with it held). Functions named `*_locked` expect the lock held. Never delete an object from inside its own event callback.
- The spike never edits `~/.claude/settings.json`; it uses a project-local `.claude/settings.local.json` in a temp directory and stops the board daemon while it runs (`launchctl bootout gui/$(id -u)/dev.cicca.claude-board`), restarting it afterwards (`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.cicca.claude-board.plist`).
- Commands: Mac `cd mac && swift test`; installer test `cd mac && python3 -m unittest test_claude_settings -v`; host C tests `cd firmware/test && cc -Wall -Werror -I../main -o /tmp/<name> <name>.c ../main/<module>.c [...] && /tmp/<name>`; firmware `. ~/esp/esp-idf/export.sh && cd firmware && idf.py build` (flash: `idf.py -p /dev/cu.usbmodem1101 flash monitor`).
- Every commit message ends with exactly these two lines (after a blank line):
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
  ```

## Review Focus

1. **A second request arrives while one is on the board** (two sessions asking at once, or a question queued behind a permission): only the head request can be answered; an answer with a stale id or the wrong shape (permission answer for a question, wrong number of masks, Always allow when not offered) is ignored; question pages with a new id replace a half-received set (Task 5 tests `answerForQueuedRequestIsIgnored`, `answersMustFitTheQuestionShape`; Task 9 test `new_id_starts_a_new_set`).
2. **Question or option text the board cannot hold**: long Vietnamese, emoji, newlines or tabs inside a question or label, more than 4 questions or options, duplicate question texts: the Mac cuts every field UTF-8-safely so the message stays ≤ 400 bytes, turns control characters into spaces, and lets shapes the board cannot show fall through to the terminal at once (Task 3 tests `questionTextStaysWithinBoardLimit`, `newlinesInFieldsBecomeSpaces`, `parseRejectsShapesTheBoardCannotShow`; Task 6 test `unsupportedQuestionFallsThroughImmediately`; Task 8 test `question_rejects_bad_shapes`).
3. **The user answers in the terminal or Remote Control while the board shows the question**: the hook goes away, the Mac sends a cancel, the board drops the pages and returns; a late Send is never applied (Task 6 test `hookDisconnectCancelsQuestion`; Task 5 test `answerForQueuedRequestIsIgnored` covers the late id; Task 11 on-device row 8).
4. **Reconnects and mode flips**: board reboot, Mac Bluetooth off/on, the board leaving and re-entering Claude mode: the picker never shows stale or duplicated rows — every activation and every reconnect while active starts with a clear, and nothing session-related is sent while the board is in translator mode or locked (Task 7 tests `activationSendsClearThenAllRows`, `reconnectWhileActiveResyncs`, `inactiveBoardGetsNoSessionTraffic`, `disconnectStopsTraffic`).
5. **Selection edge cases**: tapping the selected single-select option again, a multi-select page with nothing ticked, a fast double tap on Next that would land on Send: the selection stays, Send stays disabled until every page is answered, and controls re-arm (700 ms) on every page change (Task 9 tests `single_select_replaces_and_retap_keeps`, `multi_select_needs_one`, `send_needs_every_page`; Task 11 on-device row 4).

---

## File structure

```
docs/superpowers/notes/2026-10-04-hook-spike.md   NEW  Task 1 findings: verified hook JSON + Decisions table

mac/Sources/ClaudeBoardCore/
  HookEvent.swift        MOD  tmux pane/socket, permission_suggestions; JSONValue accessors
  HookEnvelope.swift     NEW  hook side: adds $TMUX_PANE / $TMUX to the event line
  HookSchema.swift       NEW  the spike's decisions in one place (deny key, always-allow style, answer style, session hooks)
  SocketProtocol.swift   MOD  BridgeReply carries message / updatedInput / updatedPermissions; HookOutput builds the JSON
  Utf8.swift             NEW  byte budgets: fit, share, oneLine
  AskQuestion.swift      NEW  AskUserQuestion tool_input → questions the board can show
  Sessions.swift         NEW  SessionState, SessionRow, board order
  BoardInput.swift       NEW  board → Mac bytes (choice, answers, mode, focus)
  BoardMessage.swift     MOD  kinds 4–7, permission rule line, byte budgets; Answer removed in Task 5
  SessionTracker.swift   NEW  per-session state machine (pure)
  RequestQueue.swift     MOD  RequestShape / BoardResponse, question requests, post()
  AnswerMapping.swift    NEW  board answer → hook reply (updatedInput / deny reason / always allow)
  SessionHub.swift       NEW  tracker + board mode/focus + delta sync (+ SessionSync.diff)
  HookProcessor.swift    MOD  questions, always allow, sessions
mac/Sources/claude-board/BoardLink.swift   MOD  onInput(BoardInput)
mac/Sources/claude-board/main.swift        MOD  hub wiring, 60 s tick
mac/Sources/claude-board-hook/main.swift   MOD  forwards the tmux environment
mac/claude_settings.py                     MOD  session hooks, all notification types
mac/test_claude_settings.py                NEW
mac/Tests/ClaudeBoardCoreTests/
  HookEnvelopeTests.swift   NEW   ProtocolV2Tests.swift  NEW   SessionTrackerTests.swift NEW
  AnswerMappingTests.swift  NEW   SessionHubTests.swift  NEW
  CoreTests.swift, RequestQueueTests.swift, HookProcessorTests.swift, SocketProtocolTests.swift  MOD

firmware/main/
  claude_proto.h / .c    MOD  kinds 4–7, session/question parsers, input encoders, UTF-8 cut, line split
  sessions.h / .c        NEW  session table (pure)
  question.h / .c        NEW  question pages + selection + answer bytes (pure)
  modes.h / .c           MOD  MODES_EV_PICK, modes_report()
  clock.h / clock_rtc.c  MOD  clock_now_unix()
  picker_ui.c            REWRITE  session list
  claude_ui.c            MOD  session view, badge, Always allow, question hand-off
  question_ui.c          NEW  question pages
  shell.c                MOD  reports the board mode to the Mac
  ble_link.c             MOD  generic Claude input notify
  main.c                 MOD  dispatch of the new kinds
  app.h                  MOD  declarations
  CMakeLists.txt         MOD  new sources
firmware/test/
  test_claude_proto.c MOD   test_sessions.c NEW   test_question.c NEW   test_modes.c MOD
  claude_ble_phase2.py NEW  fake Mac for on-device checks
README.md                 MOD  sessions, picker, questions, protocol
```

## Protocol (both sides implement exactly this)

Mac → board, request characteristic `…0011` (unchanged envelope): chunks `[flags u8][payload]`, flags bit0 = first, bit1 = last; assembled payload `[kind u8][id u32 LE][UTF-8 text ≤ 400 bytes]`.

| kind | name | id | text |
|---|---|---|---|
| 0 | permission | request id | `project\ntool\nsummary` or `project\ntool\nsummary\nrule` (4th line present ⇔ Always allow offered; it is the rule caption) |
| 1 | finished | fresh id | `project\nlast line` — now only for the **focused** session |
| 2 | cancel | request id | empty (cancels a permission or a whole question set) |
| 3 | time | 0 | unchanged |
| 4 | session (upsert) | session handle ≠ 0 | `"<state> <since> <updated> <flags>\n<project>\n<last line>"`; state `n` needs you, `w` working, `i` idle, `e` ended; since/updated = Unix seconds (decimal); flags decimal, bit0 focused, bit1 unseen |
| 5 | session remove | session handle | empty |
| 6 | sessions clear | 0 | empty (sent first in every full sync) |
| 7 | question page | request id | `"<index> <count> <multi> <nopt>\n<project>\n<header>\n<question>\n<label 1>\n<desc 1>…\n<label n>\n<desc n>"`; index 0-based < count ≤ 4; multi 0/1; nopt 1…4; exactly 4 + 2·nopt lines; labels non-empty |

Byte budgets (Mac, every field passed through `Utf8.oneLine` then `Utf8.fit`, which appends `…` when it cuts): permission project ≤ 60, tool ≤ 60, rule ≤ 80, summary = the rest; finished project ≤ 60, line = the rest; session project ≤ 60, line = the rest; question project ≤ 32, header ≤ 24, question ≤ 120, each label ≤ 32, descriptions share the rest (`Utf8.share`: short ones whole, long ones split the remainder evenly). Board: `claude_rx_feed` already cuts at 400 bytes UTF-8-safely; the session project is cut to 64 bytes.

Board → Mac, answer characteristic `…0012` (notify):

| bytes | meaning |
|---|---|
| `[id u32 LE][1]` / `[id][2]` | allow / deny (unchanged) |
| `[id u32 LE][3]` | always allow (only accepted when offered) |
| `[id u32 LE][0x10][n u8][mask_0]…[mask_{n-1}]` | question answers: n = question count, bit i of mask_q = option i chosen |
| `[0 0 0 0][0x20][mode u8]` | board mode: 0 other (translator or locked), 1 Claude, 2 picker |
| `[0 0 0 0][0x21][handle u32 LE]` | focus this session |

Shared test vectors (asserted in Swift and in C): answers id `0x01020304`, masks `[0x02, 0x05]` → `04 03 02 01 10 02 02 05`; always allow id `0x01020304` → `04 03 02 01 03`; mode picker → `00 00 00 00 20 02`; focus 7 → `00 00 00 00 21 07 00 00 00`; question page → `07 04 03 02 01` + `"0 2 0 3\nproj\nColor\nWhich color?\nRed\nWarm\nGreen\n\nBlue\nCool"`; session → `04 05 00 00 00` + `"w 1759555200 1759555260 1\ndự-án\nDone."`.

---

### Task 1: Hook spike on the real `claude` CLI (automated; run by an agent on the Mac)

**Files:**
- Create: `docs/superpowers/notes/2026-10-04-hook-spike.md`
- Temporary (not committed): a temp directory `$SPIKE` holding the spike scripts, a throwaway project and the logs.

**Interfaces:**
- Consumes: nothing.
- Produces: the findings doc with a **Decisions** table whose rows later tasks read verbatim:
  - `DENY_MESSAGE_KEY` = `message` | `reason` → `HookSchema.denyMessageKey` (Task 2)
  - `ALWAYS_ALLOW` = `suggestionsVerbatim` | `ruleRemember` | `unsupported` → `HookSchema.alwaysAllow` (Task 2)
  - `QUESTION_ANSWERS` = `updatedInputJoined` | `updatedInputArrays` | `denyWithReason` | `terminalOnly` → `HookSchema.questionAnswers` (Task 2)
  - `SESSION_HOOKS` = `true` | `false` → `HookSchema.sessionHooks` (Task 2) and `SESSION_HOOKS` in `mac/claude_settings.py` (Task 7)
  - `TMUX_PANE_VISIBLE` = `true` | `false` (informational for Phase 3)
  - `SUGGESTIONS_SHAPE` = the literal JSON of one `permission_suggestions` element (Task 6 parses both known shapes; this records which one is real)

This task needs: `tmux`, `python3`, the `claude` CLI logged in, and about 10 minutes of real Claude turns. Run every step from the repository root. Each Bash call starts a fresh shell, so every step re-reads `$SPIKE` from `/tmp/cb-spike-path` and sources `$SPIKE/lib.sh`.

- [ ] **Step 1: Create the spike directory, hook script, helpers and project settings**

```bash
SPIKE=$(mktemp -d "${TMPDIR:-/tmp}/cb-spike.XXXXXX")
echo "$SPIKE" > /tmp/cb-spike-path
mkdir -p "$SPIKE/proj/.claude" "$SPIKE/log" "$SPIKE/plan"

cat > "$SPIKE/hook.py" <<'PY'
#!/usr/bin/env python3
"""Spike hook: logs every event (stdin + tmux env); answers PermissionRequest from a one-shot plan file."""
import json, os, pathlib, sys, time

spike = pathlib.Path(sys.argv[1])
raw = sys.stdin.read()
try:
    ev = json.loads(raw)
except ValueError:
    ev = {"unparsed": raw}
name = ev.get("hook_event_name", "unknown")
stamp = time.time_ns()
rec = {"event": ev, "env": {k: os.environ.get(k) for k in ("TMUX_PANE", "TMUX")}}
(spike / "log" / f"{stamp}-{name}.json").write_text(json.dumps(rec, indent=2, ensure_ascii=False))


def picks(q):
    labels = [o["label"] for o in q.get("options", [])]
    if q.get("multiSelect"):
        return [labels[0], labels[-1]]          # multi: first and last option
    return labels[1:2]                           # single: the second option


def rule_caption(s):
    if isinstance(s, dict) and isinstance(s.get("rule"), str):
        return s["rule"]
    if isinstance(s, dict) and isinstance(s.get("rules"), list):
        parts = []
        for r in s["rules"]:
            t, c = r.get("toolName", ""), r.get("ruleContent")
            parts.append("%s(%s)" % (t, c) if c else t)
        return ", ".join(parts)
    return None


def build(spec, ev):
    d = {"behavior": spec["behavior"]}
    ti = ev.get("tool_input") or {}
    msg = spec.get("message")
    if msg == "AUTO_ANSWER":
        parts = ["%s → %s" % (q["question"], ", ".join(picks(q))) for q in ti.get("questions", [])]
        msg = "The user answered on the board: " + "; ".join(parts)
    if msg:
        d[spec.get("message_key", "message")] = msg
    style = spec.get("answers")
    if style:
        answers = {}
        for q in ti.get("questions", []):
            p = picks(q)
            answers[q["question"]] = ", ".join(p) if style == "joined" else p
        d["updatedInput"] = dict(ti, answers=answers)
    sugg = ev.get("permission_suggestions") or []
    if spec.get("permissions") == "suggestions" and sugg:
        d["updatedPermissions"] = sugg[:1]
    if spec.get("permissions") == "rule_remember" and sugg:
        d["updatedPermissions"] = {"rule": rule_caption(sugg[0]), "remember": True}
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": d}}


if name == "PermissionRequest":
    plan = spike / "plan" / ("%s.json" % ev.get("tool_name"))
    if plan.exists():
        spec = json.loads(plan.read_text())
        plan.unlink()
        out = build(spec, ev)
        (spike / "log" / f"{stamp}-reply-{ev.get('tool_name')}.json").write_text(
            json.dumps(out, indent=2, ensure_ascii=False))
        print(json.dumps(out, ensure_ascii=False))
sys.exit(0)
PY

cat > "$SPIKE/check.py" <<'PY'
#!/usr/bin/env python3
"""check.py SPIKE NEEDLE: prints transcript tool_result blocks containing NEEDLE; exit 1 if none."""
import json, pathlib, sys

spike, needle = pathlib.Path(sys.argv[1]), sys.argv[2]
paths = set()
for p in (spike / "log").glob("*.json"):
    ev = json.loads(p.read_text()).get("event", {})
    if isinstance(ev, dict) and ev.get("transcript_path"):
        paths.add(ev["transcript_path"])
found = False
for tp in paths:
    for line in open(tp, encoding="utf-8"):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        content = (o.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for c in content:
            if isinstance(c, dict) and c.get("type") == "tool_result":
                s = json.dumps(c, ensure_ascii=False)
                if needle in s:
                    print(s[:1500])
                    found = True
sys.exit(0 if found else 1)
PY

cat > "$SPIKE/summarize.py" <<'PY'
#!/usr/bin/env python3
"""summarize.py SPIKE: first logged stdin of each event (home dir shown as ~), env seen, every reply sent."""
import json, os, pathlib, sys

spike = pathlib.Path(sys.argv[1])
home = os.path.expanduser("~")
seen = {}
for p in sorted((spike / "log").glob("*.json")):
    rec = json.loads(p.read_text())
    if "event" in rec:
        ev = rec["event"]
        key = (ev.get("hook_event_name"), ev.get("tool_name") or ev.get("notification_type"))
        seen.setdefault(key, rec)
    else:
        print("REPLY", p.name, json.dumps(rec, ensure_ascii=False))
for key, rec in seen.items():
    print("\n###", key)
    print(json.dumps(rec, indent=2, ensure_ascii=False).replace(home, "~"))
PY

cat > "$SPIKE/lib.sh" <<'SH'
S=cbspike
SPIKE=$(cat /tmp/cb-spike-path)
say()      { tmux send-keys -t "$S" -l -- "$1"; sleep 1; tmux send-keys -t "$S" Enter; }
count()    { ls "$SPIKE"/log/*-"$1".json 2>/dev/null | wc -l | tr -d ' '; }
# wait_for EVENT N SECONDS: until at least N logs of EVENT exist
wait_for() { local end=$((SECONDS + $3)); while [ "$(count "$1")" -lt "$2" ]; do
               if [ $SECONDS -ge $end ]; then echo "TIMEOUT waiting for $1 #$2"; return 1; fi; sleep 2; done
             echo "got $1 #$2"; }
snap()     { tmux capture-pane -p -t "$S" -S -300 > "$SPIKE/pane-$1.txt"; tail -25 "$SPIKE/pane-$1.txt"; }
plan()     { printf '%s' "$2" > "$SPIKE/plan/$1.json"; }
ask_prompt() { # ask_prompt Q1 H1 A B C Q2 H2 X Y Z
  echo "Call the AskUserQuestion tool exactly once with exactly two questions. Question 1: question \"$1\", header \"$2\", options $3, $4, $5 (each with a one-sentence description), multiSelect false. Question 2: question \"$6\", header \"$7\", options $8, $9, ${10} (each with a one-sentence description), multiSelect true. After the tool returns, reply with one line that starts with RESULT: followed by exactly what the tool result told you."
}
SH

python3 - "$SPIKE" <<'PY'
import json, sys
spike = sys.argv[1]
cmd = "python3 '%s/hook.py' '%s'" % (spike, spike)
hook = lambda: [{"hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification"]
hooks = {e: hook() for e in events}
hooks["PermissionRequest"] = [{"matcher": "*", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
json.dump({"hooks": hooks}, open(spike + "/proj/.claude/settings.local.json", "w"), indent=2)
PY
cat "$SPIKE/proj/.claude/settings.local.json"
```

Expected: the settings file prints with six hook events, each running `python3 '<spike>/hook.py' '<spike>'`.

- [ ] **Step 2: Stop the board daemon so only the spike hook decides**

```bash
launchctl bootout "gui/$(id -u)/dev.cicca.claude-board" 2>/dev/null || true
sleep 1
launchctl print "gui/$(id -u)/dev.cicca.claude-board" >/dev/null 2>&1 && echo "STILL RUNNING" || echo "daemon stopped"
```

Expected: `daemon stopped`. From here on, if any step fails, still run Step 11 (restart) before stopping.

- [ ] **Step 3: Start Claude in tmux and record SessionStart**

```bash
. "$(cat /tmp/cb-spike-path)/lib.sh"
tmux kill-session -t "$S" 2>/dev/null || true
tmux new-session -d -s "$S" -x 220 -y 60 -c "$SPIKE/proj" "claude --permission-mode default"
sleep 10; snap start
# Folder trust dialog: accept it (default choice is "Yes, proceed")
if grep -qi "trust" "$SPIKE/pane-start.txt"; then tmux send-keys -t "$S" Enter; sleep 5; snap start2; fi
wait_for SessionStart 1 30 || true
```

Expected: the pane shows Claude's prompt; `got SessionStart #1` (if it prints `TIMEOUT`, SessionStart hooks did not fire from settings: that is a finding, `SESSION_HOOKS = false`, continue).

- [ ] **Step 4: Round A — AskUserQuestion answered via `updatedInput.answers` (values joined with ", ")**

```bash
. "$(cat /tmp/cb-spike-path)/lib.sh"
plan AskUserQuestion '{"behavior":"allow","answers":"joined"}'
pr=$(count PermissionRequest); st=$(count Stop)
say "$(ask_prompt 'Which color?' Color Red Green Blue 'Which fruits?' Fruits Apple Banana Cherry)"
wait_for PermissionRequest $((pr + 1)) 120
wait_for Stop $((st + 1)) 150 || { snap A-stuck; tmux send-keys -t "$S" Escape; wait_for Stop $((st + 1)) 60; }
snap A
python3 "$SPIKE/check.py" "$SPIKE" Green && python3 "$SPIKE/check.py" "$SPIKE" Cherry && echo "ROUND A WORKS"
```

Expected outcome decides `QUESTION_ANSWERS`: `ROUND A WORKS` and the pane's `RESULT:` line naming Green, Apple and Cherry, with no question dialog left waiting in the pane → `updatedInputJoined`. If the question dialog appeared in the pane anyway (`A-stuck`), or the tool result does not contain the picks, Round A failed: run Step 5.

- [ ] **Step 5: Round B (only if Round A failed) — answers as arrays**

```bash
. "$(cat /tmp/cb-spike-path)/lib.sh"
plan AskUserQuestion '{"behavior":"allow","answers":"arrays"}'
pr=$(count PermissionRequest); st=$(count Stop)
say "$(ask_prompt 'Which pet?' Pet Cat Dog Fox 'Which tools?' Tools Hammer Saw Drill)"
wait_for PermissionRequest $((pr + 1)) 120
wait_for Stop $((st + 1)) 150 || { snap B-stuck; tmux send-keys -t "$S" Escape; wait_for Stop $((st + 1)) 60; }
snap B
python3 "$SPIKE/check.py" "$SPIKE" Dog && python3 "$SPIKE/check.py" "$SPIKE" Drill && echo "ROUND B WORKS"
```

Expected: `ROUND B WORKS` → `updatedInputArrays`; otherwise neither `updatedInput` shape works and the answer style is decided by Step 6.

- [ ] **Step 6: Round C — the spec fallback: deny with a reason (always run)**

```bash
. "$(cat /tmp/cb-spike-path)/lib.sh"
plan AskUserQuestion '{"behavior":"deny","message_key":"message","message":"AUTO_ANSWER"}'
pr=$(count PermissionRequest); st=$(count Stop)
say "$(ask_prompt 'Which planet?' Planet Venus Mars Jupiter 'Which moons?' Moons Io Europa Titan)"
wait_for PermissionRequest $((pr + 1)) 120
wait_for Stop $((st + 1)) 150 || { snap C-stuck; tmux send-keys -t "$S" Escape; wait_for Stop $((st + 1)) 60; }
snap C
python3 "$SPIKE/check.py" "$SPIKE" "answered on the board: Which planet?" && echo "ROUND C (message) WORKS"
```

If it does not print `ROUND C (message) WORKS`, repeat with the other key and new labels:

```bash
. "$(cat /tmp/cb-spike-path)/lib.sh"
plan AskUserQuestion '{"behavior":"deny","message_key":"reason","message":"AUTO_ANSWER"}'
pr=$(count PermissionRequest); st=$(count Stop)
say "$(ask_prompt 'Which season?' Season Spring Summer Winter 'Which sports?' Sports Golf Judo Polo)"
wait_for PermissionRequest $((pr + 1)) 120
wait_for Stop $((st + 1)) 150 || { snap C2-stuck; tmux send-keys -t "$S" Escape; wait_for Stop $((st + 1)) 60; }
snap C2
python3 "$SPIKE/check.py" "$SPIKE" "answered on the board: Which season?" && echo "ROUND C (reason) WORKS"
```

Expected: one of the two works; its key is `DENY_MESSAGE_KEY`. Also read the pane: Claude's `RESULT:` line (or its next words) must show it took the choice (Mars, Io, Titan / Summer, Golf, Polo).

- [ ] **Step 7: Round D — Bash deny carries a message Claude sees**

```bash
. "$(cat /tmp/cb-spike-path)/lib.sh"
KEY=message   # use the key that worked in Step 6
plan Bash "{\"behavior\":\"deny\",\"message_key\":\"$KEY\",\"message\":\"SPIKE-D1-DENIED\"}"
pr=$(count PermissionRequest); st=$(count Stop)
say "Run this exact shell command with the Bash tool and nothing else: touch spike-d1.txt"
wait_for PermissionRequest $((pr + 1)) 120
wait_for Stop $((st + 1)) 150
snap D
python3 "$SPIKE/check.py" "$SPIKE" SPIKE-D1-DENIED && echo "ROUND D WORKS"
```

Expected: `ROUND D WORKS` (confirms the key for permissions too). If the PermissionRequest wait times out, the user's global allowlist already allows `touch`: repeat with `mkfifo spike-d1.fifo` instead.

- [ ] **Step 8: Round E — "Always allow"**

```bash
. "$(cat /tmp/cb-spike-path)/lib.sh"
plan Bash '{"behavior":"allow","permissions":"suggestions"}'
pr=$(count PermissionRequest); st=$(count Stop)
say "Run this exact shell command with the Bash tool and nothing else: touch spike-e1.txt"
wait_for PermissionRequest $((pr + 1)) 120
wait_for Stop $((st + 1)) 150
snap E1
ls -t "$SPIKE"/log/*-PermissionRequest.json | head -1 | xargs python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["event"].get("permission_suggestions"), indent=2))'
cat "$SPIKE/proj/.claude/settings.local.json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("permissions"))'
pr=$(count PermissionRequest); st=$(count Stop)
say "Run the exact same command again with the Bash tool: touch spike-e1.txt"
wait_for Stop $((st + 1)) 150
[ "$(count PermissionRequest)" = "$pr" ] && echo "ROUND E1 (suggestions verbatim) WORKS" || echo "E1: asked again"
```

Expected: the printed `permission_suggestions` is the `SUGGESTIONS_SHAPE` (copy one element verbatim). `ROUND E1 … WORKS` → `ALWAYS_ALLOW = suggestionsVerbatim`. If the suggestions were `null`/absent, `ALWAYS_ALLOW = unsupported` (no rule to offer) and skip the rest. If E1 asked again, try the documented object form:

```bash
. "$(cat /tmp/cb-spike-path)/lib.sh"
plan Bash '{"behavior":"allow","permissions":"rule_remember"}'
pr=$(count PermissionRequest); st=$(count Stop)
say "Run this exact shell command with the Bash tool and nothing else: cp /dev/null spike-e2.txt"
wait_for PermissionRequest $((pr + 1)) 120
wait_for Stop $((st + 1)) 150
pr=$(count PermissionRequest); st=$(count Stop)
say "Run the exact same command again with the Bash tool: cp /dev/null spike-e2.txt"
wait_for Stop $((st + 1)) 150
[ "$(count PermissionRequest)" = "$pr" ] && echo "ROUND E2 (rule+remember) WORKS" || echo "E2: asked again"
```

Expected: `ROUND E2 … WORKS` → `ruleRemember`; if both asked again → `unsupported`.

- [ ] **Step 9: Idle notification and SessionEnd**

```bash
. "$(cat /tmp/cb-spike-path)/lib.sh"
n=$(count Notification)
echo "waiting ~75 s for idle_prompt"; wait_for Notification $((n + 1)) 90 || true
say "/exit"
wait_for SessionEnd 1 30 || true
snap end
```

Expected: a Notification log (record its `notification_type`, expected `idle_prompt`) and `got SessionEnd #1` (a `TIMEOUT` means `SESSION_HOOKS = false` unless SessionStart did fire — then record "SessionStart yes, SessionEnd no" and set `SESSION_HOOKS = false`: the tracker's 2 h fallback is then needed).

- [ ] **Step 10: Summarise the raw data**

```bash
SPIKE=$(cat /tmp/cb-spike-path)
python3 "$SPIKE/summarize.py" "$SPIKE" > "$SPIKE/summary.txt"; wc -l "$SPIKE/summary.txt"
grep -h '"TMUX_PANE"' "$SPIKE"/log/*.json | sort | uniq -c
```

Expected: one block per (event, tool/notification type) and `TMUX_PANE` values like `"%3"` (not `null`) → `TMUX_PANE_VISIBLE = true`.

- [ ] **Step 11: Restart the board daemon (always)**

```bash
tmux kill-session -t cbspike 2>/dev/null || true
PL="$HOME/Library/LaunchAgents/dev.cicca.claude-board.plist"
[ -f "$PL" ] && launchctl bootstrap "gui/$(id -u)" "$PL" 2>/dev/null || true
sleep 2; launchctl print "gui/$(id -u)/dev.cicca.claude-board" | grep -m1 "state ="
```

Expected: `state = running` (if the plist does not exist the daemon was never installed: print nothing, fine).

- [ ] **Step 12: Write the findings doc**

Create `docs/superpowers/notes/2026-10-04-hook-spike.md` with this structure, filled from `$SPIKE/summary.txt`, the `pane-*.txt` files and the round results (paste JSON exactly as logged, home directory shown as `~`):

````markdown
# Hook spike findings (2026-10-04)

Claude Code version: <output of `claude --version`>. Method: interactive `claude --permission-mode default` in tmux, project-local
`.claude/settings.local.json` hooks, board daemon stopped. Rounds as in Phase 2 plan Task 1.

## Decisions

| Name | Value | Evidence |
|---|---|---|
| DENY_MESSAGE_KEY | message / reason | Round C/D result line |
| ALWAYS_ALLOW | suggestionsVerbatim / ruleRemember / unsupported | Round E result |
| QUESTION_ANSWERS | updatedInputJoined / updatedInputArrays / denyWithReason / terminalOnly | Rounds A–C |
| SESSION_HOOKS | true / false | SessionStart and SessionEnd logged? |
| TMUX_PANE_VISIBLE | true / false | env of any logged event |
| SUGGESTIONS_SHAPE | `<one permission_suggestions element, verbatim>` or `absent` | Round E1 |

Rule for QUESTION_ANSWERS: Round A worked → updatedInputJoined; else Round B worked → updatedInputArrays; else Round C worked →
denyWithReason; else terminalOnly.

## Verified stdin per event
### SessionStart / SessionEnd / UserPromptSubmit / Stop / Notification (<type>) / PermissionRequest (AskUserQuestion) / PermissionRequest (Bash)
```json
<first logged record of each>
```

## Replies tried and what Claude saw
For each round: the exact reply JSON printed by the hook, the tool_result text from the transcript (check.py output) and the
pane's last lines (did a dialog still appear?).
````

- [ ] **Step 13: Commit**

```bash
git add docs/superpowers/notes/2026-10-04-hook-spike.md
git commit -F - <<'EOF'
Spike: verified Claude Code hook shapes for sessions, questions and always-allow

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---
### Task 2: Mac — richer hook events, tmux forwarding, and hook output with message / updatedInput / updatedPermissions

**Files:**
- Modify: `mac/Sources/ClaudeBoardCore/HookEvent.swift`
- Create: `mac/Sources/ClaudeBoardCore/HookEnvelope.swift`, `mac/Sources/ClaudeBoardCore/HookSchema.swift`
- Modify: `mac/Sources/ClaudeBoardCore/SocketProtocol.swift:10-33` (BridgeReply, HookOutput)
- Modify: `mac/Sources/claude-board-hook/main.swift`
- Test: `mac/Tests/ClaudeBoardCoreTests/HookEnvelopeTests.swift`

**Interfaces:**
- Consumes: the Decisions table of `docs/superpowers/notes/2026-10-04-hook-spike.md` (Task 1).
- Produces:
  - `HookEvent` gains `permissionSuggestions: JSONValue?`, `tmuxPane: String?`, `tmuxSocket: String?`.
  - `JSONValue` gains `var array: [JSONValue]?`, `var object: [String: JSONValue]?`, `var bool: Bool?`.
  - `enum HookEnvelope { static func augment(_ event: Data, environment: [String: String]) -> Data }` (adds `claude_board_tmux_pane`, `claude_board_tmux`).
  - `enum AlwaysAllowStyle { case unsupported, suggestionsVerbatim, ruleRemember }`, `enum QuestionAnswerStyle { case updatedInputJoined, updatedInputArrays, denyWithReason, terminalOnly }`, `enum HookSchema { static let denyMessageKey: String; static let alwaysAllow: AlwaysAllowStyle; static let questionAnswers: QuestionAnswerStyle; static let sessionHooks: Bool }`.
  - `BridgeReply(decision: String?, message: String? = nil, updatedInput: JSONValue? = nil, updatedPermissions: JSONValue? = nil)`.
  - `HookOutput.output(for: BridgeReply?) -> String?` builds `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{…}}}`; `HookOutput.json(for: Decision) -> String` kept.

- [ ] **Step 1: Write the failing tests**

Create `mac/Tests/ClaudeBoardCoreTests/HookEnvelopeTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeBoardCore

private func object(_ d: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
}

@Test func envelopeAddsTmuxPaneAndSocket() throws {
    let raw = Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/p"}"#.utf8)
    let out = HookEnvelope.augment(raw, environment: ["TMUX_PANE": "%3", "TMUX": "/private/tmp/tmux-501/default,123,0"])
    let o = object(out)
    #expect(o["claude_board_tmux_pane"] as? String == "%3")
    #expect(o["claude_board_tmux"] as? String == "/private/tmp/tmux-501/default,123,0")
    #expect(o["session_id"] as? String == "s")
    #expect(!out.contains(0x0a))   // one line on the socket
    let e = try HookEvent.parse(out)
    #expect(e.tmuxPane == "%3" && e.tmuxSocket == "/private/tmp/tmux-501/default,123,0")
}

@Test func envelopeWithoutTmuxKeepsTheEvent() throws {
    let raw = Data("{\"hook_event_name\":\"Stop\",\n\"session_id\":\"s\"}\n".utf8)
    let out = HookEnvelope.augment(raw, environment: ["TMUX_PANE": ""])
    #expect(object(out)["claude_board_tmux_pane"] == nil)
    #expect(object(out)["session_id"] as? String == "s")
    #expect(!out.contains(0x0a))
    #expect(try HookEvent.parse(out).tmuxPane == nil)
}

@Test func envelopeLeavesGarbageAlone() {
    let raw = Data("not json".utf8)
    #expect(HookEnvelope.augment(raw, environment: ["TMUX_PANE": "%1"]) == raw)
}

@Test func parsesPermissionSuggestions() throws {
    let e = try HookEvent.parse(Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/p","tool_name":"Bash","tool_input":{"command":"git push"},"permission_suggestions":[{"rule":"Bash(git push *)","description":"Allow git push","specificity":"moderate"}]}"#.utf8))
    #expect(e.permissionSuggestions?.array?.first?.object?["rule"]?.string == "Bash(git push *)")
    let none = try HookEvent.parse(Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","permission_suggestions":null}"#.utf8))
    #expect(none.permissionSuggestions == nil)
}

@Test func outputCarriesDenyMessageUnderTheVerifiedKey() throws {
    let s = try #require(HookOutput.output(for: BridgeReply(decision: "deny", message: "The user answered on the board: Q → A")))
    let decision = (object(Data(s.utf8))["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    #expect(decision?["behavior"] as? String == "deny")
    #expect(decision?[HookSchema.denyMessageKey] as? String == "The user answered on the board: Q → A")
    #expect(decision?["updatedInput"] == nil)
}

@Test func outputCarriesUpdatedInputAndPermissionsOnlyWhenAllowing() throws {
    let input = JSONValue.object(["questions": .array([]), "answers": .object(["Q?": .string("A")])])
    let perms = JSONValue.array([.object(["rule": .string("Bash(npm test:*)")])])
    let allow = try #require(HookOutput.output(for: BridgeReply(decision: "allow", updatedInput: input, updatedPermissions: perms)))
    let d = (object(Data(allow.utf8))["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    #expect(((d?["updatedInput"] as? [String: Any])?["answers"] as? [String: Any])?["Q?"] as? String == "A")
    #expect(((d?["updatedPermissions"] as? [Any])?.first as? [String: Any])?["rule"] as? String == "Bash(npm test:*)")

    let deny = try #require(HookOutput.output(for: BridgeReply(decision: "deny", updatedInput: input, updatedPermissions: perms)))
    let dd = (object(Data(deny.utf8))["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    #expect(dd?["updatedInput"] == nil && dd?["updatedPermissions"] == nil)
}

@Test func onlyExplicitDecisionsBecomeOutput() {
    #expect(HookOutput.output(for: nil) == nil)
    #expect(HookOutput.output(for: BridgeReply(decision: nil, message: "x")) == nil)
    #expect(HookOutput.output(for: BridgeReply(decision: "ask")) == nil)
}

@Test func oldReplyLinesStillDecode() throws {
    let r = try JSONDecoder().decode(BridgeReply.self, from: Data(#"{"decision":"allow"}"#.utf8))
    #expect(r == BridgeReply(decision: "allow"))
    let enc = String(data: try JSONEncoder().encode(BridgeReply(decision: nil)), encoding: .utf8)
    #expect(enc == "{}")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test 2>&1 | tail -20`
Expected: build errors — `HookEnvelope`, `tmuxPane`, `permissionSuggestions`, `HookSchema` and the new `BridgeReply` initializer do not exist.

- [ ] **Step 3: Extend `HookEvent` and `JSONValue`**

In `mac/Sources/ClaudeBoardCore/HookEvent.swift`, after the line `public var string: String? { if case .string(let s) = self { s } else { nil } }` add:

```swift
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
```

Replace the whole `public struct HookEvent: Sendable { … }` with:

```swift
public struct HookEvent: Sendable {
    public let name: String
    public let sessionId: String
    public let cwd: String
    public let toolName: String?
    public let toolInput: [String: JSONValue]
    public let notificationType: String?
    public let lastAssistantMessage: String?
    public let transcriptPath: String?
    /// PermissionRequest: suggested rules that would approve this call (shape: see the hook spike notes)
    public var permissionSuggestions: JSONValue? = nil
    /// Added by claude-board-hook from its environment (HookEnvelope): the session's tmux pane and socket
    public var tmuxPane: String? = nil
    public var tmuxSocket: String? = nil

    private struct Raw: Decodable {
        let hook_event_name: String
        let session_id: String?
        let cwd: String?
        let tool_name: String?
        let tool_input: [String: JSONValue]?
        let notification_type: String?
        let last_assistant_message: String?
        let transcript_path: String?
        let permission_suggestions: JSONValue?
        let claude_board_tmux_pane: String?
        let claude_board_tmux: String?
    }

    public static func parse(_ data: Data) throws -> HookEvent {
        let r = try JSONDecoder().decode(Raw.self, from: data)
        return HookEvent(name: r.hook_event_name, sessionId: r.session_id ?? "", cwd: r.cwd ?? "",
                         toolName: r.tool_name, toolInput: r.tool_input ?? [:],
                         notificationType: r.notification_type,
                         lastAssistantMessage: r.last_assistant_message, transcriptPath: r.transcript_path,
                         permissionSuggestions: r.permission_suggestions,
                         tmuxPane: r.claude_board_tmux_pane, tmuxSocket: r.claude_board_tmux)
    }
}
```

(The three new fields are `var … = nil` so the memberwise initializer that `LastLineTests.swift` uses keeps compiling.)

- [ ] **Step 4: Create the envelope and the schema constants**

Create `mac/Sources/ClaudeBoardCore/HookEnvelope.swift`:

```swift
import Foundation

/// Hook side: the hook process inherits Claude Code's environment, so it can tell the daemon which tmux pane
/// the session runs in (Phase 3 types voice text there). Keys are prefixed so they never clash with Claude's.
public enum HookEnvelope {
    public static func augment(_ event: Data, environment: [String: String]) -> Data {
        guard var obj = (try? JSONSerialization.jsonObject(with: event)) as? [String: Any] else { return event }
        if let pane = environment["TMUX_PANE"], !pane.isEmpty { obj["claude_board_tmux_pane"] = pane }
        if let tmux = environment["TMUX"], !tmux.isEmpty { obj["claude_board_tmux"] = tmux }
        // Compact JSON has no raw newlines: the daemon reads exactly one line
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? event
    }
}
```

Create `mac/Sources/ClaudeBoardCore/HookSchema.swift`. Set the four values from the Decisions table in `docs/superpowers/notes/2026-10-04-hook-spike.md` (table value → Swift literal: `DENY_MESSAGE_KEY message` → `"message"`, `reason` → `"reason"`; `ALWAYS_ALLOW x` → `.x`; `QUESTION_ANSWERS x` → `.x`; `SESSION_HOOKS true/false` → `true/false`). The values below are the expected outcome; replace any that the spike contradicts:

```swift
import Foundation

/// How "Always allow" is sent back to Claude Code (verified in the hook spike).
public enum AlwaysAllowStyle: Sendable, Equatable {
    /// No verified mechanism: the board never offers the button
    case unsupported
    /// decision.updatedPermissions = [the first permission_suggestions element, verbatim]
    case suggestionsVerbatim
    /// decision.updatedPermissions = {"rule": <caption>, "remember": true}
    case ruleRemember
}

/// How AskUserQuestion answers reach Claude (verified in the hook spike).
public enum QuestionAnswerStyle: Sendable, Equatable {
    /// allow + updatedInput = tool_input + "answers": {question: "Label" or "A, B"}
    case updatedInputJoined
    /// allow + updatedInput = tool_input + "answers": {question: ["A", "B"]}
    case updatedInputArrays
    /// deny + message "The user answered on the board: Q → A; Q2 → B, C" (the spec's fallback)
    case denyWithReason
    /// Nothing works: questions are never shown on the board (Claude asks in the terminal)
    case terminalOnly
}

/// The hook spike's Decisions table (docs/superpowers/notes/2026-10-04-hook-spike.md), in one place.
public enum HookSchema {
    /// Key inside hookSpecificOutput.decision whose text Claude sees when a call is denied
    public static let denyMessageKey = "message"
    public static let alwaysAllow: AlwaysAllowStyle = .suggestionsVerbatim
    public static let questionAnswers: QuestionAnswerStyle = .updatedInputJoined
    /// SessionStart / SessionEnd fire from settings hooks (else: 2 h idle fallback)
    public static let sessionHooks = true
}
```

- [ ] **Step 5: Extend `BridgeReply` and `HookOutput`**

In `mac/Sources/ClaudeBoardCore/SocketProtocol.swift`, replace everything from `/// Daemon → hook, one JSON line` down to and including the closing brace of `extension HookOutput { … }` with:

```swift
/// Daemon → hook, one JSON line. Only `decision` "allow" or "deny" ever becomes a decision; the other
/// fields ride along with it (HookOutput decides which apply).
public struct BridgeReply: Codable, Equatable, Sendable {
    public let decision: String?
    /// Text Claude sees (deny reason, or the board's answers in the deny-with-reason fallback)
    public let message: String?
    /// Allow only: replaces the tool input (AskUserQuestion answers)
    public let updatedInput: JSONValue?
    /// Allow only: the "Always allow" rule
    public let updatedPermissions: JSONValue?

    public init(decision: String?, message: String? = nil, updatedInput: JSONValue? = nil,
                updatedPermissions: JSONValue? = nil) {
        self.decision = decision
        self.message = message
        self.updatedInput = updatedInput
        self.updatedPermissions = updatedPermissions
    }
}

public enum HookOutput {
    public static func json(for decision: Decision) -> String {
        output(for: BridgeReply(decision: decision == .allow ? "allow" : "deny"))!
    }

    /// Maps the daemon reply to the text the hook prints. nil = print nothing (Claude shows its normal prompt).
    /// Only an explicit "allow" or "deny" is ever turned into a decision.
    public static func output(for reply: BridgeReply?) -> String? {
        guard let reply, let behavior = reply.decision, behavior == "allow" || behavior == "deny" else { return nil }
        var decision: [String: JSONValue] = ["behavior": .string(behavior)]
        if let m = reply.message, !m.isEmpty { decision[HookSchema.denyMessageKey] = .string(m) }
        if behavior == "allow" {
            if let u = reply.updatedInput { decision["updatedInput"] = u }
            if let p = reply.updatedPermissions { decision["updatedPermissions"] = p }
        }
        let out = JSONValue.object(["hookSpecificOutput": .object([
            "hookEventName": .string("PermissionRequest"),
            "decision": .object(decision),
        ])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(out)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
```

- [ ] **Step 6: The hook forwards its tmux environment**

Replace `mac/Sources/claude-board-hook/main.swift` with:

```swift
// Claude Code hook: forwards the event (plus $TMUX_PANE / $TMUX) to the claude-board daemon.
// PermissionRequest: prints the board's decision, or nothing (Claude shows its normal prompt).
import ClaudeBoardCore
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = try? HookEvent.parse(input) else { exit(0) }

let line = HookEnvelope.augment(input, environment: ProcessInfo.processInfo.environment)
let isPermission = event.name == "PermissionRequest"
let reply = bridgeRoundTrip(event: line, waitForReply: isPermission, timeout: 92)

if isPermission, let out = HookOutput.output(for: reply) {
    print(out)
}
exit(0)
```

- [ ] **Step 7: Run all Mac tests**

Run: `cd mac && swift test 2>&1 | tail -5`
Expected: `Test run with N tests passed` (the existing `allowJsonMatchesClaudeCodeSchema` and `denyJson` still pass: the JSON is now key-sorted but has the same fields).

- [ ] **Step 8: Commit**

```bash
git add mac/Sources/ClaudeBoardCore/HookEvent.swift mac/Sources/ClaudeBoardCore/HookEnvelope.swift \
        mac/Sources/ClaudeBoardCore/HookSchema.swift mac/Sources/ClaudeBoardCore/SocketProtocol.swift \
        mac/Sources/claude-board-hook/main.swift mac/Tests/ClaudeBoardCoreTests/HookEnvelopeTests.swift
git commit -F - <<'EOF'
mac: hook forwards tmux pane; replies carry message, updatedInput, updatedPermissions

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 3: Mac — protocol v2 encoding (byte budgets, questions, session rows, board inputs)

**Files:**
- Create: `mac/Sources/ClaudeBoardCore/Utf8.swift`, `mac/Sources/ClaudeBoardCore/AskQuestion.swift`, `mac/Sources/ClaudeBoardCore/Sessions.swift`, `mac/Sources/ClaudeBoardCore/BoardInput.swift`
- Modify: `mac/Sources/ClaudeBoardCore/BoardMessage.swift`
- Modify: `mac/Tests/ClaudeBoardCoreTests/CoreTests.swift` (long-message test), `mac/Tests/ClaudeBoardCoreTests/RequestQueueTests.swift` (patterns), `mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift` (pattern)
- Test: `mac/Tests/ClaudeBoardCoreTests/ProtocolV2Tests.swift`

**Interfaces:**
- Consumes: `JSONValue.array/object/bool/string` (Task 2).
- Produces:
  - `enum Utf8 { static func fit(_ s: String, maxBytes: Int) -> String; static func share(_ items: [String], totalBytes: Int) -> [String]; static func oneLine(_ s: String) -> String }`
  - `struct AskOption { label: String; description: String }`, `struct AskQuestion { question: String; header: String; options: [AskOption]; multiSelect: Bool; static let maxQuestions = 4; static let maxOptions = 4; static func parse(_ input: [String: JSONValue]) -> [AskQuestion]? }`
  - `enum SessionState: String { case needsYou = "n", working = "w", idle = "i", ended = "e" }`, `struct SessionRow { handle: UInt32; state; since: Int64; updated: Int64; focused: Bool; unseen: Bool; project: String; lastLine: String; var flags: Int; static func boardOrder(_:_:) -> Bool }`
  - `enum BoardChoice: UInt8 { allow = 1, deny = 2, alwaysAllow = 3 }`, `enum BoardMode: UInt8 { other = 0, claude = 1, picker = 2 }`, `enum BoardInput { case choice(id: UInt32, BoardChoice); case answers(id: UInt32, masks: [UInt8]); case mode(BoardMode); case focus(handle: UInt32); static func decode(_ d: Data) -> BoardInput? }`
  - `BoardMessage` cases: `.permission(id:project:tool:summary:alwaysRule: String? = nil)`, `.finished`, `.cancel`, `.time`, `.session(SessionRow)`, `.sessionRemove(handle:)`, `.sessionsClear`, `.question(id:index:count:project:question:)`; `static let textMax = 400`.

- [ ] **Step 1: Write the failing tests**

Create `mac/Tests/ClaudeBoardCoreTests/ProtocolV2Tests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeBoardCore

private func text(_ m: BoardMessage) -> String { String(data: m.encode().dropFirst(5), encoding: .utf8)! }

// MARK: Utf8

@Test func fitKeepsShortStringsAndCutsLongOnesWithEllipsis() {
    #expect(Utf8.fit("abc", maxBytes: 3) == "abc")
    #expect(Utf8.fit("abcdef", maxBytes: 5) == "ab…")
    let cut = Utf8.fit(String(repeating: "ữ", count: 50), maxBytes: 20)   // 3 bytes each
    #expect(cut.utf8.count <= 20 && cut.hasSuffix("…") && cut.hasPrefix("ữữữữữ"))
    #expect(Utf8.fit("🇻🇳🇻🇳🇻🇳", maxBytes: 12) == "🇻🇳…")           // never splits a flag
    #expect(Utf8.fit("abcdef", maxBytes: 2) == "")
}

@Test func shareGivesShortItemsTheirLengthAndSplitsTheRest() {
    let out = Utf8.share(["ab", String(repeating: "x", count: 100), String(repeating: "y", count: 100)], totalBytes: 42)
    #expect(out[0] == "ab")
    #expect(out[1].utf8.count == 20 && out[2].utf8.count == 20)
    #expect(out.map { $0.utf8.count }.reduce(0, +) <= 42)
    #expect(Utf8.share(["a", "b"], totalBytes: 0) == ["", ""])
}

@Test func oneLineTurnsControlCharactersIntoSpaces() {
    #expect(Utf8.oneLine("a\nb\tc\r\nd\u{2028}e") == "a b c  d e")
    #expect(Utf8.oneLine("👨‍👩‍👧 ok") == "👨‍👩‍👧 ok")   // ZWJ sequences untouched
}

// MARK: AskQuestion

private let twoQuestions: [String: JSONValue] = [
    "questions": .array([
        .object(["question": .string("Which color?"), "header": .string("Color"), "multiSelect": .bool(false),
                 "options": .array([.object(["label": .string("Red"), "description": .string("Warm")]),
                                    .object(["label": .string("Green")])])]),
        .object(["question": .string("Which fruits?"), "header": .string("Fruits"), "multiSelect": .bool(true),
                 "options": .array([.object(["label": .string("Apple"), "description": .string("a")]),
                                    .object(["label": .string("Banana"), "description": .string("b")]),
                                    .object(["label": .string("Cherry"), "description": .string("c")])])]),
    ]),
]

@Test func parsesAskUserQuestionInput() throws {
    let qs = try #require(AskQuestion.parse(twoQuestions))
    #expect(qs.count == 2)
    #expect(qs[0] == AskQuestion(question: "Which color?", header: "Color",
                                 options: [AskOption(label: "Red", description: "Warm"), AskOption(label: "Green", description: "")],
                                 multiSelect: false))
    #expect(qs[1].multiSelect && qs[1].options.map(\.label) == ["Apple", "Banana", "Cherry"])
}

@Test func parseRejectsShapesTheBoardCannotShow() {
    func q(_ text: String, _ n: Int, label: String = "L") -> JSONValue {
        .object(["question": .string(text), "options": .array((0..<n).map { _ in .object(["label": .string(label)]) })])
    }
    #expect(AskQuestion.parse([:]) == nil)
    #expect(AskQuestion.parse(["questions": .array([])]) == nil)
    #expect(AskQuestion.parse(["questions": .array((1...5).map { q("Q\($0)?", 2) })]) == nil)   // > 4 questions
    #expect(AskQuestion.parse(["questions": .array([q("Q?", 5)])]) == nil)                        // > 4 options
    #expect(AskQuestion.parse(["questions": .array([q("Q?", 0)])]) == nil)                        // no options
    #expect(AskQuestion.parse(["questions": .array([q("Q?", 2, label: "  ")])]) == nil)          // empty label
    #expect(AskQuestion.parse(["questions": .array([q("Same?", 2), q("Same?", 2)])]) == nil)     // answers keyed by text
}

// MARK: Encoding

@Test func encodesQuestionPage() throws {
    let q = AskQuestion(question: "Which color?", header: "Color",
                        options: [AskOption(label: "Red", description: "Warm"), AskOption(label: "Green", description: ""),
                                  AskOption(label: "Blue", description: "Cool")], multiSelect: false)
    let d = BoardMessage.question(id: 0x01020304, index: 0, count: 2, project: "proj", question: q).encode()
    #expect(Array(d) == [7, 0x04, 0x03, 0x02, 0x01] + Array("0 2 0 3\nproj\nColor\nWhich color?\nRed\nWarm\nGreen\n\nBlue\nCool".utf8))
}

@Test func questionTextStaysWithinBoardLimit() {
    let long = String(repeating: "Mô tả rất dài bằng tiếng Việt 🚀 ", count: 20)
    let q = AskQuestion(question: String(repeating: "Câu hỏi dài? ", count: 30),
                        header: String(repeating: "Tiêu đề ", count: 10),
                        options: (1...4).map { AskOption(label: String(repeating: "Lựa chọn \($0) ", count: 10), description: long) },
                        multiSelect: true)
    let d = BoardMessage.question(id: 9, index: 3, count: 4, project: String(repeating: "dự-án-", count: 20), question: q).encode()
    #expect(d.count <= 5 + BoardMessage.textMax)
    let fields = String(data: d.dropFirst(5), encoding: .utf8)!.components(separatedBy: "\n")
    #expect(fields.count == 4 + 2 * 4)
    #expect(fields[0] == "3 4 1 4")
    #expect(fields[1].utf8.count <= 32 && fields[2].utf8.count <= 24)
    #expect(fields[3].utf8.count <= 120 && fields[3].hasSuffix("…"))
    #expect(fields[4].utf8.count <= 32 && fields[4].hasPrefix("Lựa chọn 1"))
    #expect(fields[5].hasPrefix("Mô tả"))     // descriptions keep a share of what is left
}

@Test func newlinesInFieldsBecomeSpaces() {
    let q = AskQuestion(question: "Line1\nLine2", header: "H\tX",
                        options: [AskOption(label: "A\nB", description: "d1\nd2")], multiSelect: false)
    #expect(text(.question(id: 1, index: 0, count: 1, project: "p\nq", question: q))
            == "0 1 0 1\np q\nH X\nLine1 Line2\nA B\nd1 d2")
}

@Test func encodesSessionRowAndRemoveAndClear() {
    let r = SessionRow(handle: 5, state: .working, since: 1_759_555_200, updated: 1_759_555_260,
                       focused: true, unseen: false, project: "dự-án", lastLine: "Done.")
    #expect(Array(BoardMessage.session(r).encode()) == [4, 5, 0, 0, 0] + Array("w 1759555200 1759555260 1\ndự-án\nDone.".utf8))
    var u = r
    u.focused = false; u.unseen = true; u.state = .needsYou
    #expect(text(.session(u)) == "n 1759555200 1759555260 2\ndự-án\nDone.")
    #expect(Array(BoardMessage.sessionRemove(handle: 5).encode()) == [5, 5, 0, 0, 0])
    #expect(Array(BoardMessage.sessionsClear.encode()) == [6, 0, 0, 0, 0])
}

@Test func sessionLineIsCutToFit() {
    let r = SessionRow(handle: 1, state: .idle, since: 1, updated: 2, focused: false, unseen: false,
                       project: "p", lastLine: String(repeating: "Xong rồi! ", count: 80))
    let d = BoardMessage.session(r).encode()
    #expect(d.count <= 5 + BoardMessage.textMax)
    #expect(String(data: d.dropFirst(5), encoding: .utf8)!.hasSuffix("…"))
}

@Test func permissionCarriesTheRuleLineAndKeepsItWhenTheSummaryIsCut() {
    #expect(text(.permission(id: 1, project: "p", tool: "Bash", summary: "npm test", alwaysRule: "Bash(npm test:*)"))
            == "p\nBash\nnpm test\nBash(npm test:*)")
    #expect(text(.permission(id: 1, project: "p", tool: "Bash", summary: "npm test")) == "p\nBash\nnpm test")
    let long = text(.permission(id: 1, project: "p", tool: "Bash", summary: String(repeating: "đường dẫn ", count: 60),
                                alwaysRule: "Bash(npm test:*)"))
    #expect(long.utf8.count <= BoardMessage.textMax)
    #expect(long.hasSuffix("…\nBash(npm test:*)"))
}

// MARK: Board → Mac

@Test func decodesBoardInputs() {
    #expect(BoardInput.decode(Data([0x04, 0x03, 0x02, 0x01, 1])) == .choice(id: 0x01020304, .allow))
    #expect(BoardInput.decode(Data([0x04, 0x03, 0x02, 0x01, 2])) == .choice(id: 0x01020304, .deny))
    #expect(BoardInput.decode(Data([0x04, 0x03, 0x02, 0x01, 3])) == .choice(id: 0x01020304, .alwaysAllow))
    #expect(BoardInput.decode(Data([0x04, 0x03, 0x02, 0x01, 0x10, 2, 0x02, 0x05])) == .answers(id: 0x01020304, masks: [0x02, 0x05]))
    #expect(BoardInput.decode(Data([0, 0, 0, 0, 0x20, 2])) == .mode(.picker))
    #expect(BoardInput.decode(Data([0, 0, 0, 0, 0x20, 0])) == .mode(.other))
    #expect(BoardInput.decode(Data([0, 0, 0, 0, 0x21, 7, 0, 0, 0])) == .focus(handle: 7))
}

@Test func rejectsMalformedBoardInputs() {
    let bad: [[UInt8]] = [
        [1, 2, 3],                               // short
        [0, 0, 0, 0, 1],                         // decision for id 0
        [1, 0, 0, 0, 9],                         // unknown code
        [1, 0, 0, 0, 1, 0],                      // decision with a trailing byte
        [1, 0, 0, 0, 0x10, 0],                   // zero questions
        [1, 0, 0, 0, 0x10, 5, 1, 1, 1, 1, 1],    // five questions
        [1, 0, 0, 0, 0x10, 2, 1],                // count says 2, one mask
        [0, 0, 0, 0, 0x20, 3],                   // unknown mode
        [0, 0, 0, 0, 0x21, 0, 0, 0, 0],          // focus handle 0
        [1, 0, 0, 0, 0x20, 1],                   // mode with a request id
    ]
    for b in bad { #expect(BoardInput.decode(Data(b)) == nil, "\(b)") }
}
```

In `mac/Tests/ClaudeBoardCoreTests/CoreTests.swift`, replace the test `longNonAsciiPermissionChunksFitAttMtu` with:

```swift
@Test func longNonAsciiPermissionIsCutToTheBoardLimitAndChunks() {
    let summary = String(repeating: "Đường dẫn tiếng Việt 🚀🧪 ", count: 40)
    let data = BoardMessage.permission(id: 0x01020304, project: "dự-án-🎯", tool: "Bash", summary: summary).encode()
    #expect(data.count <= 5 + BoardMessage.textMax)
    #expect(String(data: data.dropFirst(5), encoding: .utf8) != nil)   // never cut inside a character
    let chunks = BoardMessage.chunks(data, maxChunk: 20)              // default ATT MTU 23 - 3
    #expect(chunks.count > 1 && chunks.allSatisfy { $0.count <= 20 })
    #expect(reassemble(chunks) == data)
}
```

In `mac/Tests/ClaudeBoardCoreTests/RequestQueueTests.swift`, change `permissionIds()` and `tag(_:)` for the new cases:

```swift
    func permissionIds() -> [UInt32] { messages.compactMap { if case .permission(let id, _, _, _, _) = $0 { id } else { nil } } }
```

```swift
private func tag(_ m: BoardMessage) -> String {
    switch m {
    case .permission(let id, _, _, _, _): "perm\(id)"
    case .cancel(let id): "cancel\(id)"
    case .finished(let id, _, _): "fin\(id)"
    case .time: "time"
    case .session(let r): "row\(r.handle)"
    case .sessionRemove(let h): "rm\(h)"
    case .sessionsClear: "clear"
    case .question(let id, let index, _, _, _): "q\(id).\(index)"
    }
}
```

In `mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift`, change the `permissionIds` line of `FakeBoard` to:

```swift
    var permissionIds: [UInt32] { sent.compactMap { if case .permission(let id, _, _, _, _) = $0 { id } else { nil } } }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test 2>&1 | tail -20`
Expected: build errors — `Utf8`, `AskQuestion`, `SessionRow`, `BoardInput`, `BoardMessage.textMax` and the new cases do not exist.

- [ ] **Step 3: Byte budgets**

Create `mac/Sources/ClaudeBoardCore/Utf8.swift`:

```swift
import Foundation

/// Byte budgets for the board: its message text is at most 400 bytes of UTF-8 (firmware CLAUDE_TEXT_MAX).
public enum Utf8 {
    /// `s` if it fits; else the longest prefix of whole Characters plus "…" (3 bytes) within `maxBytes`;
    /// "" when not even the ellipsis fits.
    public static func fit(_ s: String, maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        guard maxBytes >= 3 else { return "" }
        var out = ""
        var used = 0
        for ch in s {
            let n = ch.utf8.count
            if used + n > maxBytes - 3 { break }
            out.append(ch)
            used += n
        }
        return out + "…"
    }

    /// Fits every item into a share of `totalBytes`: items shorter than an even share keep their full
    /// length, the others split what is left evenly.
    public static func share(_ items: [String], totalBytes: Int) -> [String] {
        var budget = [Int](repeating: 0, count: items.count)
        var left = max(0, totalBytes)
        var open = items.indices.sorted { items[$0].utf8.count < items[$1].utf8.count }
        while let i = open.first {
            let each = left / open.count
            let need = items[i].utf8.count
            if need <= each {
                budget[i] = need
                left -= need
                open.removeFirst()
            } else {
                for j in open { budget[j] = each }
                open.removeAll()
            }
        }
        return items.indices.map { fit(items[$0], maxBytes: budget[$0]) }
    }

    /// One line: control characters (newlines, tabs, …) and line/paragraph separators become spaces, since
    /// "\n" separates fields on the wire. Format characters such as ZWJ are kept.
    public static func oneLine(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let control = u.properties.generalCategory == .control || u == "\u{2028}" || u == "\u{2029}"
            out.append(control ? " " : u)
        }
        return String(out)
    }
}
```

- [ ] **Step 4: Questions, session rows and board inputs**

Create `mac/Sources/ClaudeBoardCore/AskQuestion.swift`:

```swift
import Foundation

public struct AskOption: Equatable, Sendable {
    public let label: String
    public let description: String
    public init(label: String, description: String) { self.label = label; self.description = description }
}

/// One AskUserQuestion question as the board shows it (one page each).
public struct AskQuestion: Equatable, Sendable {
    public let question: String
    public let header: String
    public let options: [AskOption]
    public let multiSelect: Bool

    public static let maxQuestions = 4
    public static let maxOptions = 4

    public init(question: String, header: String, options: [AskOption], multiSelect: Bool) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// The questions in an AskUserQuestion tool_input, or nil when the board cannot show them (then Claude
    /// asks in the terminal): no questions, more than 4 questions, 0 or more than 4 options, an empty label,
    /// or two questions with the same text (answers are keyed by the question text).
    public static func parse(_ input: [String: JSONValue]) -> [AskQuestion]? {
        guard let list = input["questions"]?.array, (1...maxQuestions).contains(list.count) else { return nil }
        var out: [AskQuestion] = []
        for item in list {
            guard let o = item.object, let question = o["question"]?.string,
                  let opts = o["options"]?.array, (1...maxOptions).contains(opts.count) else { return nil }
            var options: [AskOption] = []
            for opt in opts {
                guard let oo = opt.object, let label = oo["label"]?.string,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                options.append(AskOption(label: label, description: oo["description"]?.string ?? ""))
            }
            out.append(AskQuestion(question: question, header: o["header"]?.string ?? "", options: options,
                                   multiSelect: o["multiSelect"]?.bool ?? false))
        }
        guard Set(out.map(\.question)).count == out.count else { return nil }
        return out
    }
}
```

Create `mac/Sources/ClaudeBoardCore/Sessions.swift`:

```swift
import Foundation

/// Wire letters (firmware claude_proto.h): n needs you, w working, i idle, e ended
public enum SessionState: String, Sendable {
    case needsYou = "n", working = "w", idle = "i", ended = "e"
}

/// One picker row as the board receives it (message kind 4).
public struct SessionRow: Equatable, Sendable {
    public var handle: UInt32
    public var state: SessionState
    /// Unix seconds: when the current state began (elapsed time on the Claude screen)
    public var since: Int64
    /// Unix seconds: last hook event (picker order)
    public var updated: Int64
    public var focused: Bool
    /// A turn ended while another session was focused (badge)
    public var unseen: Bool
    public var project: String
    public var lastLine: String

    public init(handle: UInt32, state: SessionState, since: Int64, updated: Int64, focused: Bool, unseen: Bool,
                project: String, lastLine: String) {
        self.handle = handle
        self.state = state
        self.since = since
        self.updated = updated
        self.focused = focused
        self.unseen = unseen
        self.project = project
        self.lastLine = lastLine
    }

    /// Wire flags: bit0 focused, bit1 unseen
    public var flags: Int { (focused ? 1 : 0) | (unseen ? 2 : 0) }

    /// Picker order, identical on the board (sessions.c sessions_before): needs you first, then the most
    /// recently updated, then the higher handle.
    public static func boardOrder(_ a: SessionRow, _ b: SessionRow) -> Bool {
        let an = a.state == .needsYou, bn = b.state == .needsYou
        if an != bn { return an }
        if a.updated != b.updated { return a.updated > b.updated }
        return a.handle > b.handle
    }
}
```

Create `mac/Sources/ClaudeBoardCore/BoardInput.swift`:

```swift
import Foundation

public enum BoardChoice: UInt8, Sendable { case allow = 1, deny = 2, alwaysAllow = 3 }

/// What the board shows, as it reports it: session traffic flows only for .claude and .picker.
public enum BoardMode: UInt8, Sendable { case other = 0, claude = 1, picker = 2 }

/// Board → Mac on the answer characteristic. Request answers carry the request id (never 0); id 0 marks
/// board events.
///   [id u32 LE][1|2|3]                      allow / deny / always allow
///   [id u32 LE][0x10][n u8][mask × n]       question answers, bit i of mask q = option i of question q
///   [0 u32][0x20][mode u8]                  board mode
///   [0 u32][0x21][handle u32 LE]            focus this session
public enum BoardInput: Equatable, Sendable {
    case choice(id: UInt32, BoardChoice)
    case answers(id: UInt32, masks: [UInt8])
    case mode(BoardMode)
    case focus(handle: UInt32)

    public static func decode(_ d: Data) -> BoardInput? {
        let b = [UInt8](d)
        guard b.count >= 5 else { return nil }
        let id = le32(b, 0)
        switch (id == 0, b[4]) {
        case (false, 1...3):
            guard b.count == 5, let c = BoardChoice(rawValue: b[4]) else { return nil }
            return .choice(id: id, c)
        case (false, 0x10):
            guard b.count >= 6 else { return nil }
            let n = Int(b[5])
            guard (1...AskQuestion.maxQuestions).contains(n), b.count == 6 + n else { return nil }
            return .answers(id: id, masks: Array(b[6...]))
        case (true, 0x20):
            guard b.count == 6, let m = BoardMode(rawValue: b[5]) else { return nil }
            return .mode(m)
        case (true, 0x21):
            guard b.count == 9 else { return nil }
            let h = le32(b, 5)
            return h == 0 ? nil : .focus(handle: h)
        default:
            return nil
        }
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
```

- [ ] **Step 5: New message kinds with byte budgets**

In `mac/Sources/ClaudeBoardCore/BoardMessage.swift`, replace the whole `public enum BoardMessage: Equatable, Sendable { … }` up to (not including) `/// The time message for` … — i.e. the case list and `encode()` — with:

```swift
public enum BoardMessage: Equatable, Sendable {
    /// alwaysRule: caption of the rule "Always allow" would add; nil = the button is not offered
    case permission(id: UInt32, project: String, tool: String, summary: String, alwaysRule: String? = nil)
    case finished(id: UInt32, project: String, line: String)
    case cancel(id: UInt32)
    /// Wall clock for the board's lock face: Unix seconds and the local UTC offset in minutes
    case time(unixSeconds: Int64, offsetMinutes: Int)
    case session(SessionRow)
    case sessionRemove(handle: UInt32)
    case sessionsClear
    /// One AskUserQuestion page; all pages of a request share its id
    case question(id: UInt32, index: Int, count: Int, project: String, question: AskQuestion)

    /// Firmware CLAUDE_TEXT_MAX: the text after the 5-byte header never exceeds this many bytes
    public static let textMax = 400

    /// [kind u8][id u32 LE][UTF-8 text]. Kinds: 0 permission "project\ntool\nsummary[\nrule]", 1 finished
    /// "project\nline", 2 cancel, 3 time (id 0, "<unix seconds> <offset minutes>"), 4 session (id = handle,
    /// "<state> <since> <updated> <flags>\nproject\nline"), 5 session remove (id = handle), 6 sessions clear
    /// (id 0), 7 question page "<index> <count> <multi> <nopt>\nproject\nheader\nquestion\n(label\ndesc)×nopt".
    public func encode() -> Data {
        let (kind, id, text): (UInt8, UInt32, String) = switch self {
        case .permission(let id, let p, let t, let s, let rule): (0, id, Self.permissionText(p, t, s, rule))
        case .finished(let id, let p, let l): (1, id, Self.headAndRest([(p, 60)], rest: l))
        case .cancel(let id): (2, id, "")
        case .time(let seconds, let offset): (3, 0, "\(seconds) \(offset)")
        case .session(let r):
            (4, r.handle, Self.headAndRest([("\(r.state.rawValue) \(r.since) \(r.updated) \(r.flags)", 64), (r.project, 60)],
                                           rest: r.lastLine))
        case .sessionRemove(let h): (5, h, "")
        case .sessionsClear: (6, 0, "")
        case .question(let id, let index, let count, let project, let q): (7, id, Self.questionText(index, count, project, q))
        }
        var d = Data([kind, UInt8(id & 0xff), UInt8(id >> 8 & 0xff), UInt8(id >> 16 & 0xff), UInt8(id >> 24)])
        d.append(contentsOf: text.utf8)
        return d
    }

    private static func line(_ s: String, _ max: Int) -> String { Utf8.fit(Utf8.oneLine(s), maxBytes: max) }

    /// Capped fields, then one last field that gets every byte left (newlines included in the count).
    private static func headAndRest(_ head: [(String, Int)], rest: String) -> String {
        let fields = head.map { line($0.0, $0.1) }
        let used = fields.reduce(0) { $0 + $1.utf8.count } + fields.count
        return (fields + [line(rest, max(0, textMax - used))]).joined(separator: "\n")
    }

    private static func permissionText(_ p: String, _ t: String, _ s: String, _ rule: String?) -> String {
        var fields = [line(p, 60), line(t, 60)]
        let ruleLine = rule.map { line($0, 80) }
        let used = fields.reduce(0) { $0 + $1.utf8.count } + (ruleLine?.utf8.count ?? 0) + (ruleLine == nil ? 2 : 3)
        fields.append(line(s, max(0, textMax - used)))
        if let ruleLine { fields.append(ruleLine) }
        return fields.joined(separator: "\n")
    }

    private static func questionText(_ index: Int, _ count: Int, _ project: String, _ q: AskQuestion) -> String {
        let head = ["\(index) \(count) \(q.multiSelect ? 1 : 0) \(q.options.count)",
                    line(project, 32), line(q.header, 24), line(q.question, 120)]
        let labels = q.options.map { line($0.label, 32) }
        let newlines = head.count + 2 * labels.count - 1
        let used = (head + labels).reduce(0) { $0 + $1.utf8.count } + newlines
        let descs = Utf8.share(q.options.map { Utf8.oneLine($0.description) }, totalBytes: textMax - used)
        var fields = head
        for (l, d) in zip(labels, descs) { fields.append(l); fields.append(d) }
        return fields.joined(separator: "\n")
    }
```

(Keep `timeSync(at:in:)` and `chunks(_:maxChunk:)` and the closing brace of the enum as they are; keep `Decision` and `Answer` at the top of the file — `Answer` is removed in Task 5.)

- [ ] **Step 6: Run all Mac tests**

Run: `cd mac && swift test 2>&1 | tail -5`
Expected: all tests pass, including `encodesPermissionMessage` and `encodesCancel` from `CoreTests.swift` (short permission text is unchanged on the wire).

- [ ] **Step 7: Commit**

```bash
git add mac/Sources/ClaudeBoardCore/Utf8.swift mac/Sources/ClaudeBoardCore/AskQuestion.swift \
        mac/Sources/ClaudeBoardCore/Sessions.swift mac/Sources/ClaudeBoardCore/BoardInput.swift \
        mac/Sources/ClaudeBoardCore/BoardMessage.swift mac/Tests/ClaudeBoardCoreTests/ProtocolV2Tests.swift \
        mac/Tests/ClaudeBoardCoreTests/CoreTests.swift mac/Tests/ClaudeBoardCoreTests/RequestQueueTests.swift \
        mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift
git commit -F - <<'EOF'
mac: board protocol v2: session rows, question pages, board inputs, 400-byte budgets

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---
### Task 4: Mac — session tracker (pure)

**Files:**
- Create: `mac/Sources/ClaudeBoardCore/SessionTracker.swift`
- Test: `mac/Tests/ClaudeBoardCoreTests/SessionTrackerTests.swift`

**Interfaces:**
- Consumes: `HookEvent` (Task 2: `tmuxPane`), `SessionState`, `SessionRow`, `SessionRow.boardOrder` (Task 3), `Summary.project(cwd:)`, `Summary.lastLine(_:)`.
- Produces:
  - `enum TrackerEffect: Equatable { case none; case focusedDone(project: String, line: String) }`
  - `struct SessionTracker` with `init(sessionHooks: Bool)`, `@discardableResult mutating func record(_ e: HookEvent, now: Int64) -> TrackerEffect`, `mutating func requestAnswered(_ sessionId: String, now: Int64)`, `@discardableResult mutating func focus(handle: UInt32) -> Bool`, `mutating func markAllSeen()`, `mutating func expire(now: Int64)`, `func rows() -> [SessionRow]`, `func tmuxPane(sessionId: String) -> String?`, `var focusedId: String? { get }`; constants `visibleMax = 6`, `endedKeepSeconds = 600`, `idleEndSeconds = 7200`.
  - Test helper (module-internal, in the test target): `func hookEvent(_ name: String, sid: String = "s1", cwd: String = "/x/alpha", extra: String = "") -> HookEvent` (reused by Tasks 6 and 7).

Rules this task pins (spec + agreed UI):
- A session is created on its first event of any kind and the first session ever seen (or the first one after the focused one is dropped) becomes focused, so a single-session user never needs the picker.
- `since` changes only when the state changes; `updated` changes on every event. The Claude screen's elapsed time is the time in the current state ("Working · 12m"); a separate session start time is not needed by any screen and is not kept.
- PermissionRequest → needs you; `requestAnswered` (the board answered) → working; a request that fell through to the terminal leaves "needs you" until the next event. Notification `permission_prompt` / `elicitation_dialog` → needs you; `idle_prompt` → idle; other notification types only touch `updated`.
- Stop → idle + last line; for the focused session it yields `.focusedDone`, for any other it sets `unseen`. Focusing a session clears its `unseen`; `markAllSeen` clears all.
- `rows()` = at most 6 rows in board order; the focused session is always included (it replaces the last row if needed).
- Ended sessions are dropped 10 min after SessionEnd. Without session hooks, a session with no event for 2 h becomes ended (and is dropped 10 min later).

- [ ] **Step 1: Write the failing tests**

Create `mac/Tests/ClaudeBoardCoreTests/SessionTrackerTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeBoardCore

func hookEvent(_ name: String, sid: String = "s1", cwd: String = "/x/alpha", extra: String = "") -> HookEvent {
    try! HookEvent.parse(Data(#"{"hook_event_name":"\#(name)","session_id":"\#(sid)","cwd":"\#(cwd)"\#(extra)}"#.utf8))
}

@Test func createsOnFirstEventAndFocusesTheFirstSession() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit"), now: 100)
    t.record(hookEvent("UserPromptSubmit", sid: "s2", cwd: "/x/beta"), now: 110)
    let rows = t.rows()
    #expect(rows.map(\.project) == ["beta", "alpha"])          // most recent first
    #expect(rows.first { $0.project == "alpha" }?.focused == true)
    #expect(rows.first { $0.project == "beta" }?.focused == false)
    #expect(t.focusedId == "s1")
    #expect(rows.map(\.handle).sorted() == [1, 2])
}

@Test func statesFollowTheHooks() {
    var t = SessionTracker(sessionHooks: true)
    func state() -> SessionState? { t.rows().first?.state }
    t.record(hookEvent("SessionStart"), now: 1);                                         #expect(state() == .idle)
    t.record(hookEvent("UserPromptSubmit"), now: 2);                                     #expect(state() == .working)
    t.record(hookEvent("PermissionRequest", extra: #","tool_name":"Bash""#), now: 3);   #expect(state() == .needsYou)
    t.requestAnswered("s1", now: 4);                                                     #expect(state() == .working)
    t.record(hookEvent("Notification", extra: #","notification_type":"permission_prompt""#), now: 5)
    #expect(state() == .needsYou)
    t.record(hookEvent("Notification", extra: #","notification_type":"auth_success""#), now: 6)
    #expect(state() == .needsYou)
    t.record(hookEvent("Notification", extra: #","notification_type":"idle_prompt""#), now: 7)
    #expect(state() == .idle)
    t.record(hookEvent("Stop", extra: #","last_assistant_message":"All tests pass.\nDone 🎉""#), now: 8)
    #expect(state() == .idle && t.rows().first?.lastLine == "Done 🎉")
    t.record(hookEvent("SessionEnd"), now: 9);                                           #expect(state() == .ended)
    t.record(hookEvent("UserPromptSubmit"), now: 10);                                    #expect(state() == .working)  // resumed
}

@Test func requestAnsweredOnlyLeavesNeedsYou() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("Stop"), now: 1)
    t.requestAnswered("s1", now: 2)
    #expect(t.rows().first?.state == .idle)
    t.requestAnswered("unknown", now: 3)
    #expect(t.rows().count == 1)
}

@Test func sinceChangesOnlyWithTheState() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit"), now: 100)
    t.record(hookEvent("UserPromptSubmit"), now: 150)
    #expect(t.rows()[0].since == 100 && t.rows()[0].updated == 150)
    t.record(hookEvent("Stop"), now: 200)
    #expect(t.rows()[0].since == 200)
}

@Test func stopOfTheFocusedSessionIsDoneOthersBecomeUnseen() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit"), now: 1)                                // s1 focused
    t.record(hookEvent("UserPromptSubmit", sid: "s2", cwd: "/x/beta"), now: 2)
    // (mutating calls cannot sit inside #expect: take the result first)
    let focusedDone = t.record(hookEvent("Stop", extra: #","last_assistant_message":"ok""#), now: 3)
    #expect(focusedDone == .focusedDone(project: "alpha", line: "ok"))
    let otherDone = t.record(hookEvent("Stop", sid: "s2", cwd: "/x/beta"), now: 4)
    #expect(otherDone == .none)
    #expect(t.rows().first { $0.project == "beta" }?.unseen == true)
    let beta = t.rows().first { $0.project == "beta" }!.handle
    let focused = t.focus(handle: beta)
    #expect(focused)
    #expect(t.rows().first { $0.project == "beta" }?.unseen == false)
    #expect(t.rows().first { $0.project == "beta" }?.focused == true)
    let unknown = t.focus(handle: 999)
    #expect(!unknown)
}

@Test func markAllSeenClearsEveryBadge() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit"), now: 1)
    t.record(hookEvent("Stop", sid: "s2"), now: 2)
    t.record(hookEvent("Stop", sid: "s3"), now: 3)
    #expect(t.rows().filter(\.unseen).count == 2)
    t.markAllSeen()
    #expect(t.rows().filter(\.unseen).isEmpty)
}

@Test func rowsPutNeedsYouFirstAndKeepTheFocusedOneWithinSix() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit", sid: "old", cwd: "/x/old"), now: 1)     // focused, oldest
    for i in 0..<7 { t.record(hookEvent("UserPromptSubmit", sid: "s\(i)", cwd: "/x/p\(i)"), now: 10 + Int64(i)) }
    t.record(hookEvent("PermissionRequest", sid: "s0", cwd: "/x/p0"), now: 20)
    let rows = t.rows()
    #expect(rows.count == SessionTracker.visibleMax)
    #expect(rows[0].project == "p0" && rows[0].state == .needsYou)
    #expect(rows.contains { $0.project == "old" && $0.focused })
    #expect(rows.filter { !$0.focused && $0.state != .needsYou }.map(\.updated) == [16, 15, 14, 13])
}

@Test func endedSessionsAreDroppedAfterTenMinutes() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("SessionEnd"), now: 1000)
    t.expire(now: 1000 + 599)
    #expect(t.rows().count == 1)
    t.expire(now: 1000 + 600)
    #expect(t.rows().isEmpty && t.focusedId == nil)
}

@Test func idleFallbackEndsSilentSessionsOnlyWithoutSessionHooks() {
    var with = SessionTracker(sessionHooks: true)
    with.record(hookEvent("Stop"), now: 0)
    with.expire(now: 3 * 3600)
    #expect(with.rows().first?.state == .idle)

    var without = SessionTracker(sessionHooks: false)
    without.record(hookEvent("Stop"), now: 0)
    without.expire(now: 7199)
    #expect(without.rows().first?.state == .idle)
    without.expire(now: 7200)
    #expect(without.rows().first?.state == .ended && without.rows().first?.since == 7200)
    without.expire(now: 7200 + 600)
    #expect(without.rows().isEmpty)
}

@Test func keepsTheTmuxPaneAndIgnoresEventsWithoutSession() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit", extra: #","claude_board_tmux_pane":"%4""#), now: 1)
    t.record(hookEvent("Stop"), now: 2)                       // no pane in this event: keep the old one
    #expect(t.tmuxPane(sessionId: "s1") == "%4")
    t.record(hookEvent("Stop", sid: ""), now: 3)
    #expect(t.rows().count == 1)
}

@Test func handlesSkipZero() {
    var t = SessionTracker(sessionHooks: true)
    t.nextHandle = .max
    t.record(hookEvent("Stop", sid: "a"), now: 1)
    t.record(hookEvent("Stop", sid: "b"), now: 2)
    #expect(Set(t.rows().map(\.handle)) == [UInt32.max, 1])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test 2>&1 | tail -20`
Expected: build error — `SessionTracker` is not defined.

- [ ] **Step 3: Implement the tracker**

Create `mac/Sources/ClaudeBoardCore/SessionTracker.swift`:

```swift
import Foundation

public enum TrackerEffect: Equatable, Sendable {
    case none
    /// The focused session finished a turn: chime + last line on the board, in any board mode
    case focusedDone(project: String, line: String)
}

/// Claude Code sessions as seen through hooks. Pure: the caller passes the time (Unix seconds).
public struct SessionTracker: Sendable {
    public static let visibleMax = 6
    public static let endedKeepSeconds: Int64 = 10 * 60
    public static let idleEndSeconds: Int64 = 2 * 60 * 60

    struct Session: Equatable, Sendable {
        let handle: UInt32
        var project: String
        var state: SessionState
        var since: Int64
        var updated: Int64
        var lastLine: String
        var tmuxPane: String?
        var unseen: Bool
    }

    /// SessionStart / SessionEnd hooks are installed (hook spike). Without them a session ends after 2 h
    /// without events.
    public let sessionHooks: Bool
    private(set) var sessions: [String: Session] = [:]
    public private(set) var focusedId: String?
    var nextHandle: UInt32 = 1

    public init(sessionHooks: Bool) { self.sessionHooks = sessionHooks }

    @discardableResult
    public mutating func record(_ e: HookEvent, now: Int64) -> TrackerEffect {
        guard !e.sessionId.isEmpty else { return .none }
        var s = sessions[e.sessionId] ?? newSession(now: now)
        if !e.cwd.isEmpty { s.project = Summary.project(cwd: e.cwd) }
        if let pane = e.tmuxPane, !pane.isEmpty { s.tmuxPane = pane }
        s.updated = now
        if focusedId.map({ sessions[$0] == nil }) ?? true { focusedId = e.sessionId }
        var effect = TrackerEffect.none
        switch e.name {
        case "SessionStart":
            Self.set(&s, .idle, now)
        case "UserPromptSubmit":
            Self.set(&s, .working, now)
        case "PermissionRequest":
            Self.set(&s, .needsYou, now)
        case "Notification":
            switch e.notificationType {
            case "permission_prompt", "elicitation_dialog": Self.set(&s, .needsYou, now)
            case "idle_prompt": Self.set(&s, .idle, now)
            default: break
            }
        case "Stop":
            Self.set(&s, .idle, now)
            s.lastLine = Summary.lastLine(e)
            if focusedId == e.sessionId {
                effect = .focusedDone(project: s.project, line: s.lastLine)
            } else {
                s.unseen = true
            }
        case "SessionEnd":
            Self.set(&s, .ended, now)
        default:
            break
        }
        sessions[e.sessionId] = s
        return effect
    }

    /// The board answered this session's request: Claude continues.
    public mutating func requestAnswered(_ sessionId: String, now: Int64) {
        guard var s = sessions[sessionId], s.state == .needsYou else { return }
        Self.set(&s, .working, now)
        s.updated = now
        sessions[sessionId] = s
    }

    @discardableResult
    public mutating func focus(handle: UInt32) -> Bool {
        guard let id = sessions.first(where: { $0.value.handle == handle })?.key else { return false }
        focusedId = id
        sessions[id]?.unseen = false
        return true
    }

    public mutating func markAllSeen() {
        for id in sessions.keys { sessions[id]?.unseen = false }
    }

    public mutating func expire(now: Int64) {
        for (id, s) in sessions {
            if s.state == .ended {
                if now - s.since >= Self.endedKeepSeconds { sessions[id] = nil }
            } else if !sessionHooks && now - s.updated >= Self.idleEndSeconds {
                var ended = s
                Self.set(&ended, .ended, now)
                sessions[id] = ended
            }
        }
        if let f = focusedId, sessions[f] == nil { focusedId = nil }
    }

    /// At most `visibleMax` rows in board order; the focused session is always one of them.
    public func rows() -> [SessionRow] {
        let all = sessions.map { id, s in
            SessionRow(handle: s.handle, state: s.state, since: s.since, updated: s.updated,
                       focused: id == focusedId, unseen: s.unseen && id != focusedId,
                       project: s.project, lastLine: s.lastLine)
        }.sorted(by: SessionRow.boardOrder)
        var top = Array(all.prefix(Self.visibleMax))
        if let f = all.first(where: \.focused), !top.contains(f), !top.isEmpty {
            top[top.count - 1] = f
            top.sort(by: SessionRow.boardOrder)
        }
        return top
    }

    public func tmuxPane(sessionId: String) -> String? { sessions[sessionId]?.tmuxPane }

    private mutating func newSession(now: Int64) -> Session {
        let handle = nextHandle
        nextHandle = nextHandle == .max ? 1 : nextHandle + 1   // handles are never 0
        return Session(handle: handle, project: "Claude", state: .idle, since: now, updated: now,
                       lastLine: "", tmuxPane: nil, unseen: false)
    }

    private static func set(_ s: inout Session, _ state: SessionState, _ now: Int64) {
        if s.state != state {
            s.state = state
            s.since = now
        }
    }
}
```

- [ ] **Step 4: Run all Mac tests**

Run: `cd mac && swift test 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/ClaudeBoardCore/SessionTracker.swift mac/Tests/ClaudeBoardCoreTests/SessionTrackerTests.swift
git commit -F - <<'EOF'
mac: session tracker (states, focus, unseen badge, expiry, picker order)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 5: Mac — request queue for permissions and questions; board inputs end to end

**Files:**
- Modify: `mac/Sources/ClaudeBoardCore/RequestQueue.swift` (whole file)
- Modify: `mac/Sources/ClaudeBoardCore/BoardMessage.swift` (remove `Answer`)
- Modify: `mac/Sources/ClaudeBoardCore/HookProcessor.swift:38-48` (permission case)
- Modify: `mac/Sources/claude-board/BoardLink.swift` (`onAnswer` → `onInput`), `mac/Sources/claude-board/main.swift:10`
- Modify: `mac/Tests/ClaudeBoardCoreTests/RequestQueueTests.swift`, `mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift`, `mac/Tests/ClaudeBoardCoreTests/CoreTests.swift` (drop `decodesAnswer`)

**Interfaces:**
- Consumes: `BoardInput`, `BoardChoice`, `BoardMessage.question` (Task 3).
- Produces:
  - `enum BoardResponse: Equatable, Sendable { case allow, deny, alwaysAllow, answers([UInt8]) }`
  - `enum RequestShape: Equatable, Sendable { case permission(alwaysOffered: Bool); case question(options: [Int], multi: [Bool]); func accept(_ input: BoardInput) -> BoardResponse? }`
  - `RequestQueue.ask(shape: RequestShape, messages build: @Sendable (UInt32) -> [BoardMessage]) async -> BoardResponse?` (all messages of the head request are sent back to back; the rest wait), `ask(project:tool:summary:) async -> BoardResponse?` (permission without Always allow), `handle(_ input: BoardInput)`, `post(_ m: BoardMessage)` (non-request traffic on the same FIFO), `notifyFinished(project:line:)`, `boardDisconnected()`.
  - `BoardLink.onInput: (@Sendable (BoardInput) -> Void)?`

- [ ] **Step 1: Write the failing tests**

Replace `mac/Tests/ClaudeBoardCoreTests/RequestQueueTests.swift` with (the `tag` helper keeps the Task 3 cases):

```swift
import Foundation
import Testing
@testable import ClaudeBoardCore

actor Sent {
    var messages: [BoardMessage] = []
    func add(_ m: BoardMessage) { messages.append(m) }
    func permissionIds() -> [UInt32] { messages.compactMap { if case .permission(let id, _, _, _, _) = $0 { id } else { nil } } }
    func questionIds() -> [UInt32] { messages.compactMap { if case .question(let id, _, _, _, _) = $0 { id } else { nil } } }
}

private let color = AskQuestion(question: "Which color?", header: "Color",
                                options: [AskOption(label: "Red", description: ""), AskOption(label: "Green", description: "")],
                                multiSelect: false)
private let fruits = AskQuestion(question: "Which fruits?", header: "Fruits",
                                 options: ["Apple", "Banana", "Cherry"].map { AskOption(label: $0, description: "") },
                                 multiSelect: true)
private let questionShape = RequestShape.question(options: [2, 3], multi: [false, true])

private func askQuestions(_ q: RequestQueue) async -> BoardResponse? {
    await q.ask(shape: questionShape) { id in
        [.question(id: id, index: 0, count: 2, project: "p", question: color),
         .question(id: id, index: 1, count: 2, project: "p", question: fruits)]
    }
}

@Test func answersTheWaitingHook() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let d = q.ask(project: "p", tool: "Bash", summary: "ls")
    try? await Task.sleep(for: .milliseconds(50))
    let id = await sent.permissionIds()[0]
    await q.handle(.choice(id: id, .allow))
    #expect(await d == .allow)
}

@Test func queuesSecondRequestUntilFirstAnswered() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let a = q.ask(project: "p", tool: "Bash", summary: "one")
    try? await Task.sleep(for: .milliseconds(30))
    async let b = q.ask(project: "p", tool: "Bash", summary: "two")
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await sent.permissionIds().count == 1)
    let first = await sent.permissionIds()[0]
    await q.handle(.choice(id: first, .deny))
    try? await Task.sleep(for: .milliseconds(30))
    let ids = await sent.permissionIds()
    #expect(ids.count == 2)
    await q.handle(.choice(id: ids[1], .allow))
    #expect(await a == .deny)
    #expect(await b == .allow)
}

@Test func answerForQueuedRequestIsIgnored() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) }, timeout: .milliseconds(300))
    async let a = q.ask(project: "p", tool: "Bash", summary: "one")
    try? await Task.sleep(for: .milliseconds(30))
    async let b = askQuestions(q)
    try? await Task.sleep(for: .milliseconds(30))
    let first = await sent.permissionIds()[0]
    // The queued question's id is first + 1; it is not on the board yet, so its answer must not count
    await q.handle(.answers(id: first &+ 1, masks: [1, 1]))
    await q.handle(.choice(id: first, .allow))
    #expect(await a == .allow)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await sent.questionIds() == [first &+ 1, first &+ 1])
    #expect(await b == nil)     // timed out: the early answer was not kept
}

@Test func questionRoundTripSendsEveryPageThenTakesTheMasks() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let r = askQuestions(q)
    try? await Task.sleep(for: .milliseconds(50))
    let ids = await sent.questionIds()
    #expect(ids.count == 2 && ids[0] == ids[1])
    await q.handle(.answers(id: ids[0], masks: [0b10, 0b101]))
    #expect(await r == .answers([0b10, 0b101]))
}

@Test func answersMustFitTheQuestionShape() {
    let bad: [[UInt8]] = [[0b10], [0b10, 0b101, 1], [0, 0b1], [0b11, 0b1], [0b100, 0b1], [0b1, 0b1000]]
    for m in bad { #expect(questionShape.accept(.answers(id: 1, masks: m)) == nil, "\(m)") }
    #expect(questionShape.accept(.answers(id: 1, masks: [0b01, 0b111])) == .answers([0b01, 0b111]))
    #expect(questionShape.accept(.choice(id: 1, .allow)) == nil)
    #expect(RequestShape.permission(alwaysOffered: false).accept(.answers(id: 1, masks: [1])) == nil)
}

@Test func alwaysAllowOnlyWhenOffered() {
    #expect(RequestShape.permission(alwaysOffered: false).accept(.choice(id: 1, .alwaysAllow)) == nil)
    #expect(RequestShape.permission(alwaysOffered: true).accept(.choice(id: 1, .alwaysAllow)) == .alwaysAllow)
    #expect(RequestShape.permission(alwaysOffered: false).accept(.choice(id: 1, .deny)) == .deny)
}

@Test func ignoresAnswerForUnknownId() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) }, timeout: .milliseconds(200))
    async let d = q.ask(project: "p", tool: "Bash", summary: "ls")
    try? await Task.sleep(for: .milliseconds(30))
    await q.handle(.choice(id: 999_999, .allow))
    #expect(await d == nil)        // timed out, never approved by a stray answer
}

@Test func timeoutFallsThroughAndCancelsOnBoard() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) }, timeout: .milliseconds(100))
    #expect(await q.ask(project: "p", tool: "Bash", summary: "ls") == nil)
    try? await Task.sleep(for: .milliseconds(30))
    let msgs = await sent.messages
    #expect(msgs.contains { if case .cancel = $0 { true } else { false } })
}

@Test func cancelsWhenHookDisconnects() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    let t = Task { await q.ask(project: "p", tool: "Bash", summary: "ls") }
    try? await Task.sleep(for: .milliseconds(30))
    t.cancel()
    #expect(await t.value == nil)
    try? await Task.sleep(for: .milliseconds(30))
    let msgs = await sent.messages
    #expect(msgs.contains { if case .cancel = $0 { true } else { false } })
}

@Test func boardDisconnectReleasesWaiters() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let d = q.ask(project: "p", tool: "Bash", summary: "ls")
    try? await Task.sleep(for: .milliseconds(30))
    await q.boardDisconnected()
    #expect(await d == nil)
}

@Test func postGoesThroughTheSameFifo() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    await q.post(.sessionsClear)
    await q.post(.sessionRemove(handle: 3))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await sent.messages == [.sessionsClear, .sessionRemove(handle: 3)])
}

private func tag(_ m: BoardMessage) -> String {
    switch m {
    case .permission(let id, _, _, _, _): "perm\(id)"
    case .cancel(let id): "cancel\(id)"
    case .finished(let id, _, _): "fin\(id)"
    case .time: "time"
    case .session(let r): "row\(r.handle)"
    case .sessionRemove(let h): "rm\(h)"
    case .sessionsClear: "clear"
    case .question(let id, let index, _, _, _): "q\(id).\(index)"
    }
}

@Test func cancelOfHeadIsSentBeforeNextPermission() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    let a = Task { await q.ask(project: "p", tool: "Bash", summary: "one") }
    try? await Task.sleep(for: .milliseconds(30))
    async let b = q.ask(project: "p", tool: "Bash", summary: "two")
    try? await Task.sleep(for: .milliseconds(30))
    a.cancel()
    try? await Task.sleep(for: .milliseconds(50))
    let msgs = await sent.messages
    let ids = await sent.permissionIds()
    #expect(ids.count == 2)
    #expect(msgs.map(tag) == ["perm\(ids[0])", "cancel\(ids[0])", "perm\(ids[1])"])
    await q.handle(.choice(id: ids[1], .allow))
    #expect(await b == .allow)
}

@Test func idsNeverZeroAcrossWrap() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    await q.seedNextId(UInt32.max)
    await q.notifyFinished(project: "p", line: "a")   // uses max
    await q.notifyFinished(project: "p", line: "b")   // must skip 0
    try? await Task.sleep(for: .milliseconds(30))
    let ids = await sent.messages.map(tag)
    #expect(ids == ["fin\(UInt32.max)", "fin1"])
}
```

In `mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift`, replace the two places that build an `Answer`:

```swift
@Test(arguments: [BoardChoice.allow, BoardChoice.deny])
func permissionRoundTrip(_ choice: BoardChoice) async {
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(permissionLine, conn) }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(board.sent == [.permission(id: board.permissionIds[0], project: "dự-án", tool: "Bash", summary: "npm test")])
    #expect(conn.replies.isEmpty)
    await p.requests.handle(.choice(id: board.permissionIds[0], choice))
    await done.value
    #expect(conn.replies == [BridgeReply(decision: choice == .allow ? "allow" : "deny")])
}
```

and in `hookDisconnectCancelsBoardRequest` replace `await p.requests.handle(Answer(id: id, decision: .allow))` with `await p.requests.handle(.choice(id: id, .allow))`.

In `mac/Tests/ClaudeBoardCoreTests/CoreTests.swift`, delete the test `decodesAnswer` (its bytes are covered by `decodesBoardInputs`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test 2>&1 | tail -20`
Expected: build errors — `RequestShape`, `BoardResponse`, `ask(shape:messages:)`, `post`, `handle(BoardInput)` do not exist.

- [ ] **Step 3: Implement the queue**

Replace `mac/Sources/ClaudeBoardCore/RequestQueue.swift` with:

```swift
import Foundation

/// What the board answered for the request it showed.
public enum BoardResponse: Equatable, Sendable {
    case allow, deny, alwaysAllow
    /// One bitmask per question: bit i = option i chosen
    case answers([UInt8])
}

/// The answers a request accepts.
public enum RequestShape: Equatable, Sendable {
    case permission(alwaysOffered: Bool)
    /// options[q] = option count of question q; multi[q] = several options may be chosen
    case question(options: [Int], multi: [Bool])

    /// The response a board input stands for, or nil when it does not fit this request.
    public func accept(_ input: BoardInput) -> BoardResponse? {
        switch (self, input) {
        case (.permission(let always), .choice(_, let c)):
            switch c {
            case .allow: return .allow
            case .deny: return .deny
            case .alwaysAllow: return always ? .alwaysAllow : nil
            }
        case (.question(let options, let multi), .answers(_, let masks)):
            guard masks.count == options.count else { return nil }
            for (i, m) in masks.enumerated() {
                let valid = UInt8((1 << options[i]) - 1)
                guard m != 0, m & ~valid == 0, multi[i] || m.nonzeroBitCount == 1 else { return nil }
            }
            return .answers(masks)
        default:
            return nil
        }
    }
}

public actor RequestQueue {
    private struct Pending {
        let id: UInt32
        let messages: [BoardMessage]
        let shape: RequestShape
        var continuation: CheckedContinuation<BoardResponse?, Never>?
    }

    private let outbox: AsyncStream<BoardMessage>.Continuation   // single FIFO so board traffic never reorders
    private let timeout: Duration
    private var queue: [Pending] = []          // queue[0] is on the board
    private var nextId = UInt32.random(in: 1 ... 0x7fff_ffff)

    public init(send: @escaping @Sendable (BoardMessage) async -> Void, timeout: Duration = .seconds(90)) {
        let (stream, continuation) = AsyncStream<BoardMessage>.makeStream()
        self.outbox = continuation
        self.timeout = timeout
        Task {
            for await message in stream { await send(message) }
        }
    }

    deinit { outbox.finish() }

    /// Ids are never 0: the board uses 0 as "no pending request" and for its own events.
    private func allocateId() -> UInt32 {
        if nextId == 0 { nextId = 1 }
        let id = nextId
        nextId &+= 1
        return id
    }

    func seedNextId(_ value: UInt32) { nextId = value }

    /// Shows a request on the board (when it reaches the head of the queue) and waits for its answer.
    /// nil = timeout, cancellation (the hook went away) or the board disconnected: never a decision.
    public func ask(shape: RequestShape, messages build: @Sendable (UInt32) -> [BoardMessage]) async -> BoardResponse? {
        let id = allocateId()
        let messages = build(id)
        let timer = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await self.finish(id, with: nil, cancelOnBoard: true) }
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                queue.append(Pending(id: id, messages: messages, shape: shape, continuation: c))
                if queue.count == 1 { show(messages) }
            }
        } onCancel: {
            Task { await self.finish(id, with: nil, cancelOnBoard: true) }
        }
    }

    /// A permission request without "Always allow".
    public func ask(project: String, tool: String, summary: String) async -> BoardResponse? {
        await ask(shape: .permission(alwaysOffered: false)) { id in
            [.permission(id: id, project: project, tool: tool, summary: summary)]
        }
    }

    /// Only the request shown on the board can be answered, and only with an answer of its shape.
    public func handle(_ input: BoardInput) {
        let id: UInt32
        switch input {
        case .choice(let i, _), .answers(let i, _): id = i
        case .mode, .focus: return
        }
        guard let head = queue.first, head.id == id, let response = head.shape.accept(input) else { return }
        finish(id, with: response, cancelOnBoard: false)
    }

    /// Non-request traffic (session rows): same FIFO, so it never overtakes a request or a cancel.
    public func post(_ message: BoardMessage) {
        outbox.yield(message)
    }

    public func boardDisconnected() {
        let all = queue
        queue.removeAll()
        for p in all { p.continuation?.resume(returning: nil) }
    }

    public func notifyFinished(project: String, line: String) async {
        outbox.yield(.finished(id: allocateId(), project: project, line: line))
    }

    private func show(_ messages: [BoardMessage]) {
        for m in messages { outbox.yield(m) }
    }

    private func finish(_ id: UInt32, with response: BoardResponse?, cancelOnBoard: Bool) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let wasShown = index == 0
        let p = queue.remove(at: index)
        p.continuation?.resume(returning: response)
        if wasShown {
            if cancelOnBoard { outbox.yield(.cancel(id: id)) }
            if let next = queue.first { show(next.messages) }
        }
    }
}
```

In `mac/Sources/ClaudeBoardCore/BoardMessage.swift`, delete the whole `public struct Answer … { … }` (keep `Decision`, still used by `HookOutput.json(for:)`).

- [ ] **Step 4: Keep the processor and the daemon building**

In `mac/Sources/ClaudeBoardCore/HookProcessor.swift`, replace the two lines

```swift
            log("\(project) \(e.toolName ?? "") → \(d.map { $0 == .allow ? "allow" : "deny" } ?? "fall through")")
            conn.reply(BridgeReply(decision: d.map { $0 == .allow ? "allow" : "deny" }))
```

with

```swift
            let decision: String? = switch d {
            case .allow?: "allow"
            case .deny?: "deny"
            default: nil
            }
            log("\(project) \(e.toolName ?? "") → \(decision ?? "fall through")")
            conn.reply(BridgeReply(decision: decision))
```

In `mac/Sources/claude-board/BoardLink.swift`, replace `var onAnswer: (@Sendable (Answer) -> Void)?` with

```swift
    var onInput: (@Sendable (BoardInput) -> Void)?
```

and replace the body line of `didUpdateValueFor` with

```swift
        if c.uuid == Self.answerChar, let v = c.value, let input = BoardInput.decode(v) { onInput?(input) }
```

In `mac/Sources/claude-board/main.swift`, replace `board.onAnswer = { a in Task { await requests.handle(a) } }` with

```swift
board.onInput = { input in Task { await requests.handle(input) } }
```

- [ ] **Step 5: Run all Mac tests and build the release binaries**

Run: `cd mac && swift test 2>&1 | tail -5 && swift build -c release 2>&1 | tail -2`
Expected: all tests pass; `Build complete!`.

- [ ] **Step 6: Commit**

```bash
git add mac/Sources/ClaudeBoardCore/RequestQueue.swift mac/Sources/ClaudeBoardCore/BoardMessage.swift \
        mac/Sources/ClaudeBoardCore/HookProcessor.swift mac/Sources/claude-board/BoardLink.swift \
        mac/Sources/claude-board/main.swift mac/Tests/ClaudeBoardCoreTests/RequestQueueTests.swift \
        mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift mac/Tests/ClaudeBoardCoreTests/CoreTests.swift
git commit -F - <<'EOF'
mac: request queue answers permissions and multi-page questions by shape

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---
### Task 6: Mac — answer mapping; the processor shows questions and offers Always allow

**Files:**
- Create: `mac/Sources/ClaudeBoardCore/AnswerMapping.swift`
- Modify: `mac/Sources/ClaudeBoardCore/HookProcessor.swift` (whole file)
- Test: `mac/Tests/ClaudeBoardCoreTests/AnswerMappingTests.swift`, `mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift`

**Interfaces:**
- Consumes: `HookSchema`, `AlwaysAllowStyle`, `QuestionAnswerStyle`, `BridgeReply` (Task 2); `AskQuestion`, `BoardMessage.question`, `BoardMessage.permission(…alwaysRule:)` (Task 3); `RequestQueue.ask(shape:messages:)`, `RequestShape`, `BoardResponse` (Task 5).
- Produces:
  - `enum AnswerMapping` with `static func alwaysRule(suggestions: JSONValue?, style: AlwaysAllowStyle = HookSchema.alwaysAllow) -> String?`, `static func permissionReply(_ r: BoardResponse, suggestions: JSONValue?, style: AlwaysAllowStyle = HookSchema.alwaysAllow) -> BridgeReply`, `static func chosenLabels(_ masks: [UInt8], _ questions: [AskQuestion]) -> [[String]]`, `static func boardAnswerText(_ masks: [UInt8], questions: [AskQuestion]) -> String`, `static func questionReply(_ masks: [UInt8], questions: [AskQuestion], toolInput: [String: JSONValue], style: QuestionAnswerStyle = HookSchema.questionAnswers) -> BridgeReply`.
  - `HookProcessor.process` handles `PermissionRequest` for `AskUserQuestion` (question pages) and other tools (permission, with the rule line when Always allow is usable).

Both answer paths are implemented and tested; `HookSchema.questionAnswers` (set from the spike in Task 2) picks one at run time. `.terminalOnly` makes the processor reply `null` at once for AskUserQuestion (Claude asks in the terminal); `alwaysAllow == .unsupported` means no rule line is ever sent, so the board never shows the button.

- [ ] **Step 1: Write the failing tests**

Create `mac/Tests/ClaudeBoardCoreTests/AnswerMappingTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeBoardCore

private let qs = [
    AskQuestion(question: "Which color?", header: "Color",
                options: ["Red", "Green", "Blue"].map { AskOption(label: $0, description: "") }, multiSelect: false),
    AskQuestion(question: "Which fruits?", header: "Fruits",
                options: ["Apple", "Banana", "Cherry"].map { AskOption(label: $0, description: "") }, multiSelect: true),
]
private let input: [String: JSONValue] = ["questions": .array([.string("kept as sent")])]
private let docsSuggestion = JSONValue.array([.object(["rule": .string("Bash(git push *)"),
                                                       "description": .string("Allow git push"),
                                                       "specificity": .string("moderate")])])
private let sdkSuggestion = JSONValue.array([.object(["type": .string("addRules"),
                                                      "rules": .array([.object(["toolName": .string("Bash"),
                                                                                "ruleContent": .string("npm test:*")])]),
                                                      "behavior": .string("allow"),
                                                      "destination": .string("localSettings")])])

@Test func chosenLabelsFollowTheMasks() {
    #expect(AnswerMapping.chosenLabels([0b010, 0b101], qs) == [["Green"], ["Apple", "Cherry"]])
}

@Test func joinedAnswersGoInUpdatedInput() {
    let r = AnswerMapping.questionReply([0b010, 0b101], questions: qs, toolInput: input, style: .updatedInputJoined)
    #expect(r.decision == "allow" && r.message == nil && r.updatedPermissions == nil)
    #expect(r.updatedInput == .object([
        "questions": .array([.string("kept as sent")]),
        "answers": .object(["Which color?": .string("Green"), "Which fruits?": .string("Apple, Cherry")]),
    ]))
}

@Test func arrayAnswersGoInUpdatedInput() {
    let r = AnswerMapping.questionReply([0b001, 0b010], questions: qs, toolInput: input, style: .updatedInputArrays)
    #expect(r.updatedInput?.object?["answers"] == .object(["Which color?": .array([.string("Red")]),
                                                           "Which fruits?": .array([.string("Banana")])]))
}

@Test func denyWithReasonCarriesTheSpecText() {
    let r = AnswerMapping.questionReply([0b010, 0b101], questions: qs, toolInput: input, style: .denyWithReason)
    #expect(r == BridgeReply(decision: "deny",
                             message: "The user answered on the board: Which color? → Green; Which fruits? → Apple, Cherry"))
}

@Test func alwaysRuleReadsBothSuggestionShapes() {
    #expect(AnswerMapping.alwaysRule(suggestions: docsSuggestion, style: .suggestionsVerbatim) == "Bash(git push *)")
    #expect(AnswerMapping.alwaysRule(suggestions: sdkSuggestion, style: .ruleRemember) == "Bash(npm test:*)")
    #expect(AnswerMapping.alwaysRule(suggestions: docsSuggestion, style: .unsupported) == nil)
    #expect(AnswerMapping.alwaysRule(suggestions: nil, style: .suggestionsVerbatim) == nil)
    #expect(AnswerMapping.alwaysRule(suggestions: .array([]), style: .suggestionsVerbatim) == nil)
    #expect(AnswerMapping.alwaysRule(suggestions: .array([.object(["type": .string("setMode")])]), style: .suggestionsVerbatim) == nil)
}

@Test func alwaysAllowRepliesWithTheVerifiedRuleShape() {
    let verbatim = AnswerMapping.permissionReply(.alwaysAllow, suggestions: sdkSuggestion, style: .suggestionsVerbatim)
    #expect(verbatim == BridgeReply(decision: "allow", updatedPermissions: .array([sdkSuggestion.array![0]])))
    let remember = AnswerMapping.permissionReply(.alwaysAllow, suggestions: docsSuggestion, style: .ruleRemember)
    #expect(remember == BridgeReply(decision: "allow",
                                    updatedPermissions: .object(["rule": .string("Bash(git push *)"), "remember": .bool(true)])))
    #expect(AnswerMapping.permissionReply(.alwaysAllow, suggestions: nil, style: .suggestionsVerbatim) == BridgeReply(decision: "allow"))
    #expect(AnswerMapping.permissionReply(.allow, suggestions: docsSuggestion) == BridgeReply(decision: "allow"))
    #expect(AnswerMapping.permissionReply(.deny, suggestions: docsSuggestion) == BridgeReply(decision: "deny"))
    #expect(AnswerMapping.permissionReply(.answers([1]), suggestions: nil) == BridgeReply(decision: nil))
}
```

Append to `mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift`:

```swift
private let questionLine = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/x/proj","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color?","header":"Color","options":[{"label":"Red","description":"Warm"},{"label":"Green","description":""}],"multiSelect":false},{"question":"Which fruits?","header":"Fruits","options":[{"label":"Apple","description":"a"},{"label":"Banana","description":"b"},{"label":"Cherry","description":"c"}],"multiSelect":true}]}}"#.utf8)

private func pages(_ board: FakeBoard) -> [(id: UInt32, index: Int, count: Int)] {
    board.sent.compactMap { m -> (id: UInt32, index: Int, count: Int)? in
        if case .question(let id, let index, let count, _, _) = m { return (id, index, count) }
        return nil
    }
}

@Test func questionRoundTripRepliesWithTheMappedAnswers() async throws {
    if HookSchema.questionAnswers == .terminalOnly { return }      // questions never reach the board then
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(questionLine, conn) }
    try? await Task.sleep(for: .milliseconds(50))
    let shown = pages(board)
    #expect(shown.map(\.index) == [0, 1] && shown.allSatisfy { $0.count == 2 && $0.id == shown[0].id })
    await p.requests.handle(.answers(id: shown[0].id, masks: [0b10, 0b101]))
    await done.value
    let e = try HookEvent.parse(questionLine)
    let expected = AnswerMapping.questionReply([0b10, 0b101], questions: try #require(AskQuestion.parse(e.toolInput)),
                                               toolInput: e.toolInput)
    #expect(conn.replies == [expected])
}

@Test func hookDisconnectCancelsQuestion() async {
    if HookSchema.questionAnswers == .terminalOnly { return }
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(questionLine, conn) }
    try? await Task.sleep(for: .milliseconds(50))
    let id = pages(board)[0].id
    conn.hookGoesAway()                         // answered in the terminal / Remote Control
    await done.value
    try? await Task.sleep(for: .milliseconds(50))
    #expect(board.sent.last == .cancel(id: id))
    #expect(conn.replies == [BridgeReply(decision: nil)])
    await p.requests.handle(.answers(id: id, masks: [1, 1]))   // a late Send changes nothing
    #expect(conn.replies.count == 1)
}

@Test func unsupportedQuestionFallsThroughImmediately() async {
    let line = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/x","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","options":[{"label":"1"},{"label":"2"},{"label":"3"},{"label":"4"},{"label":"5"}]}]}}"#.utf8)
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let start = ContinuousClock.now
    await p.process(line, conn)
    #expect(ContinuousClock.now - start < .milliseconds(200))
    #expect(conn.replies == [BridgeReply(decision: nil)])
    try? await Task.sleep(for: .milliseconds(30))
    #expect(board.sent.isEmpty)
}

@Test func permissionOffersAlwaysAllowOnlyWithAUsableSuggestion() async {
    let line = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/x/proj","tool_name":"Bash","tool_input":{"command":"git push"},"permission_suggestions":[{"rule":"Bash(git push *)","description":"d","specificity":"moderate"}]}"#.utf8)
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(line, conn) }
    try? await Task.sleep(for: .milliseconds(50))
    let rule = AnswerMapping.alwaysRule(suggestions: try? HookEvent.parse(line).permissionSuggestions)
    #expect(board.sent == [.permission(id: board.permissionIds[0], project: "proj", tool: "Bash", summary: "git push", alwaysRule: rule)])
    let choice: BoardChoice = rule == nil ? .allow : .alwaysAllow
    await p.requests.handle(.choice(id: board.permissionIds[0], choice))
    await done.value
    let expected = AnswerMapping.permissionReply(rule == nil ? .allow : .alwaysAllow,
                                                 suggestions: try? HookEvent.parse(line).permissionSuggestions)
    #expect(conn.replies == [expected])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test 2>&1 | tail -20`
Expected: build error — `AnswerMapping` is not defined.

- [ ] **Step 3: Implement the mapping**

Create `mac/Sources/ClaudeBoardCore/AnswerMapping.swift`:

```swift
import Foundation

/// Board answers → the hook's reply. The verified field names and styles live in HookSchema (hook spike);
/// every style is implemented so the spike only has to pick one.
public enum AnswerMapping {
    /// Caption of the rule "Always allow" would add, or nil when the button must not be offered. Reads the
    /// first permission_suggestions element in either known shape: {"rule": …} (hooks docs) or
    /// {"type": "addRules", "rules": [{"toolName", "ruleContent"}], …} (permission update).
    public static func alwaysRule(suggestions: JSONValue?, style: AlwaysAllowStyle = HookSchema.alwaysAllow) -> String? {
        guard style != .unsupported, let first = suggestions?.array?.first?.object else { return nil }
        if let rule = first["rule"]?.string, !rule.isEmpty { return rule }
        if let rules = first["rules"]?.array {
            let names = rules.compactMap { r -> String? in
                guard let o = r.object, let tool = o["toolName"]?.string, !tool.isEmpty else { return nil }
                if let content = o["ruleContent"]?.string, !content.isEmpty { return "\(tool)(\(content))" }
                return tool
            }
            if !names.isEmpty { return names.joined(separator: ", ") }
        }
        return nil
    }

    public static func permissionReply(_ r: BoardResponse, suggestions: JSONValue?,
                                       style: AlwaysAllowStyle = HookSchema.alwaysAllow) -> BridgeReply {
        switch r {
        case .allow:
            return BridgeReply(decision: "allow")
        case .deny:
            return BridgeReply(decision: "deny")
        case .alwaysAllow:
            // The user tapped an allow button: without a usable rule it is a plain allow
            guard let rule = alwaysRule(suggestions: suggestions, style: style),
                  let first = suggestions?.array?.first else { return BridgeReply(decision: "allow") }
            switch style {
            case .suggestionsVerbatim:
                return BridgeReply(decision: "allow", updatedPermissions: .array([first]))
            case .ruleRemember:
                return BridgeReply(decision: "allow",
                                   updatedPermissions: .object(["rule": .string(rule), "remember": .bool(true)]))
            case .unsupported:
                return BridgeReply(decision: "allow")
            }
        case .answers:
            return BridgeReply(decision: nil)
        }
    }

    /// Labels chosen per question, in option order (labels from the original tool_input, never the cut ones).
    public static func chosenLabels(_ masks: [UInt8], _ questions: [AskQuestion]) -> [[String]] {
        zip(masks, questions).map { mask, q in
            q.options.indices.filter { mask & (1 << $0) != 0 }.map { q.options[$0].label }
        }
    }

    /// The spec's fallback text: "The user answered on the board: <question> → <choice>[; …]"
    public static func boardAnswerText(_ masks: [UInt8], questions: [AskQuestion]) -> String {
        let parts = zip(questions, chosenLabels(masks, questions)).map { q, labels in
            "\(q.question) → \(labels.joined(separator: ", "))"
        }
        return "The user answered on the board: " + parts.joined(separator: "; ")
    }

    public static func questionReply(_ masks: [UInt8], questions: [AskQuestion], toolInput: [String: JSONValue],
                                     style: QuestionAnswerStyle = HookSchema.questionAnswers) -> BridgeReply {
        switch style {
        case .denyWithReason:
            return BridgeReply(decision: "deny", message: boardAnswerText(masks, questions: questions))
        case .updatedInputJoined, .updatedInputArrays:
            var answers: [String: JSONValue] = [:]
            for (q, labels) in zip(questions, chosenLabels(masks, questions)) {
                answers[q.question] = style == .updatedInputJoined
                    ? .string(labels.joined(separator: ", "))
                    : .array(labels.map { .string($0) })
            }
            var updated = toolInput
            updated["answers"] = .object(answers)
            return BridgeReply(decision: "allow", updatedInput: .object(updated))
        case .terminalOnly:
            return BridgeReply(decision: nil)
        }
    }
}
```

- [ ] **Step 4: The processor asks permissions and questions**

Replace `mac/Sources/ClaudeBoardCore/HookProcessor.swift` with:

```swift
import Foundation

/// The BLE link to the board, as the daemon's request handling sees it.
public protocol BoardLinking: Sendable {
    /// Subscribed to the board's answer characteristic: messages can be delivered and answered.
    var isReady: Bool { get }
    func send(_ message: BoardMessage)
}

/// One accepted hook connection on the daemon's Unix socket.
public protocol HookConnection: Sendable {
    /// Calls `handler` (possibly more than once) when the hook side goes away: EOF, error, a stray byte,
    /// or the connection being cancelled. Harmless after the reply has been sent.
    func onPeerGone(_ handler: @escaping @Sendable () -> Void)
    /// Sends one reply line, then closes the connection.
    func reply(_ reply: BridgeReply)
    /// Closes without replying.
    func close()
}

/// Handles one hook event line received by the daemon. Never decides on its own: a request is answered
/// only with what the board sent back, and every failure path replies `null` or nothing.
public struct HookProcessor: Sendable {
    public let board: any BoardLinking
    public let requests: RequestQueue
    private let log: @Sendable (String) -> Void

    public init(board: any BoardLinking, requests: RequestQueue, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.board = board
        self.requests = requests
        self.log = log
    }

    public func process(_ line: Data, _ conn: any HookConnection) async {
        guard let e = try? HookEvent.parse(line) else { conn.close(); return }
        let project = Summary.project(cwd: e.cwd)
        switch e.name {
        case "PermissionRequest":
            guard board.isReady else { conn.reply(BridgeReply(decision: nil)); return }
            let reply = e.toolName == "AskUserQuestion"
                ? await askQuestion(e, project: project, conn: conn)
                : await askPermission(e, project: project, conn: conn)
            log("\(project) \(e.toolName ?? "") → \(reply.decision ?? "fall through")")
            conn.reply(reply)
        case "Stop", "Notification":
            if board.isReady {
                let text = e.name == "Stop" ? Summary.lastLine(e) : "Claude is waiting for you"
                await requests.notifyFinished(project: project, line: text)
            }
            conn.close()
        default:
            conn.close()
        }
    }

    private func askPermission(_ e: HookEvent, project: String, conn: any HookConnection) async -> BridgeReply {
        let rule = AnswerMapping.alwaysRule(suggestions: e.permissionSuggestions)
        let tool = e.toolName ?? "Tool"
        let summary = Summary.permission(e)
        let response = await cancellable(conn) { [requests] in
            await requests.ask(shape: .permission(alwaysOffered: rule != nil)) { id in
                [.permission(id: id, project: project, tool: tool, summary: summary, alwaysRule: rule)]
            }
        }
        return response.map { AnswerMapping.permissionReply($0, suggestions: e.permissionSuggestions) }
            ?? BridgeReply(decision: nil)
    }

    private func askQuestion(_ e: HookEvent, project: String, conn: any HookConnection) async -> BridgeReply {
        guard HookSchema.questionAnswers != .terminalOnly, let questions = AskQuestion.parse(e.toolInput) else {
            log("\(project) AskUserQuestion not shown on the board (unsupported); Claude asks in the terminal")
            return BridgeReply(decision: nil)
        }
        let shape = RequestShape.question(options: questions.map { $0.options.count }, multi: questions.map(\.multiSelect))
        let response = await cancellable(conn) { [requests] in
            await requests.ask(shape: shape) { id in
                questions.enumerated().map { i, q in
                    BoardMessage.question(id: id, index: i, count: questions.count, project: project, question: q)
                }
            }
        }
        guard case .answers(let masks) = response else { return BridgeReply(decision: nil) }
        return AnswerMapping.questionReply(masks, questions: questions, toolInput: e.toolInput)
    }

    /// Runs `body`, cancelling it when the hook goes away (the user answered in the terminal): the queue then
    /// cancels the request on the board.
    private func cancellable(_ conn: any HookConnection,
                             _ body: @escaping @Sendable () async -> BoardResponse?) async -> BoardResponse? {
        let task = Task { await body() }
        conn.onPeerGone { task.cancel() }
        return await task.value
    }
}
```

- [ ] **Step 5: Run all Mac tests**

Run: `cd mac && swift test 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add mac/Sources/ClaudeBoardCore/AnswerMapping.swift mac/Sources/ClaudeBoardCore/HookProcessor.swift \
        mac/Tests/ClaudeBoardCoreTests/AnswerMappingTests.swift mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift
git commit -F - <<'EOF'
mac: AskUserQuestion pages and Always allow, answered through the verified hook shape

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 7: Mac — session hub, daemon wiring and the new hooks in the installer

**Files:**
- Create: `mac/Sources/ClaudeBoardCore/SessionHub.swift`
- Modify: `mac/Sources/ClaudeBoardCore/HookProcessor.swift` (hub, Stop/Notification)
- Modify: `mac/Sources/claude-board/main.swift`
- Modify: `mac/claude_settings.py`
- Create: `mac/test_claude_settings.py`
- Test: `mac/Tests/ClaudeBoardCoreTests/SessionHubTests.swift`, `mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift`

**Interfaces:**
- Consumes: `SessionTracker`, `TrackerEffect` (Task 4); `BoardInput`, `BoardMode`, `SessionRow`, `BoardMessage.session/sessionRemove/sessionsClear` (Task 3); `RequestQueue.post`, `notifyFinished` (Task 5); `HookSchema.sessionHooks` (Task 2); `SESSION_HOOKS` from the spike's Decisions table (Task 1); test helpers `hookEvent(…)` (Task 4) and `actor Sent` (Task 5).
- Produces:
  - `enum SessionSync { static func diff(old: [UInt32: SessionRow], new: [SessionRow]) -> [BoardMessage] }` (removes first, then upserts of new or changed rows, in board order)
  - `actor SessionHub` with `init(sessionHooks: Bool, post: @escaping @Sendable (BoardMessage) async -> Void, finished: @escaping @Sendable (String, String) async -> Void, clock: @escaping @Sendable () -> Int64 = …)`, `record(_ e: HookEvent) async`, `requestAnswered(sessionId: String) async`, `boardInput(_ i: BoardInput) async`, `boardConnected(_ up: Bool) async`, `tick() async`, `var focusedSessionId: String? { get }`, `func tmuxPane(sessionId: String) -> String?`.
  - `HookProcessor.init(board:requests:hub:log:)` (hub optional, defaults to nil).
  - `claude_settings.HOOKS` (list of `(event, entry_extra, hook_extra)`), `claude_settings.SESSION_HOOKS`.

Rules this task pins:
- Session traffic only while the board reports `.claude` or `.picker`; on every activation and on every reconnect it starts with `sessionsClear` then the rows (full sync); after that only changed rows (deltas). `.other` and disconnects stop it.
- The focused session's Stop sends `finished` in any mode (chime + last line); other sessions only change their row (badge).
- Leaving the picker (mode was `.picker`, becomes anything else) marks all done sessions seen; a focus from the board clears that session's badge.
- The hub ticks every 60 s on the Mac (expiry); the board never polls.

- [ ] **Step 1: Write the failing tests**

Create `mac/Tests/ClaudeBoardCoreTests/SessionHubTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeBoardCore

final class FakeNow: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Int64
    init(_ t: Int64) { self.t = t }
    var now: Int64 { lock.withLock { t } }
    func advance(_ s: Int64) { lock.withLock { t += s } }
}

private func makeHub() -> (SessionHub, Sent, FakeNow) {
    let sent = Sent()
    let now = FakeNow(1_000)
    let hub = SessionHub(sessionHooks: true,
                         post: { await sent.add($0) },
                         finished: { await sent.add(.finished(id: 0, project: $0, line: $1)) },
                         clock: { now.now })
    return (hub, sent, now)
}

private func kinds(_ ms: some Collection<BoardMessage>) -> [String] {
    ms.map {
        switch $0 {
        case .session(let r): "row\(r.handle)"
        case .sessionRemove(let h): "rm\(h)"
        case .sessionsClear: "clear"
        case .finished(_, let p, let l): "fin:\(p):\(l)"
        default: "other"
        }
    }
}

private func rows(_ ms: some Collection<BoardMessage>) -> [SessionRow] {
    ms.compactMap { if case .session(let r) = $0 { r } else { nil } }
}

@Test func inactiveBoardGetsNoSessionTraffic() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("UserPromptSubmit"))
    await hub.record(hookEvent("UserPromptSubmit", sid: "s2"))
    await hub.boardInput(.mode(.other))
    #expect(await sent.messages.isEmpty)
}

@Test func activationSendsClearThenAllRows() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("SessionStart", sid: "a"))
    await hub.record(hookEvent("SessionStart", sid: "b", cwd: "/x/beta"))
    await hub.boardInput(.mode(.claude))
    let k = kinds(await sent.messages)
    #expect(k.first == "clear" && k.count == 3 && Set(k.dropFirst()) == ["row1", "row2"])
}

@Test func deltasCarryOnlyChangedRows() async {
    let (hub, sent, now) = makeHub()
    await hub.record(hookEvent("SessionStart", sid: "a"))
    await hub.record(hookEvent("SessionStart", sid: "b"))
    await hub.boardInput(.mode(.picker))
    let before = await sent.messages.count
    now.advance(5)
    await hub.record(hookEvent("UserPromptSubmit", sid: "b"))
    let new = await sent.messages.dropFirst(before)
    #expect(kinds(new) == ["row2"])
    #expect(rows(new).first?.state == .working && rows(new).first?.since == 1_005)
}

@Test func leavingThePickerMarksDoneSessionsSeen() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("UserPromptSubmit", sid: "a"))           // focused
    await hub.record(hookEvent("Stop", sid: "b", cwd: "/x/beta"))       // done while not focused
    await hub.boardInput(.mode(.picker))
    #expect(rows(await sent.messages).first { $0.handle == 2 }?.unseen == true)   // the picker shows "new"
    let before = await sent.messages.count
    await hub.boardInput(.mode(.claude))           // picker → Claude: still active, so a delta, not a resync
    let after = await sent.messages.dropFirst(before)
    #expect(kinds(after) == ["row2"])
    #expect(rows(after).first?.unseen == false)
}

@Test func focusFromTheBoardMovesFocusAndClearsUnseen() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("UserPromptSubmit", sid: "a"))
    await hub.record(hookEvent("Stop", sid: "b", cwd: "/x/beta"))
    await hub.boardInput(.mode(.picker))
    let before = await sent.messages.count
    await hub.boardInput(.focus(handle: 2))
    let changed = rows(await sent.messages.dropFirst(before))
    #expect(Set(changed.map(\.handle)) == [1, 2])
    #expect(changed.first { $0.handle == 2 }?.focused == true && changed.first { $0.handle == 2 }?.unseen == false)
    #expect(changed.first { $0.handle == 1 }?.focused == false)
    #expect(await hub.focusedSessionId == "b")
}

@Test func focusedStopSendsFinishedEvenWhenInactive() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("UserPromptSubmit", sid: "a", cwd: "/x/alpha"))
    await hub.record(hookEvent("Stop", sid: "a", cwd: "/x/alpha", extra: #","last_assistant_message":"Done.""#))
    await hub.record(hookEvent("Stop", sid: "b", cwd: "/x/beta", extra: #","last_assistant_message":"Other.""#))
    #expect(kinds(await sent.messages) == ["fin:alpha:Done."])
}

@Test func reconnectWhileActiveResyncs() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("SessionStart", sid: "a"))
    await hub.boardInput(.mode(.claude))
    let before = await sent.messages.count
    await hub.boardConnected(true)
    #expect(kinds(await sent.messages.dropFirst(before)) == ["clear", "row1"])
}

@Test func disconnectStopsTraffic() async {
    let (hub, sent, _) = makeHub()
    await hub.record(hookEvent("SessionStart", sid: "a"))
    await hub.boardInput(.mode(.claude))
    await hub.boardConnected(false)
    let before = await sent.messages.count
    await hub.record(hookEvent("UserPromptSubmit", sid: "a"))
    #expect(await sent.messages.count == before)
    await hub.boardConnected(true)                   // the board reports its mode again after reconnecting
    #expect(await sent.messages.count == before)
    await hub.boardInput(.mode(.picker))
    #expect(kinds(await sent.messages.dropFirst(before)) == ["clear", "row1"])
}

@Test func tickDropsEndedSessionsFromTheBoard() async {
    let (hub, sent, now) = makeHub()
    await hub.record(hookEvent("SessionStart", sid: "a"))
    await hub.boardInput(.mode(.claude))
    await hub.record(hookEvent("SessionEnd", sid: "a"))
    let before = await sent.messages.count
    now.advance(600)
    await hub.tick()
    #expect(kinds(await sent.messages.dropFirst(before)) == ["rm1"])
}

@Test func diffRemovesFirstThenUpsertsInOrder() {
    func row(_ h: UInt32, _ updated: Int64) -> SessionRow {
        SessionRow(handle: h, state: .idle, since: 0, updated: updated, focused: false, unseen: false, project: "p", lastLine: "")
    }
    let old: [UInt32: SessionRow] = [1: row(1, 10), 2: row(2, 20), 3: row(3, 30)]
    let new = [row(4, 40), row(3, 30), row(2, 25)]
    #expect(kinds(SessionSync.diff(old: old, new: new)) == ["rm1", "row4", "row2"])
}
```

In `mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift`, replace `makeProcessor` and the test `stopAndNotificationSendFinishedOnlyWhenReady` with:

```swift
private func makeProcessor(ready: Bool, timeout: Duration = .seconds(90)) -> (HookProcessor, FakeBoard) {
    let board = FakeBoard(ready: ready)
    let requests = RequestQueue(send: { board.send($0) }, timeout: timeout)
    let hub = SessionHub(sessionHooks: true, post: { await requests.post($0) },
                         finished: { await requests.notifyFinished(project: $0, line: $1) })
    return (HookProcessor(board: board, requests: requests, hub: hub), board)
}

@Test func stopOfTheFocusedSessionSendsFinishedAndIdleNotificationDoesNot() async {
    let (p, board) = makeProcessor(ready: true)
    let stop = Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/x/proj","last_assistant_message":"Xong rồi 🎉"}"#.utf8)
    let c1 = FakeConn()
    await p.process(stop, c1)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(board.sent.count == 1)
    if case .finished(_, let project, let text) = board.sent.first {
        #expect(project == "proj" && text == "Xong rồi 🎉")
    } else {
        Issue.record("expected a finished message")
    }
    #expect(c1.replies.isEmpty && c1.closed)

    let c2 = FakeConn()
    await p.process(event("Notification", extra: #","notification_type":"idle_prompt""#), c2)
    await p.process(event("Stop", extra: #","last_assistant_message":"other session""#).replacingSession("t"), FakeConn())
    try? await Task.sleep(for: .milliseconds(50))
    #expect(board.sent.count == 1)                 // idle_prompt and a non-focused Stop are silent
    #expect(c2.replies.isEmpty && c2.closed)
}

@Test func answeredRequestSetsTheSessionWorking() async {
    let (p, board) = makeProcessor(ready: true)
    await p.process(event("UserPromptSubmit"), FakeConn())
    await p.hub?.boardInput(.mode(.claude))
    let conn = FakeConn()
    let done = Task { await p.process(permissionLine, conn) }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(board.sent.contains { if case .session(let r) = $0 { r.state == .needsYou } else { false } })
    await p.requests.handle(.choice(id: board.permissionIds[0], .allow))
    await done.value
    try? await Task.sleep(for: .milliseconds(50))
    if case .session(let r) = board.sent.last { #expect(r.state == .working) } else { Issue.record("expected a row") }
}
```

and add, next to the private `event(_:extra:)` helper at the top of that file:

```swift
private extension Data {
    /// The same event line for another session id
    func replacingSession(_ id: String) -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: #""session_id":"s""#, with: #""session_id":"\#(id)""#).utf8)
    }
}
```

Create `mac/test_claude_settings.py`:

```python
# mac/test_claude_settings.py — run: cd mac && python3 -m unittest test_claude_settings -v
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import claude_settings  # noqa: E402

HOOK = "/x/bin/claude-board-hook"


def run(*args):
    subprocess.run([sys.executable, os.path.join(HERE, "claude_settings.py"), *args], check=True, capture_output=True)


def ours(settings, event):
    return [h for e in settings.get("hooks", {}).get(event, []) for h in e.get("hooks", [])
            if h.get("command", "").strip().strip("\"'").endswith("claude-board-hook")]


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "settings.json")
        with open(self.path, "w") as f:
            json.dump({"model": "x", "hooks": {
                "Stop": [{"hooks": [{"type": "command", "command": "other-tool"}]}],
                "Notification": [{"matcher": "idle_prompt", "hooks": [{"type": "command", "command": '"%s"' % HOOK, "async": True}]}],
            }}, f)

    def load(self):
        with open(self.path) as f:
            return json.load(f)

    def test_session_hooks_follow_the_spike(self):
        events = {e for e, _, _ in claude_settings.HOOKS}
        self.assertTrue({"PermissionRequest", "Stop", "Notification", "UserPromptSubmit"} <= events)
        self.assertEqual("SessionStart" in events, claude_settings.SESSION_HOOKS)
        self.assertEqual("SessionEnd" in events, claude_settings.SESSION_HOOKS)

    def test_install_adds_every_hook_once_and_only_permission_is_sync(self):
        run("install", self.path, HOOK)
        run("install", self.path, HOOK)            # idempotent
        s = self.load()
        for event, _, _ in claude_settings.HOOKS:
            hooks = ours(s, event)
            self.assertEqual(len(hooks), 1, event)
            if event == "PermissionRequest":
                self.assertEqual(hooks[0].get("timeout"), 100)
                self.assertNotIn("async", hooks[0])
            else:
                self.assertIs(hooks[0].get("async"), True, event)
        self.assertEqual(s["model"], "x")
        self.assertIn({"type": "command", "command": "other-tool"}, [h for e in s["hooks"]["Stop"] for h in e["hooks"]])

    def test_notification_hook_takes_every_type(self):
        run("install", self.path, HOOK)
        entries = [e for e in self.load()["hooks"]["Notification"] if ours({"hooks": {"N": [e]}}, "N")]
        self.assertEqual(len(entries), 1)
        self.assertNotIn("matcher", entries[0])     # the old idle_prompt-only entry is replaced

    def test_uninstall_removes_only_ours(self):
        run("install", self.path, HOOK)
        run("uninstall", self.path)
        s = self.load()
        for event, _, _ in claude_settings.HOOKS:
            self.assertEqual(ours(s, event), [], event)
        self.assertEqual(s["hooks"]["Stop"], [{"hooks": [{"type": "command", "command": "other-tool"}]}])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test 2>&1 | tail -20; python3 -m unittest test_claude_settings -v 2>&1 | tail -5`
Expected: Swift build error — `SessionHub`, `SessionSync` and `HookProcessor.init(…hub:…)` do not exist; Python `AttributeError: module 'claude_settings' has no attribute 'HOOKS'`.

- [ ] **Step 3: Implement the hub**

Create `mac/Sources/ClaudeBoardCore/SessionHub.swift`:

```swift
import Foundation

public enum SessionSync {
    /// Messages that turn the board's rows `old` into `new`: removes first (the board never holds more than
    /// it shows), then the new or changed rows in board order.
    public static func diff(old: [UInt32: SessionRow], new: [SessionRow]) -> [BoardMessage] {
        let keep = Set(new.map(\.handle))
        var out: [BoardMessage] = old.keys.sorted().filter { !keep.contains($0) }.map { .sessionRemove(handle: $0) }
        for r in new where old[r.handle] != r { out.append(.session(r)) }
        return out
    }
}

/// Sessions as the board sees them. Rows flow only while the board shows Claude or the picker (battery):
/// a full sync (clear + rows) on activation or reconnect, then deltas. The focused session's "done" goes out
/// in any mode.
public actor SessionHub {
    private var tracker: SessionTracker
    private var mode: BoardMode = .other
    /// Rows the board holds; nil = it needs a full sync
    private var shown: [UInt32: SessionRow]?
    private let post: @Sendable (BoardMessage) async -> Void
    private let finished: @Sendable (String, String) async -> Void
    private let clock: @Sendable () -> Int64

    public init(sessionHooks: Bool,
                post: @escaping @Sendable (BoardMessage) async -> Void,
                finished: @escaping @Sendable (String, String) async -> Void,
                clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.tracker = SessionTracker(sessionHooks: sessionHooks)
        self.post = post
        self.finished = finished
        self.clock = clock
    }

    public var focusedSessionId: String? { tracker.focusedId }

    public func tmuxPane(sessionId: String) -> String? { tracker.tmuxPane(sessionId: sessionId) }

    public func record(_ e: HookEvent) async {
        if case .focusedDone(let project, let line) = tracker.record(e, now: clock()) {
            await finished(project, line)
        }
        await push()
    }

    public func requestAnswered(sessionId: String) async {
        tracker.requestAnswered(sessionId, now: clock())
        await push()
    }

    public func boardInput(_ input: BoardInput) async {
        switch input {
        case .mode(let m):
            if mode == .picker && m != .picker { tracker.markAllSeen() }   // the user has looked at the rows
            if m == .other { shown = nil }
            mode = m
            await push()
        case .focus(let handle):
            if tracker.focus(handle: handle) { await push() }
        case .choice, .answers:
            break
        }
    }

    /// up: resync if the board is active (it reports its mode again right after subscribing);
    /// down: stop all session traffic until the board reports an active mode.
    public func boardConnected(_ up: Bool) async {
        shown = nil
        if up { await push() } else { mode = .other }
    }

    /// Every 60 s from the daemon: ended sessions leave, silent sessions end (no session hooks).
    public func tick() async {
        tracker.expire(now: clock())
        await push()
    }

    private func push() async {
        guard mode != .other else { return }
        let rows = tracker.rows()
        var messages: [BoardMessage] = shown == nil ? [.sessionsClear] : []
        messages += SessionSync.diff(old: shown ?? [:], new: rows)
        shown = Dictionary(uniqueKeysWithValues: rows.map { ($0.handle, $0) })   // before awaiting: reentrancy
        for m in messages { await post(m) }
    }
}
```

- [ ] **Step 4: The processor feeds the hub**

In `mac/Sources/ClaudeBoardCore/HookProcessor.swift`:

Replace

```swift
    public let board: any BoardLinking
    public let requests: RequestQueue
    private let log: @Sendable (String) -> Void

    public init(board: any BoardLinking, requests: RequestQueue, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.board = board
        self.requests = requests
        self.log = log
    }
```

with

```swift
    public let board: any BoardLinking
    public let requests: RequestQueue
    public let hub: SessionHub?
    private let log: @Sendable (String) -> Void

    public init(board: any BoardLinking, requests: RequestQueue, hub: SessionHub? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.board = board
        self.requests = requests
        self.hub = hub
        self.log = log
    }
```

Replace the body of `process` from `let project = Summary.project(cwd: e.cwd)` to the end of the `switch` with:

```swift
        await hub?.record(e)       // every event: session state (PermissionRequest → needs you)
        let project = Summary.project(cwd: e.cwd)
        switch e.name {
        case "PermissionRequest":
            guard board.isReady else { conn.reply(BridgeReply(decision: nil)); return }
            let reply = e.toolName == "AskUserQuestion"
                ? await askQuestion(e, project: project, conn: conn)
                : await askPermission(e, project: project, conn: conn)
            if reply.decision != nil { await hub?.requestAnswered(sessionId: e.sessionId) }
            log("\(project) \(e.toolName ?? "") → \(reply.decision ?? "fall through")")
            conn.reply(reply)
        default:
            // Stop / Notification / session events: the hub sends the focused session's "done" and the rows
            conn.close()
        }
```

- [ ] **Step 5: Wire the daemon**

In `mac/Sources/claude-board/main.swift` (the hub is declared right after `requests`: top-level closures cannot capture a global declared later), replace

```swift
let requests = RequestQueue(send: { board.send($0) })
board.onInput = { input in Task { await requests.handle(input) } }
```

with

```swift
let requests = RequestQueue(send: { board.send($0) })
let hub = SessionHub(sessionHooks: HookSchema.sessionHooks,
                     post: { await requests.post($0) },
                     finished: { await requests.notifyFinished(project: $0, line: $1) })
board.onInput = { input in
    if case .mode(let m) = input { log("board mode \(m)") }
    Task {
        await requests.handle(input)
        await hub.boardInput(input)
    }
}
```

replace

```swift
    } else {
        Task { await requests.boardDisconnected() }
    }
}
```

(the end of `board.onConnectionChange`) with

```swift
    } else {
        Task { await requests.boardDisconnected() }
    }
    Task { await hub.boardConnected(up) }
}
```

and replace `let processor = HookProcessor(board: board, requests: requests, log: log)` with (the clock/time-zone observers above it stay as they are):

```swift
let processor = HookProcessor(board: board, requests: requests, hub: hub, log: log)

// Session expiry (ended → dropped after 10 min; 2 h fallback without session hooks)
let expiryTimer = DispatchSource.makeTimerSource(queue: .main)
expiryTimer.schedule(deadline: .now() + 60, repeating: 60)
expiryTimer.setEventHandler { Task { await hub.tick() } }
expiryTimer.resume()
```

- [ ] **Step 6: Install the new hooks**

In `mac/claude_settings.py`, after `import json, os, plistlib, sys, tempfile, time` add:

```python

# Hook spike (docs/superpowers/notes/2026-10-04-hook-spike.md, Decisions table, SESSION_HOOKS):
# SessionStart / SessionEnd fire from settings hooks. If False the daemon ends silent sessions after 2 h.
SESSION_HOOKS = True

# (event, extra keys of the matcher entry, extra keys of our hook object)
HOOKS = [
    ("PermissionRequest", {"matcher": "*"}, {"timeout": 100}),
    ("Stop", {}, {"async": True}),
    ("Notification", {}, {"async": True}),          # every type: idle_prompt, permission_prompt, ...
    ("UserPromptSubmit", {}, {"async": True}),
] + ([("SessionStart", {}, {"async": True}), ("SessionEnd", {}, {"async": True})] if SESSION_HOOKS else [])
```

Set `SESSION_HOOKS` to the spike's value. Then replace the install loop

```python
        for event, extra in (("PermissionRequest", {"matcher": "*"}),
                             ("Stop", {}),
                             ("Notification", {"matcher": "idle_prompt"})):
            lst = hooks.get(event, [])
            if not isinstance(lst, list):
                die("hooks.%s is not an array; left untouched" % event)
            lst, _ = strip_ours(lst)
            hook = {"type": "command", "command": cmd}
            hook.update({"timeout": 100} if event == "PermissionRequest" else {"async": True})
            lst.append(dict(extra, hooks=[hook]))
            hooks[event] = lst
```

with

```python
        for event, extra, hook_extra in HOOKS:
            lst = hooks.get(event, [])
            if not isinstance(lst, list):
                die("hooks.%s is not an array; left untouched" % event)
            lst, _ = strip_ours(lst)
            hook = {"type": "command", "command": cmd}
            hook.update(hook_extra)
            lst.append(dict(extra, hooks=[hook]))
            hooks[event] = lst
```

- [ ] **Step 7: Run all Mac tests, the installer test and a release build**

Run: `cd mac && swift test 2>&1 | tail -5 && python3 -m unittest test_claude_settings -v 2>&1 | tail -3 && swift build -c release 2>&1 | tail -1`
Expected: all Swift tests pass; `OK` from unittest; `Build complete!`.

- [ ] **Step 8: Commit**

```bash
git add mac/Sources/ClaudeBoardCore/SessionHub.swift mac/Sources/ClaudeBoardCore/HookProcessor.swift \
        mac/Sources/claude-board/main.swift mac/claude_settings.py mac/test_claude_settings.py \
        mac/Tests/ClaudeBoardCoreTests/SessionHubTests.swift mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift
git commit -F - <<'EOF'
mac: session hub (deltas only while the board shows Claude), session hooks installed

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---
### Task 8: Firmware — protocol v2 parsers and encoders (host-tested)

**Files:**
- Modify: `firmware/main/claude_proto.h` (whole file), `firmware/main/claude_proto.c` (whole file)
- Test: `firmware/test/test_claude_proto.c`

**Interfaces:**
- Consumes: the wire format in "Protocol" above (same vectors as Task 3).
- Produces (used by Tasks 9–11):
  - kinds `CLAUDE_SESSION = 4`, `CLAUDE_SESSION_REMOVE = 5`, `CLAUDE_SESSIONS_CLEAR = 6`, `CLAUDE_QUESTION = 7`
  - `size_t claude_utf8_cut(const char *s, size_t n);` `size_t claude_split_lines(char *text, char **fields, size_t max);`
  - `claude_session_t { uint32_t handle; char state; uint8_t flags; int64_t since; int64_t updated; char project[CLAUDE_PROJECT_MAX + 1]; char line[CLAUDE_TEXT_MAX + 1]; }`, `CLAUDE_PROJECT_MAX 64`, `CLAUDE_STATE_NEEDS_YOU 'n'`, `CLAUDE_STATE_WORKING 'w'`, `CLAUDE_STATE_IDLE 'i'`, `CLAUDE_STATE_ENDED 'e'`, `CLAUDE_SESSION_FOCUSED 0x01`, `CLAUDE_SESSION_UNSEEN 0x02`, `bool claude_parse_session(const claude_msg_t *m, claude_session_t *out);`
  - `claude_question_t { uint8_t index, count, nopt; bool multi; uint16_t project, header, question, label[4], desc[4]; char buf[CLAUDE_TEXT_MAX + 1]; }`, `CLAUDE_Q_MAX 4`, `CLAUDE_OPT_MAX 4`, `CLAUDE_Q_STR(q, field)`, `bool claude_parse_question(const claude_msg_t *m, claude_question_t *out);`
  - `CLAUDE_INPUT_MAX 10`, `CLAUDE_DECISION_ALLOW 1`, `CLAUDE_DECISION_DENY 2`, `CLAUDE_DECISION_ALWAYS 3`, `CLAUDE_INPUT_ANSWERS 0x10`, `CLAUDE_INPUT_MODE 0x20`, `CLAUDE_INPUT_FOCUS 0x21`, `CLAUDE_BOARD_OTHER 0`, `CLAUDE_BOARD_CLAUDE 1`, `CLAUDE_BOARD_PICKER 2`, `size_t claude_encode_answers(uint32_t id, const uint8_t *masks, size_t n, uint8_t out[CLAUDE_INPUT_MAX]);`, `size_t claude_encode_mode(uint8_t mode, uint8_t out[CLAUDE_INPUT_MAX]);`, `size_t claude_encode_focus(uint32_t handle, uint8_t out[CLAUDE_INPUT_MAX]);` (0 = refused)

Parsers copy into their own buffers (no pointers into `claude_msg_t`, which `ble_link.c` reuses for the next write); question fields are offsets into the copy so the struct can be copied safely.

- [ ] **Step 1: Write the failing tests**

In `firmware/test/test_claude_proto.c`, change the first line to

```c
// firmware/test/test_claude_proto.c — build: cc -Wall -Werror -I../main -o /tmp/test_claude_proto test_claude_proto.c ../main/claude_proto.c && /tmp/test_claude_proto
```

then add before `int main(void)`:

```c
static claude_msg_t msg(claude_kind_t kind, uint32_t id, const char *text)
{
    claude_msg_t m;
    memset(&m, 0, sizeof m);
    m.kind = kind;
    m.id = id;
    snprintf(m.text, sizeof m.text, "%s", text);
    return m;
}

/* Feeds kind+id+text in 20-byte writes (default ATT MTU 23 - 3), like the Mac */
static claude_msg_t from_wire(uint8_t kind, uint32_t id, const char *text)
{
    uint8_t payload[CLAUDE_TEXT_MAX + 5] = { kind, (uint8_t)(id & 0xff), (uint8_t)((id >> 8) & 0xff),
                                             (uint8_t)((id >> 16) & 0xff), (uint8_t)(id >> 24) };
    size_t n = 5 + strlen(text);
    memcpy(payload + 5, text, strlen(text));
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    bool done = false;
    for (size_t off = 0; off < n; off += 19) {
        uint8_t chunk[20];
        size_t len = n - off < 19 ? n - off : 19;
        chunk[0] = (off == 0 ? 1 : 0) | (off + len == n ? 2 : 0);
        memcpy(chunk + 1, payload + off, len);
        done = claude_rx_feed(&rx, chunk, len + 1, &m);
    }
    assert(done);
    return m;
}

static void session_parses(void)
{
    claude_msg_t m = from_wire(CLAUDE_SESSION, 5, "w 1759555200 1759555260 1\ndự-án\nDone.");
    claude_session_t s;
    assert(m.kind == CLAUDE_SESSION && claude_parse_session(&m, &s));
    assert(s.handle == 5 && s.state == CLAUDE_STATE_WORKING && s.flags == CLAUDE_SESSION_FOCUSED);
    assert(s.since == 1759555200LL && s.updated == 1759555260LL);
    assert(strcmp(s.project, "dự-án") == 0 && strcmp(s.line, "Done.") == 0);
}

static void session_empty_line_and_unseen(void)
{
    claude_msg_t m = msg(CLAUDE_SESSION, 9, "i -5 2 2\np\n");
    claude_session_t s;
    assert(claude_parse_session(&m, &s));
    assert(s.state == CLAUDE_STATE_IDLE && s.since == -5 && s.flags == CLAUDE_SESSION_UNSEEN);
    assert(strcmp(s.project, "p") == 0 && s.line[0] == '\0');
}

static void session_rejects_bad_rows(void)
{
    const char *bad[] = {
        "", "w 1 2 0", "w 1 2 0\np", "x 1 2 0\np\nl", "w 1 2\np\nl", "w a 2 0\np\nl",
        "w 1 2 0 9\np\nl", "w 1 2 7\np\nl", "w1 2 3 0\np\nl",
    };
    claude_session_t s;
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        claude_msg_t m = msg(CLAUDE_SESSION, 5, bad[i]);
        assert(!claude_parse_session(&m, &s));
    }
    claude_msg_t zero = msg(CLAUDE_SESSION, 0, "w 1 2 0\np\nl");
    assert(!claude_parse_session(&zero, &s));
    claude_msg_t other = msg(CLAUDE_QUESTION, 5, "w 1 2 0\np\nl");
    assert(!claude_parse_session(&other, &s));
}

static void session_long_project_is_cut_utf8_safe(void)
{
    char text[CLAUDE_TEXT_MAX + 1] = "e 1 2 0\n";
    for (int i = 0; i < 40; i++) {
        strcat(text, "ữ");   /* 3 bytes each: 120 bytes */
    }
    strcat(text, "\nbye");
    claude_msg_t m = msg(CLAUDE_SESSION, 9, text);
    claude_session_t s;
    assert(claude_parse_session(&m, &s));
    assert(strlen(s.project) == 63);   /* 21 whole characters: 64 bytes would split the 22nd */
    assert(strcmp(s.line, "bye") == 0);
}

static const char *QTEXT = "0 2 0 3\nproj\nColor\nWhich color?\nRed\nWarm\nGreen\n\nBlue\nCool";

static void question_parses(void)
{
    claude_msg_t m = from_wire(CLAUDE_QUESTION, 0x01020304, QTEXT);
    claude_question_t q;
    assert(m.kind == CLAUDE_QUESTION && m.id == 0x01020304 && claude_parse_question(&m, &q));
    assert(q.index == 0 && q.count == 2 && !q.multi && q.nopt == 3);
    assert(strcmp(CLAUDE_Q_STR(&q, project), "proj") == 0);
    assert(strcmp(CLAUDE_Q_STR(&q, header), "Color") == 0);
    assert(strcmp(CLAUDE_Q_STR(&q, question), "Which color?") == 0);
    assert(strcmp(CLAUDE_Q_STR(&q, label[0]), "Red") == 0 && strcmp(CLAUDE_Q_STR(&q, desc[0]), "Warm") == 0);
    assert(strcmp(CLAUDE_Q_STR(&q, label[1]), "Green") == 0 && strcmp(CLAUDE_Q_STR(&q, desc[1]), "") == 0);
    assert(strcmp(CLAUDE_Q_STR(&q, label[2]), "Blue") == 0 && strcmp(CLAUDE_Q_STR(&q, desc[2]), "Cool") == 0);
    claude_question_t copy = q;   /* offsets, not pointers: a copy stays valid */
    assert(strcmp(CLAUDE_Q_STR(&copy, label[2]), "Blue") == 0);
}

static void question_rejects_bad_shapes(void)
{
    const char *bad[] = {
        "0 2 0 3\nproj\nColor\nWhich color?\nRed\nWarm\nGreen\n\nBlue",   /* one line short */
        "0 2 0 2\nproj\nColor\nQ\nA\na\nB\nb\nC",                       /* one line too many */
        "2 2 0 1\np\nh\nq\nA\na",                                         /* index >= count */
        "0 0 0 1\np\nh\nq\nA\na",                                         /* no questions */
        "0 5 0 1\np\nh\nq\nA\na",                                         /* more than 4 questions */
        "0 1 2 1\np\nh\nq\nA\na",                                         /* multi is not 0/1 */
        "0 1 0 5\np\nh\nq\nA\na\nB\nb\nC\nc\nD\nd\nE\ne",                 /* more than 4 options */
        "0 1 0 0\np\nh\nq",                                               /* no options */
        "0 1 0 1\np\nh\nq\n\nd",                                          /* empty label */
        "0 1 0 1 9\np\nh\nq\nA\na",                                       /* extra number */
        "x 1 0 1\np\nh\nq\nA\na",                                         /* not a number */
    };
    claude_question_t q;
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        claude_msg_t m = msg(CLAUDE_QUESTION, 3, bad[i]);
        assert(!claude_parse_question(&m, &q));
    }
    claude_msg_t zero = msg(CLAUDE_QUESTION, 0, QTEXT);
    assert(!claude_parse_question(&zero, &q));
}

static void input_encoders_match_the_mac(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    uint8_t masks[2] = { 0x02, 0x05 };
    assert(claude_encode_answers(0x01020304, masks, 2, out) == 8);
    const uint8_t want_answers[8] = { 0x04, 0x03, 0x02, 0x01, 0x10, 0x02, 0x02, 0x05 };
    assert(memcmp(out, want_answers, 8) == 0);
    assert(claude_encode_answers(0x01020304, masks, 0, out) == 0);
    assert(claude_encode_answers(0x01020304, masks, 5, out) == 0);
    assert(claude_encode_answers(0, masks, 2, out) == 0);

    assert(claude_encode_mode(CLAUDE_BOARD_PICKER, out) == 6);
    const uint8_t want_mode[6] = { 0, 0, 0, 0, 0x20, 2 };
    assert(memcmp(out, want_mode, 6) == 0);

    assert(claude_encode_focus(7, out) == 9);
    const uint8_t want_focus[9] = { 0, 0, 0, 0, 0x21, 7, 0, 0, 0 };
    assert(memcmp(out, want_focus, 9) == 0);
    assert(claude_encode_focus(0, out) == 0);

    uint8_t five[5];
    claude_encode_answer(0x01020304, CLAUDE_DECISION_ALWAYS, five);
    const uint8_t want_always[5] = { 0x04, 0x03, 0x02, 0x01, 3 };
    assert(memcmp(five, want_always, 5) == 0);
}

static void split_lines_keeps_the_rest_in_the_last_field(void)
{
    char *f[4];
    char t[] = "p\nBash\nnpm test\nBash(npm test:*)";
    assert(claude_split_lines(t, f, 4) == 4);
    assert(strcmp(f[0], "p") == 0 && strcmp(f[2], "npm test") == 0 && strcmp(f[3], "Bash(npm test:*)") == 0);
    char t2[] = "p\nBash\nls";
    assert(claude_split_lines(t2, f, 4) == 3 && strcmp(f[2], "ls") == 0);
    char t3[] = "a\nb\nc";
    assert(claude_split_lines(t3, f, 2) == 2 && strcmp(f[1], "b\nc") == 0);
}
```

and add these calls at the end of `main` (before the `puts`):

```c
    session_parses();
    session_empty_line_and_unseen();
    session_rejects_bad_rows();
    session_long_project_is_cut_utf8_safe();
    question_parses();
    question_rejects_bad_shapes();
    input_encoders_match_the_mac();
    split_lines_keeps_the_rest_in_the_last_field();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd firmware/test && cc -Wall -Werror -I../main -o /tmp/test_claude_proto test_claude_proto.c ../main/claude_proto.c && /tmp/test_claude_proto`
Expected: compile errors — `CLAUDE_SESSION`, `claude_session_t`, `claude_parse_question`, `claude_encode_answers` … undeclared.

- [ ] **Step 3: Write the header**

Replace `firmware/main/claude_proto.h` with:

```c
/*
 * Claude companion wire format (Mac daemon <-> board), pure C, host-tested in firmware/test/test_claude_proto.c.
 *
 * Mac -> board (request characteristic): BLE writes [flags u8][payload], flags bit0 = first, bit1 = last;
 * payload [kind u8][id u32 LE][UTF-8 text, at most CLAUDE_TEXT_MAX bytes]:
 *   0 permission      id = request  "project\ntool\nsummary[\nrule]"  (rule line <=> Always allow offered)
 *   1 finished        fresh id      "project\nlast line"               (focused session only)
 *   2 cancel          id = request  ""                                 (a permission or a whole question set)
 *   3 time            id 0          "<unix seconds> <UTC offset minutes>" (clock.h)
 *   4 session         id = handle   "<state> <since> <updated> <flags>\nproject\nlast line"
 *   5 session remove  id = handle   ""
 *   6 sessions clear  id 0          ""                                 (first message of every full sync)
 *   7 question page   id = request  "<index> <count> <multi> <nopt>\nproject\nheader\nquestion\n(label\ndesc) x nopt"
 *
 * Board -> Mac (answer characteristic, notify, at most CLAUDE_INPUT_MAX bytes):
 *   [id u32 LE][1|2|3]                   allow / deny / always allow
 *   [id u32 LE][0x10][n][mask x n]       question answers, bit i of mask q = option i of question q
 *   [0 u32][0x20][mode]                  board mode (CLAUDE_BOARD_*)
 *   [0 u32][0x21][handle u32 LE]         focus this session
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CLAUDE_TEXT_MAX 400

typedef enum {
    CLAUDE_PERMISSION = 0,
    CLAUDE_FINISHED = 1,
    CLAUDE_CANCEL = 2,
    CLAUDE_TIME = 3,
    CLAUDE_SESSION = 4,
    CLAUDE_SESSION_REMOVE = 5,
    CLAUDE_SESSIONS_CLEAR = 6,
    CLAUDE_QUESTION = 7,
} claude_kind_t;

typedef struct {
    claude_kind_t kind;
    uint32_t id;
    char text[CLAUDE_TEXT_MAX + 1];
} claude_msg_t;

typedef struct {
    uint8_t buf[CLAUDE_TEXT_MAX + 5];
    size_t len;
} claude_rx_t;

/* Feeds one BLE write ([flags][payload...]). Returns true and fills *out when the last chunk arrives. */
bool claude_rx_feed(claude_rx_t *rx, const uint8_t *chunk, size_t len, claude_msg_t *out);
void claude_encode_answer(uint32_t id, uint8_t decision, uint8_t out[5]);

/* Length of the longest prefix of s[0..n) that does not end inside a UTF-8 sequence */
size_t claude_utf8_cut(const char *s, size_t n);
/* Splits text in place at '\n' into at most max fields (the last one keeps any further newlines). Returns the count. */
size_t claude_split_lines(char *text, char **fields, size_t max);

/* Sessions (kind 4) */
#define CLAUDE_PROJECT_MAX     64
#define CLAUDE_STATE_NEEDS_YOU 'n'
#define CLAUDE_STATE_WORKING   'w'
#define CLAUDE_STATE_IDLE      'i'
#define CLAUDE_STATE_ENDED     'e'
#define CLAUDE_SESSION_FOCUSED 0x01
#define CLAUDE_SESSION_UNSEEN  0x02

typedef struct {
    uint32_t handle;   /* never 0 */
    char state;        /* CLAUDE_STATE_* */
    uint8_t flags;     /* CLAUDE_SESSION_* */
    int64_t since;     /* Unix seconds: current state began */
    int64_t updated;   /* Unix seconds: last event (picker order) */
    char project[CLAUDE_PROJECT_MAX + 1];
    char line[CLAUDE_TEXT_MAX + 1];
} claude_session_t;

bool claude_parse_session(const claude_msg_t *m, claude_session_t *out);

/* Question pages (kind 7) */
#define CLAUDE_Q_MAX   4
#define CLAUDE_OPT_MAX 4

typedef struct {
    uint8_t index;   /* 0-based page */
    uint8_t count;   /* pages in the request, 1..CLAUDE_Q_MAX */
    uint8_t nopt;    /* 1..CLAUDE_OPT_MAX */
    bool multi;
    /* Offsets into buf (a copy stays valid) */
    uint16_t project, header, question, label[CLAUDE_OPT_MAX], desc[CLAUDE_OPT_MAX];
    char buf[CLAUDE_TEXT_MAX + 1];
} claude_question_t;

#define CLAUDE_Q_STR(q, field) ((const char *)(q)->buf + (q)->field)

bool claude_parse_question(const claude_msg_t *m, claude_question_t *out);

/* Board -> Mac */
#define CLAUDE_INPUT_MAX       10
#define CLAUDE_DECISION_ALLOW  1
#define CLAUDE_DECISION_DENY   2
#define CLAUDE_DECISION_ALWAYS 3
#define CLAUDE_INPUT_ANSWERS   0x10
#define CLAUDE_INPUT_MODE      0x20
#define CLAUDE_INPUT_FOCUS     0x21
#define CLAUDE_BOARD_OTHER     0
#define CLAUDE_BOARD_CLAUDE    1
#define CLAUDE_BOARD_PICKER    2

/* Each returns the byte count to send, or 0 when the input is refused (id 0, handle 0, bad n) */
size_t claude_encode_answers(uint32_t id, const uint8_t *masks, size_t n, uint8_t out[CLAUDE_INPUT_MAX]);
size_t claude_encode_mode(uint8_t mode, uint8_t out[CLAUDE_INPUT_MAX]);
size_t claude_encode_focus(uint32_t handle, uint8_t out[CLAUDE_INPUT_MAX]);
```

- [ ] **Step 4: Write the implementation**

Replace `firmware/main/claude_proto.c` with:

```c
#include "claude_proto.h"

#include <stdlib.h>
#include <string.h>

#define FLAG_FIRST 0x01
#define FLAG_LAST  0x02

size_t claude_utf8_cut(const char *str, size_t n)
{
    const uint8_t *s = (const uint8_t *)str;
    size_t i = n;
    while (i > 0 && (s[i - 1] & 0xC0) == 0x80) {
        i--;
    }
    if (i > 0 && (s[i - 1] & 0x80)) {
        uint8_t lead = s[i - 1];
        size_t need = (lead & 0xE0) == 0xC0 ? 2 : (lead & 0xF0) == 0xE0 ? 3 : (lead & 0xF8) == 0xF0 ? 4 : 1;
        if (n - (i - 1) < need) {
            return i - 1;
        }
    }
    return n;
}

bool claude_rx_feed(claude_rx_t *rx, const uint8_t *chunk, size_t len, claude_msg_t *out)
{
    if (len < 1) {
        return false;
    }
    uint8_t flags = chunk[0];
    if (flags & FLAG_FIRST) {
        rx->len = 0;
    }
    size_t n = len - 1;
    if (rx->len + n > sizeof(rx->buf)) {
        n = sizeof(rx->buf) - rx->len;
    }
    memcpy(rx->buf + rx->len, chunk + 1, n);
    rx->len += n;

    if (!(flags & FLAG_LAST) || rx->len < 5) {
        return false;
    }
    out->kind = (claude_kind_t)rx->buf[0];
    out->id = (uint32_t)rx->buf[1] | (uint32_t)rx->buf[2] << 8 | (uint32_t)rx->buf[3] << 16 | (uint32_t)rx->buf[4] << 24;
    size_t text_len = claude_utf8_cut((const char *)rx->buf + 5, rx->len - 5);
    memcpy(out->text, rx->buf + 5, text_len);
    out->text[text_len] = '\0';
    rx->len = 0;
    return true;
}

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = v & 0xff;
    p[1] = (v >> 8) & 0xff;
    p[2] = (v >> 16) & 0xff;
    p[3] = (v >> 24) & 0xff;
}

void claude_encode_answer(uint32_t id, uint8_t decision, uint8_t out[5])
{
    put32(out, id);
    out[4] = decision;
}

size_t claude_encode_answers(uint32_t id, const uint8_t *masks, size_t n, uint8_t out[CLAUDE_INPUT_MAX])
{
    if (id == 0 || n < 1 || n > CLAUDE_Q_MAX) {
        return 0;
    }
    put32(out, id);
    out[4] = CLAUDE_INPUT_ANSWERS;
    out[5] = (uint8_t)n;
    memcpy(out + 6, masks, n);
    return 6 + n;
}

size_t claude_encode_mode(uint8_t mode, uint8_t out[CLAUDE_INPUT_MAX])
{
    put32(out, 0);
    out[4] = CLAUDE_INPUT_MODE;
    out[5] = mode;
    return 6;
}

size_t claude_encode_focus(uint32_t handle, uint8_t out[CLAUDE_INPUT_MAX])
{
    if (handle == 0) {
        return 0;
    }
    put32(out, 0);
    out[4] = CLAUDE_INPUT_FOCUS;
    put32(out + 5, handle);
    return 9;
}

size_t claude_split_lines(char *text, char **fields, size_t max)
{
    size_t n = 0;
    char *p = text;
    while (n < max) {
        fields[n++] = p;
        if (n == max) {
            break;
        }
        char *nl = strchr(p, '\n');
        if (nl == NULL) {
            break;
        }
        *nl = '\0';
        p = nl + 1;
    }
    return n;
}

/* One decimal integer (optional sign) followed by a single space or the end of the string */
static bool take_int(const char **p, long long *out)
{
    char *end;
    long long v = strtoll(*p, &end, 10);
    if (end == *p || **p == ' ') {
        return false;
    }
    if (*end == ' ') {
        end++;
    } else if (*end != '\0') {
        return false;
    }
    *out = v;
    *p = end;
    return true;
}

bool claude_parse_session(const claude_msg_t *m, claude_session_t *out)
{
    if (m->kind != CLAUDE_SESSION || m->id == 0) {
        return false;
    }
    const char *nl1 = strchr(m->text, '\n');
    const char *nl2 = nl1 ? strchr(nl1 + 1, '\n') : NULL;
    if (nl2 == NULL) {
        return false;
    }
    char meta[64];
    size_t ml = (size_t)(nl1 - m->text);
    if (ml < 3 || ml >= sizeof(meta)) {
        return false;
    }
    memcpy(meta, m->text, ml);
    meta[ml] = '\0';
    char state = meta[0];
    if (meta[1] != ' ' || (state != CLAUDE_STATE_NEEDS_YOU && state != CLAUDE_STATE_WORKING &&
                           state != CLAUDE_STATE_IDLE && state != CLAUDE_STATE_ENDED)) {
        return false;
    }
    const char *p = meta + 2;
    long long since, updated, flags;
    if (!take_int(&p, &since) || !take_int(&p, &updated) || !take_int(&p, &flags) || *p != '\0' ||
        flags < 0 || flags > (CLAUDE_SESSION_FOCUSED | CLAUDE_SESSION_UNSEEN)) {
        return false;
    }
    out->handle = m->id;
    out->state = state;
    out->flags = (uint8_t)flags;
    out->since = since;
    out->updated = updated;
    size_t pl = (size_t)(nl2 - nl1 - 1);
    pl = claude_utf8_cut(nl1 + 1, pl > CLAUDE_PROJECT_MAX ? CLAUDE_PROJECT_MAX : pl);
    memcpy(out->project, nl1 + 1, pl);
    out->project[pl] = '\0';
    size_t ll = strlen(nl2 + 1);   /* part of m->text: at most CLAUDE_TEXT_MAX */
    memcpy(out->line, nl2 + 1, ll + 1);
    return true;
}

bool claude_parse_question(const claude_msg_t *m, claude_question_t *q)
{
    if (m->kind != CLAUDE_QUESTION || m->id == 0) {
        return false;
    }
    memset(q, 0, sizeof(*q));
    size_t len = strlen(m->text);
    memcpy(q->buf, m->text, len + 1);
    size_t lines = 1;
    for (size_t i = 0; i < len; i++) {
        if (q->buf[i] == '\n') {
            lines++;
        }
    }
    if (lines < 6 || lines > 4 + 2 * CLAUDE_OPT_MAX) {
        return false;
    }
    char *f[4 + 2 * CLAUDE_OPT_MAX];
    claude_split_lines(q->buf, f, lines);
    const char *p = f[0];
    long long index, count, multi, nopt;
    if (!take_int(&p, &index) || !take_int(&p, &count) || !take_int(&p, &multi) || !take_int(&p, &nopt) ||
        *p != '\0') {
        return false;
    }
    if (count < 1 || count > CLAUDE_Q_MAX || index < 0 || index >= count || (multi != 0 && multi != 1) ||
        nopt < 1 || nopt > CLAUDE_OPT_MAX || lines != (size_t)(4 + 2 * nopt)) {
        return false;
    }
    q->index = (uint8_t)index;
    q->count = (uint8_t)count;
    q->multi = multi == 1;
    q->nopt = (uint8_t)nopt;
    q->project = (uint16_t)(f[1] - q->buf);
    q->header = (uint16_t)(f[2] - q->buf);
    q->question = (uint16_t)(f[3] - q->buf);
    for (int i = 0; i < q->nopt; i++) {
        if (f[4 + 2 * i][0] == '\0') {
            return false;   /* every option needs a label */
        }
        q->label[i] = (uint16_t)(f[4 + 2 * i] - q->buf);
        q->desc[i] = (uint16_t)(f[5 + 2 * i] - q->buf);
    }
    return true;
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd firmware/test && cc -Wall -Werror -I../main -o /tmp/test_claude_proto test_claude_proto.c ../main/claude_proto.c && /tmp/test_claude_proto`
Expected: `claude_proto: all tests passed`.

- [ ] **Step 6: Build the firmware**

`ble_link.c` and `claude_ui.c` keep compiling unchanged (old kinds, `claude_encode_answer` kept).
Run: `. ~/esp/esp-idf/export.sh && cd firmware && idf.py build 2>&1 | tail -3`
Expected: `Project build complete.`

- [ ] **Step 7: Commit**

```bash
git add firmware/main/claude_proto.h firmware/main/claude_proto.c firmware/test/test_claude_proto.c
git commit -F - <<'EOF'
firmware: Claude protocol v2 parsers (sessions, question pages) and input encoders

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 9: Firmware — session table, question model, picker event and mode report (host-tested)

**Files:**
- Create: `firmware/main/sessions.h`, `firmware/main/sessions.c`, `firmware/main/question.h`, `firmware/main/question.c`
- Modify: `firmware/main/modes.h`, `firmware/main/modes.c`, `firmware/main/shell.c:29-32` (event names), `firmware/main/CMakeLists.txt:1`
- Test: `firmware/test/test_sessions.c`, `firmware/test/test_question.c`, `firmware/test/test_modes.c`

**Interfaces:**
- Consumes: `claude_session_t`, `claude_question_t`, `claude_encode_answers`, `CLAUDE_*` constants (Task 8).
- Produces (used by Tasks 10–11):
  - `sessions_t { claude_session_t rows[SESSIONS_MAX]; int n; }`, `SESSIONS_MAX 8`, `SESSIONS_SHOWN 6`; `void sessions_clear(sessions_t *s)`, `void sessions_upsert(sessions_t *s, const claude_session_t *row)`, `void sessions_remove(sessions_t *s, uint32_t handle)`, `bool sessions_before(const claude_session_t *a, const claude_session_t *b)`, `int sessions_sorted(const sessions_t *s, const claude_session_t **out, int max)`, `const claude_session_t *sessions_focused(const sessions_t *s)`, `int sessions_badge(const sessions_t *s)`, `void sessions_set_focus(sessions_t *s, uint32_t handle)`, `void sessions_format_elapsed(int64_t seconds, char *out, size_t n)`, `const char *sessions_state_label(char state)`, `const char *sessions_state_short(char state)`, `uint32_t sessions_state_color(char state)`.
  - `question_set_t { uint32_t id; uint8_t count; uint8_t have; uint8_t page; uint8_t mask[CLAUDE_Q_MAX]; claude_question_t q[CLAUDE_Q_MAX]; }`; `void question_reset(question_set_t *s)`, `bool question_add(question_set_t *s, uint32_t id, const claude_question_t *page)` (true when the set just became complete), `bool question_complete(const question_set_t *s)`, `void question_tap(question_set_t *s, uint8_t option)`, `bool question_page_answered(const question_set_t *s, uint8_t page)`, `bool question_all_answered(const question_set_t *s)`, `bool question_last_page(const question_set_t *s)`, `void question_next(question_set_t *s)`, `void question_back(question_set_t *s)`, `size_t question_encode(const question_set_t *s, uint8_t out[CLAUDE_INPUT_MAX])`.
  - `MODES_EV_PICK` (a picker row was tapped → Claude mode; ignored while locked or over a request), `int modes_report(const modes_t *m)` → `CLAUDE_BOARD_OTHER` (0) when locked or in the translator, `CLAUDE_BOARD_CLAUDE` (1), `CLAUDE_BOARD_PICKER` (2).

- [ ] **Step 1: Write the failing tests**

Create `firmware/test/test_sessions.c`:

```c
// firmware/test/test_sessions.c — build: cc -Wall -Werror -I../main -o /tmp/test_sessions test_sessions.c ../main/sessions.c ../main/claude_proto.c && /tmp/test_sessions
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "sessions.h"

static claude_session_t row(uint32_t handle, char state, int64_t updated, uint8_t flags, const char *project)
{
    claude_session_t r;
    memset(&r, 0, sizeof r);
    r.handle = handle;
    r.state = state;
    r.since = updated;
    r.updated = updated;
    r.flags = flags;
    snprintf(r.project, sizeof r.project, "%s", project);
    return r;
}

static void upsert_replaces_the_same_handle(void)
{
    sessions_t s;
    sessions_clear(&s);
    claude_session_t a = row(1, 'w', 10, 0, "alpha");
    sessions_upsert(&s, &a);
    a.state = 'i';
    sessions_upsert(&s, &a);
    assert(s.n == 1 && s.rows[0].state == 'i');
}

static void order_is_needs_you_then_recent_then_handle(void)
{
    sessions_t s;
    sessions_clear(&s);
    claude_session_t rs[] = { row(1, 'i', 10, 0, "a"), row(2, 'w', 30, 0, "b"), row(3, 'n', 5, 0, "c"),
                              row(4, 'e', 30, 0, "d") };
    for (int i = 0; i < 4; i++) {
        sessions_upsert(&s, &rs[i]);
    }
    const claude_session_t *out[SESSIONS_SHOWN];
    assert(sessions_sorted(&s, out, SESSIONS_SHOWN) == 4);
    assert(out[0]->handle == 3 && out[1]->handle == 4 && out[2]->handle == 2 && out[3]->handle == 1);
}

static void shows_at_most_six(void)
{
    sessions_t s;
    sessions_clear(&s);
    for (uint32_t h = 1; h <= 8; h++) {
        claude_session_t r = row(h, 'i', h, 0, "p");
        sessions_upsert(&s, &r);
    }
    const claude_session_t *out[SESSIONS_SHOWN];
    assert(s.n == 8 && sessions_sorted(&s, out, SESSIONS_SHOWN) == 6);
    assert(out[0]->handle == 8 && out[5]->handle == 3);
}

static void a_full_table_drops_the_least_relevant_row(void)
{
    sessions_t s;
    sessions_clear(&s);
    for (uint32_t h = 1; h <= SESSIONS_MAX; h++) {
        claude_session_t r = row(h, 'i', 10 + h, 0, "p");
        sessions_upsert(&s, &r);
    }
    claude_session_t extra = row(99, 'w', 100, 0, "new");
    sessions_upsert(&s, &extra);
    assert(s.n == SESSIONS_MAX);
    bool has_1 = false, has_99 = false;
    for (int i = 0; i < s.n; i++) {
        has_1 |= s.rows[i].handle == 1;
        has_99 |= s.rows[i].handle == 99;
    }
    assert(!has_1 && has_99);
}

static void remove_and_clear(void)
{
    sessions_t s;
    sessions_clear(&s);
    claude_session_t a = row(1, 'i', 1, 0, "a"), b = row(2, 'i', 2, 0, "b");
    sessions_upsert(&s, &a);
    sessions_upsert(&s, &b);
    sessions_remove(&s, 1);
    sessions_remove(&s, 42);   /* unknown: nothing */
    assert(s.n == 1 && s.rows[0].handle == 2);
    sessions_clear(&s);
    assert(s.n == 0 && sessions_focused(&s) == NULL && sessions_badge(&s) == 0);
}

static void focus_is_exclusive_and_clears_unseen(void)
{
    sessions_t s;
    sessions_clear(&s);
    claude_session_t a = row(1, 'i', 1, CLAUDE_SESSION_FOCUSED, "a"), b = row(2, 'i', 2, CLAUDE_SESSION_UNSEEN, "b");
    sessions_upsert(&s, &a);
    sessions_upsert(&s, &b);
    assert(sessions_focused(&s)->handle == 1 && sessions_badge(&s) == 1);
    sessions_set_focus(&s, 2);
    assert(sessions_focused(&s)->handle == 2 && sessions_badge(&s) == 0);
    claude_session_t a2 = row(1, 'i', 3, CLAUDE_SESSION_FOCUSED, "a");   /* the Mac moves focus back */
    sessions_upsert(&s, &a2);
    assert(sessions_focused(&s)->handle == 1);
    int focused = 0;
    for (int i = 0; i < s.n; i++) {
        focused += (s.rows[i].flags & CLAUDE_SESSION_FOCUSED) != 0;
    }
    assert(focused == 1);
}

static void badge_counts_unseen_rows_that_are_not_focused(void)
{
    sessions_t s;
    sessions_clear(&s);
    claude_session_t rs[] = { row(1, 'i', 1, CLAUDE_SESSION_UNSEEN, "a"), row(2, 'i', 2, CLAUDE_SESSION_UNSEEN, "b"),
                              row(3, 'i', 3, CLAUDE_SESSION_UNSEEN | CLAUDE_SESSION_FOCUSED, "c"), row(4, 'w', 4, 0, "d") };
    for (int i = 0; i < 4; i++) {
        sessions_upsert(&s, &rs[i]);
    }
    assert(sessions_badge(&s) == 2);
}

static void elapsed_and_labels(void)
{
    char b[16];
    const struct { int64_t s; const char *want; } cases[] = {
        { -5, "<1m" }, { 0, "<1m" }, { 59, "<1m" }, { 60, "1m" }, { 3599, "59m" },
        { 3600, "1h 00m" }, { 7380, "2h 03m" }, { 100 * 3600 + 59, "100h 00m" },
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        sessions_format_elapsed(cases[i].s, b, sizeof b);
        assert(strcmp(b, cases[i].want) == 0);
    }
    assert(strcmp(sessions_state_label('n'), "Needs you") == 0 && strcmp(sessions_state_label('w'), "Working") == 0);
    assert(strcmp(sessions_state_label('i'), "Idle") == 0 && strcmp(sessions_state_label('e'), "Ended") == 0);
    assert(strcmp(sessions_state_label('?'), "") == 0);
    assert(strcmp(sessions_state_short('n'), "needs you") == 0 && strcmp(sessions_state_short('e'), "ended") == 0);
    uint32_t c[4] = { sessions_state_color('n'), sessions_state_color('w'), sessions_state_color('i'), sessions_state_color('e') };
    assert(c[0] == 0xe5484d && c[1] == 0xf5c400 && c[2] == 0x30a46c && c[3] == 0x6f6f6f);
}

int main(void)
{
    upsert_replaces_the_same_handle();
    order_is_needs_you_then_recent_then_handle();
    shows_at_most_six();
    a_full_table_drops_the_least_relevant_row();
    remove_and_clear();
    focus_is_exclusive_and_clears_unseen();
    badge_counts_unseen_rows_that_are_not_focused();
    elapsed_and_labels();
    puts("sessions: all tests passed");
    return 0;
}
```

Create `firmware/test/test_question.c`:

```c
// firmware/test/test_question.c — build: cc -Wall -Werror -I../main -o /tmp/test_question test_question.c ../main/question.c ../main/claude_proto.c && /tmp/test_question
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "question.h"

static claude_question_t page(unsigned index, unsigned count, bool multi, unsigned nopt)
{
    claude_msg_t m;
    memset(&m, 0, sizeof m);
    m.kind = CLAUDE_QUESTION;
    m.id = 1;
    int n = snprintf(m.text, sizeof m.text, "%u %u %u %u\nproj\nHeader\nQuestion %u?", index, count, multi ? 1u : 0u,
                     nopt, index + 1);
    for (unsigned i = 0; i < nopt; i++) {
        n += snprintf(m.text + n, sizeof m.text - (size_t)n, "\nOption %u\nAbout %u", i + 1, i + 1);
    }
    claude_question_t q;
    assert(claude_parse_question(&m, &q));
    return q;
}

static question_set_t s;   /* about 1.8 KB: static, as on the board */

static void completes_when_every_page_arrived(void)
{
    question_reset(&s);
    claude_question_t p1 = page(1, 2, true, 3), p0 = page(0, 2, false, 2);
    assert(!question_add(&s, 7, &p1));   /* pages may come in any order */
    assert(!question_complete(&s));
    assert(question_add(&s, 7, &p0));
    assert(question_complete(&s) && s.page == 0);
    assert(!question_add(&s, 7, &p0));   /* a repeat does not complete it again */
}

static void new_id_starts_a_new_set(void)
{
    question_reset(&s);
    claude_question_t a = page(0, 2, false, 2), b = page(0, 1, false, 2);
    question_add(&s, 7, &a);             /* half of request 7 */
    assert(question_add(&s, 8, &b));     /* request 8 (one page) replaces it */
    assert(s.id == 8 && s.count == 1 && question_complete(&s));
}

static void ids_of_zero_are_refused(void)
{
    question_reset(&s);
    claude_question_t p = page(0, 1, false, 2);
    assert(!question_add(&s, 0, &p) && s.id == 0);
}

static void taps_wait_for_the_whole_set(void)
{
    question_reset(&s);
    claude_question_t p = page(0, 2, false, 2);
    question_add(&s, 3, &p);
    question_tap(&s, 0);
    assert(s.mask[0] == 0);
}

static void single_select_replaces_and_retap_keeps(void)
{
    question_reset(&s);
    claude_question_t p = page(0, 1, false, 3);
    question_add(&s, 1, &p);
    question_tap(&s, 2);
    assert(s.mask[0] == 0x04);
    question_tap(&s, 0);
    assert(s.mask[0] == 0x01);
    question_tap(&s, 0);                 /* tapping the chosen option keeps it */
    assert(s.mask[0] == 0x01);
    question_tap(&s, 3);                 /* no such option */
    assert(s.mask[0] == 0x01);
}

static void multi_select_needs_one(void)
{
    question_reset(&s);
    claude_question_t p = page(0, 1, true, 3);
    question_add(&s, 1, &p);
    uint8_t out[CLAUDE_INPUT_MAX];
    assert(!question_page_answered(&s, 0) && question_encode(&s, out) == 0);
    question_tap(&s, 0);
    question_tap(&s, 2);
    assert(s.mask[0] == 0x05 && question_page_answered(&s, 0));
    question_tap(&s, 0);
    question_tap(&s, 2);
    assert(s.mask[0] == 0 && !question_all_answered(&s) && question_encode(&s, out) == 0);
}

static void send_needs_every_page(void)
{
    question_reset(&s);
    claude_question_t p0 = page(0, 2, false, 2), p1 = page(1, 2, true, 3);
    question_add(&s, 0x01020304, &p0);
    question_add(&s, 0x01020304, &p1);
    assert(!question_last_page(&s));
    question_next(&s);
    assert(s.page == 0);                 /* page 1 unanswered: Next does nothing */
    question_tap(&s, 1);
    question_next(&s);
    assert(s.page == 1 && question_last_page(&s));
    uint8_t out[CLAUDE_INPUT_MAX];
    assert(question_encode(&s, out) == 0);
    question_tap(&s, 0);
    question_tap(&s, 2);
    assert(question_all_answered(&s));
    question_back(&s);
    assert(s.page == 0);
    question_back(&s);
    assert(s.page == 0);
    assert(question_encode(&s, out) == 8);
    const uint8_t want[8] = { 0x04, 0x03, 0x02, 0x01, 0x10, 0x02, 0x02, 0x05 };   /* same bytes as the Mac test */
    assert(memcmp(out, want, 8) == 0);
}

int main(void)
{
    completes_when_every_page_arrived();
    new_id_starts_a_new_set();
    ids_of_zero_are_refused();
    taps_wait_for_the_whole_set();
    single_select_replaces_and_retap_keeps();
    multi_select_needs_one();
    send_needs_every_page();
    puts("question: all tests passed");
    return 0;
}
```

In `firmware/test/test_modes.c`, add before `int main(void)`:

```c
static void pick_goes_to_claude_mode(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_3, 0);
    assert(modes_report(&m) == 2);
    assert(modes_handle(&m, MODES_EV_PICK, 0));
    assert(modes_screen(&m) == SCREEN_CLAUDE && modes_report(&m) == 1);
}

static void pick_is_ignored_when_locked_or_over_a_request(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_3, 0);
    modes_handle(&m, MODES_EV_PWR_1, 0);                  /* locked */
    assert(!modes_handle(&m, MODES_EV_PICK, 0));
    assert(m.locked && m.mode == BOARD_PICKER);
    modes_handle(&m, MODES_EV_PWR_3, 0);                  /* unlocked into the picker */
    modes_handle(&m, MODES_EV_URGENT, 0);
    assert(!modes_handle(&m, MODES_EV_PICK, 0));
    assert(m.mode == BOARD_PICKER && m.urgent);
}

static void report_follows_mode_and_lock(void)
{
    modes_t m = fresh();
    assert(modes_report(&m) == 0);
    modes_handle(&m, MODES_EV_PWR_2, 0);
    assert(modes_report(&m) == 1);
    modes_handle(&m, MODES_EV_PWR_1, 0);
    assert(modes_report(&m) == 0);                        /* locked: nothing to show */
    modes_handle(&m, MODES_EV_URGENT, 0);
    assert(modes_report(&m) == 0);                        /* a request over the lock is not Claude mode */
    modes_handle(&m, MODES_EV_PWR_3, 0);
    assert(modes_report(&m) == 2);
    modes_handle(&m, MODES_EV_BOOT_1, 0);
    assert(modes_report(&m) == 0);
}
```

and add the three calls before `puts("modes: all tests passed");`:

```c
    pick_goes_to_claude_mode();
    pick_is_ignored_when_locked_or_over_a_request();
    report_follows_mode_and_lock();
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd firmware/test && cc -Wall -Werror -I../main -o /tmp/test_sessions test_sessions.c ../main/sessions.c ../main/claude_proto.c; cc -Wall -Werror -I../main -o /tmp/test_question test_question.c ../main/question.c ../main/claude_proto.c; cc -Wall -Werror -I../main -o /tmp/test_modes test_modes.c ../main/modes.c`
Expected: `sessions.h` / `question.h` not found; `MODES_EV_PICK` and `modes_report` undeclared.

- [ ] **Step 3: Session table**

Create `firmware/main/sessions.h`:

```c
/*
 * Claude sessions as the board holds them (pure C, host-tested in firmware/test/test_sessions.c).
 * The Mac sends at most 6 rows (kind 4 upserts, 5 removes, 6 clears); the table keeps up to 8 as a safety
 * margin. Order matches the Mac (SessionRow.boardOrder): "needs you" first, then most recently updated,
 * then the higher handle. On the board the table is guarded by the display lock (picker_ui.c).
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "claude_proto.h"

#define SESSIONS_MAX   8
#define SESSIONS_SHOWN 6

typedef struct {
    claude_session_t rows[SESSIONS_MAX];
    int n;
} sessions_t;

void sessions_clear(sessions_t *s);
/* Adds or replaces the row with this handle; a row carrying FOCUSED takes the flag from the others.
 * A full table drops its least relevant row. */
void sessions_upsert(sessions_t *s, const claude_session_t *row);
void sessions_remove(sessions_t *s, uint32_t handle);
/* true when a comes before b in the picker */
bool sessions_before(const claude_session_t *a, const claude_session_t *b);
/* Fills out with at most max rows in picker order; returns the count */
int sessions_sorted(const sessions_t *s, const claude_session_t **out, int max);
const claude_session_t *sessions_focused(const sessions_t *s);
/* Done events of non-focused sessions not seen yet */
int sessions_badge(const sessions_t *s);
/* Optimistic local focus after a picker tap (the Mac confirms with upserts) */
void sessions_set_focus(sessions_t *s, uint32_t handle);
/* "<1m", "12m", "2h 05m" (negative = clock skew: "<1m") */
void sessions_format_elapsed(int64_t seconds, char *out, size_t n);
const char *sessions_state_label(char state);   /* "Needs you", "Working", "Idle", "Ended" */
const char *sessions_state_short(char state);   /* "needs you", "working", "idle", "ended" */
uint32_t sessions_state_color(char state);      /* red, yellow, green, grey (0xRRGGBB) */
```

Create `firmware/main/sessions.c`:

```c
#include "sessions.h"

#include <stdio.h>
#include <string.h>

void sessions_clear(sessions_t *s)
{
    s->n = 0;
}

static int find(const sessions_t *s, uint32_t handle)
{
    for (int i = 0; i < s->n; i++) {
        if (s->rows[i].handle == handle) {
            return i;
        }
    }
    return -1;
}

bool sessions_before(const claude_session_t *a, const claude_session_t *b)
{
    bool an = a->state == CLAUDE_STATE_NEEDS_YOU, bn = b->state == CLAUDE_STATE_NEEDS_YOU;
    if (an != bn) {
        return an;
    }
    if (a->updated != b->updated) {
        return a->updated > b->updated;
    }
    return a->handle > b->handle;
}

void sessions_upsert(sessions_t *s, const claude_session_t *row)
{
    int i = find(s, row->handle);
    if (i < 0) {
        if (s->n < SESSIONS_MAX) {
            i = s->n++;
        } else {
            i = 0;   /* full: replace the row that sorts last */
            for (int j = 1; j < s->n; j++) {
                if (sessions_before(&s->rows[i], &s->rows[j])) {
                    i = j;
                }
            }
        }
    }
    s->rows[i] = *row;
    if (row->flags & CLAUDE_SESSION_FOCUSED) {
        for (int j = 0; j < s->n; j++) {
            if (j != i) {
                s->rows[j].flags &= (uint8_t)~CLAUDE_SESSION_FOCUSED;
            }
        }
    }
}

void sessions_remove(sessions_t *s, uint32_t handle)
{
    int i = find(s, handle);
    if (i >= 0) {
        s->rows[i] = s->rows[--s->n];
    }
}

int sessions_sorted(const sessions_t *s, const claude_session_t **out, int max)
{
    const claude_session_t *all[SESSIONS_MAX];
    for (int i = 0; i < s->n; i++) {
        const claude_session_t *r = &s->rows[i];
        int j = i;
        while (j > 0 && sessions_before(r, all[j - 1])) {
            all[j] = all[j - 1];
            j--;
        }
        all[j] = r;
    }
    int k = s->n < max ? s->n : max;
    for (int i = 0; i < k; i++) {
        out[i] = all[i];
    }
    return k;
}

const claude_session_t *sessions_focused(const sessions_t *s)
{
    for (int i = 0; i < s->n; i++) {
        if (s->rows[i].flags & CLAUDE_SESSION_FOCUSED) {
            return &s->rows[i];
        }
    }
    return NULL;
}

int sessions_badge(const sessions_t *s)
{
    int n = 0;
    for (int i = 0; i < s->n; i++) {
        uint8_t f = s->rows[i].flags;
        n += (f & CLAUDE_SESSION_UNSEEN) && !(f & CLAUDE_SESSION_FOCUSED);
    }
    return n;
}

void sessions_set_focus(sessions_t *s, uint32_t handle)
{
    for (int i = 0; i < s->n; i++) {
        if (s->rows[i].handle == handle) {
            s->rows[i].flags = CLAUDE_SESSION_FOCUSED;   /* focused: no longer unseen */
        } else {
            s->rows[i].flags &= (uint8_t)~CLAUDE_SESSION_FOCUSED;
        }
    }
}

void sessions_format_elapsed(int64_t seconds, char *out, size_t n)
{
    if (seconds < 60) {
        snprintf(out, n, "<1m");
    } else if (seconds < 3600) {
        snprintf(out, n, "%dm", (int)(seconds / 60));
    } else {
        snprintf(out, n, "%dh %02dm", (int)(seconds / 3600), (int)(seconds % 3600 / 60));
    }
}

const char *sessions_state_label(char state)
{
    switch (state) {
    case CLAUDE_STATE_NEEDS_YOU: return "Needs you";
    case CLAUDE_STATE_WORKING:   return "Working";
    case CLAUDE_STATE_IDLE:      return "Idle";
    case CLAUDE_STATE_ENDED:     return "Ended";
    default:                     return "";
    }
}

const char *sessions_state_short(char state)
{
    switch (state) {
    case CLAUDE_STATE_NEEDS_YOU: return "needs you";
    case CLAUDE_STATE_WORKING:   return "working";
    case CLAUDE_STATE_IDLE:      return "idle";
    case CLAUDE_STATE_ENDED:     return "ended";
    default:                     return "";
    }
}

uint32_t sessions_state_color(char state)
{
    switch (state) {
    case CLAUDE_STATE_NEEDS_YOU: return 0xe5484d;   /* red */
    case CLAUDE_STATE_WORKING:   return 0xf5c400;   /* yellow */
    case CLAUDE_STATE_IDLE:      return 0x30a46c;   /* green */
    default:                     return 0x6f6f6f;   /* grey: ended */
    }
}
```

- [ ] **Step 4: Question model**

Create `firmware/main/question.h`:

```c
/*
 * AskUserQuestion pages on the board (pure C, host-tested in firmware/test/test_question.c).
 * The Mac sends one kind-7 message per question, all with the request id; the set is shown once every
 * page is in. Single-select: a tap selects that option (tapping it again keeps it). Multi-select: a tap
 * toggles. Next needs the page answered; Send (last page) needs every page answered.
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "claude_proto.h"

typedef struct {
    uint32_t id;                      /* request id; 0 = empty */
    uint8_t count;                    /* pages expected */
    uint8_t have;                     /* bit i = page i received */
    uint8_t page;                     /* page on screen */
    uint8_t mask[CLAUDE_Q_MAX];       /* bit i = option i chosen */
    claude_question_t q[CLAUDE_Q_MAX];
} question_set_t;

void question_reset(question_set_t *s);
/* Stores one page; a page with another id (or page count) starts a new set. True when the set has just
 * become complete. */
bool question_add(question_set_t *s, uint32_t id, const claude_question_t *page);
bool question_complete(const question_set_t *s);
void question_tap(question_set_t *s, uint8_t option);
bool question_page_answered(const question_set_t *s, uint8_t page);
bool question_all_answered(const question_set_t *s);
bool question_last_page(const question_set_t *s);
void question_next(question_set_t *s);   /* only from an answered page */
void question_back(question_set_t *s);
/* The answer bytes (claude_encode_answers), or 0 until every page is answered */
size_t question_encode(const question_set_t *s, uint8_t out[CLAUDE_INPUT_MAX]);
```

Create `firmware/main/question.c`:

```c
#include "question.h"

#include <string.h>

void question_reset(question_set_t *s)
{
    memset(s, 0, sizeof(*s));
}

bool question_complete(const question_set_t *s)
{
    return s->id != 0 && s->count > 0 && s->have == (uint8_t)((1u << s->count) - 1);
}

bool question_add(question_set_t *s, uint32_t id, const claude_question_t *page)
{
    if (id == 0 || page->count == 0 || page->count > CLAUDE_Q_MAX || page->index >= page->count) {
        return false;
    }
    if (s->id != id || s->count != page->count) {
        question_reset(s);
        s->id = id;
        s->count = page->count;
    }
    bool was_complete = question_complete(s);
    s->q[page->index] = *page;
    s->have |= (uint8_t)(1u << page->index);
    return !was_complete && question_complete(s);
}

void question_tap(question_set_t *s, uint8_t option)
{
    if (!question_complete(s) || s->page >= s->count) {
        return;
    }
    const claude_question_t *q = &s->q[s->page];
    if (option >= q->nopt) {
        return;
    }
    uint8_t bit = (uint8_t)(1u << option);
    if (q->multi) {
        s->mask[s->page] ^= bit;
    } else {
        s->mask[s->page] = bit;
    }
}

bool question_page_answered(const question_set_t *s, uint8_t page)
{
    return page < s->count && s->mask[page] != 0;
}

bool question_all_answered(const question_set_t *s)
{
    if (!question_complete(s)) {
        return false;
    }
    for (uint8_t i = 0; i < s->count; i++) {
        if (s->mask[i] == 0) {
            return false;
        }
    }
    return true;
}

bool question_last_page(const question_set_t *s)
{
    return s->page + 1 >= s->count;
}

void question_next(question_set_t *s)
{
    if (!question_last_page(s) && question_page_answered(s, s->page)) {
        s->page++;
    }
}

void question_back(question_set_t *s)
{
    if (s->page > 0) {
        s->page--;
    }
}

size_t question_encode(const question_set_t *s, uint8_t out[CLAUDE_INPUT_MAX])
{
    if (!question_all_answered(s)) {
        return 0;
    }
    return claude_encode_answers(s->id, s->mask, s->count, out);
}
```

- [ ] **Step 5: Picker event and mode report**

In `firmware/main/modes.h`, replace

```c
    MODES_EV_URGENT_DONE,  /* that request was answered, cancelled or dropped */
} modes_event_t;
```

with

```c
    MODES_EV_URGENT_DONE,  /* that request was answered, cancelled or dropped */
    MODES_EV_PICK,         /* a session was tapped in the picker: Claude mode */
} modes_event_t;
```

and add after the `modes_face_visible` declaration:

```c
/* What the board shows, for the Mac (claude_proto.h CLAUDE_BOARD_*): 0 other (translator, or locked),
 * 1 Claude mode, 2 picker. Session rows are pushed only while this is 1 or 2. */
int modes_report(const modes_t *m);
```

In `firmware/main/modes.c`, in `modes_handle` replace

```c
    case MODES_EV_URGENT_DONE:
        m->urgent = false;
        m->pending = false;
        return false;
    }
```

with

```c
    case MODES_EV_URGENT_DONE:
        m->urgent = false;
        m->pending = false;
        return false;
    case MODES_EV_PICK:
        if (m->locked || m->urgent) {
            return false;   /* the picker is not on screen then */
        }
        m->mode = BOARD_CLAUDE;
        return true;
    }
```

and append:

```c
int modes_report(const modes_t *m)
{
    if (m->locked) {
        return 0;
    }
    switch (m->mode) {
    case BOARD_CLAUDE:
        return 1;
    case BOARD_PICKER:
        return 2;
    default:
        return 0;
    }
}
```

In `firmware/main/shell.c`, replace the event-name table and its assertion with:

```c
static const char *const EV_NAMES[] = {
    "PWR x1", "PWR x2", "PWR x3", "BOOT x1", "tap x1", "tap x2", "Claude request", "Claude request done",
    "session picked",
};
_Static_assert(sizeof EV_NAMES / sizeof EV_NAMES[0] == MODES_EV_PICK + 1, "EV_NAMES out of sync");
```

In `firmware/main/CMakeLists.txt`, add `"sessions.c" "question.c"` after `"claude_proto.c"` in `SRCS`.

- [ ] **Step 6: Run the host tests to verify they pass**

Run each and expect its line:
- `cd firmware/test && cc -Wall -Werror -I../main -o /tmp/test_sessions test_sessions.c ../main/sessions.c ../main/claude_proto.c && /tmp/test_sessions` → `sessions: all tests passed`
- `cd firmware/test && cc -Wall -Werror -I../main -o /tmp/test_question test_question.c ../main/question.c ../main/claude_proto.c && /tmp/test_question` → `question: all tests passed`
- `cd firmware/test && cc -Wall -Werror -I../main -o /tmp/test_modes test_modes.c ../main/modes.c && /tmp/test_modes` → `modes: all tests passed`
- `cd firmware/test && cc -Wall -Werror -I../main -o /tmp/test_claude_proto test_claude_proto.c ../main/claude_proto.c && /tmp/test_claude_proto` → `claude_proto: all tests passed`

- [ ] **Step 7: Build the firmware**

Run: `. ~/esp/esp-idf/export.sh && cd firmware && idf.py build 2>&1 | tail -3`
Expected: `Project build complete.`

- [ ] **Step 8: Commit**

```bash
git add firmware/main/sessions.h firmware/main/sessions.c firmware/main/question.h firmware/main/question.c \
        firmware/main/modes.h firmware/main/modes.c firmware/main/shell.c firmware/main/CMakeLists.txt \
        firmware/test/test_sessions.c firmware/test/test_question.c firmware/test/test_modes.c
git commit -F - <<'EOF'
firmware: session table, question pages model, picker event and mode report (host-tested)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---
### Task 10: Firmware — session picker, session view on the Claude screen, Always allow, mode and focus reports

**Files:**
- Rewrite: `firmware/main/picker_ui.c`
- Rewrite: `firmware/main/claude_ui.c`
- Modify: `firmware/main/app.h`, `firmware/main/main.c` (`app_on_claude_link`, `app_on_claude_message`), `firmware/main/ble_link.c` (comment, answer notify), `firmware/main/shell.c` (mode report), `firmware/main/clock.h`, `firmware/main/clock_rtc.c`
- Create: `firmware/test/claude_ble_phase2.py` (fake Mac for the on-device checks)

**Interfaces:**
- Consumes: `sessions_*` (Task 9), `claude_parse_session`, `claude_split_lines`, `claude_encode_mode/focus`, `CLAUDE_DECISION_*` (Task 8), `MODES_EV_PICK`, `modes_report` (Task 9).
- Produces (used by Task 11):
  - `bool ble_link_send_claude_input(const uint8_t *data, size_t len);` (any board → Mac bytes, ≤ `CLAUDE_INPUT_MAX`)
  - `bool claude_ui_on_message(const claude_msg_t *m);` (true: a request is ready to take over the screen)
  - `void claude_ui_refresh_session_locked(void);`, `void claude_ui_note_press(void);`, `bool claude_ui_tap_allowed(void);`, `void claude_ui_rearm(void);`
  - `void picker_ui_on_message(const claude_msg_t *m);`, `void picker_ui_set_link(bool connected);`, `void picker_ui_set_touch_enabled(bool on);`, `const claude_session_t *picker_ui_focused_locked(void);`, `int picker_ui_badge_locked(void);`
  - `void shell_resend_mode(void);`
  - `bool clock_now_unix(int64_t *out);` (false until a time was received)
  - Static helpers inside `claude_ui.c` that Task 11 uses by name: `show_idle`, `set_buttons`, `arm_buttons`, `schedule_restore`, `start_cap` (the existing 100 s board-side cap), `s_restore_timer`, `s_pending_id`, `s_always_offered`.

No host test can drive LVGL; this task's logic lives in the host-tested `sessions.c` / `modes.c` / `claude_proto.c`, and the wiring is checked on the device with a fake Mac (Step 9).

- [ ] **Step 1: Declarations**

In `firmware/main/app.h`:

Replace `bool ble_link_send_claude_answer(uint32_t id, uint8_t decision);   /* 1 allow, 2 deny */` with

```c
bool ble_link_send_claude_answer(uint32_t id, uint8_t decision);   /* CLAUDE_DECISION_* */
/* Any board -> Mac bytes (claude_proto.h encoders), at most CLAUDE_INPUT_MAX; false if no Mac */
bool ble_link_send_claude_input(const uint8_t *data, size_t len);
```

Replace the `/* claude_ui.c: Claude companion screen */` block (its 7 lines, down to `bool claude_ui_pending(void); …`) with:

```c
/* claude_ui.c: Claude companion screen */
void claude_ui_init(void);
lv_obj_t *claude_ui_screen(void);
/* Copies the text; takes the display lock. True when a request is now ready to show (take over the screen). */
bool claude_ui_on_message(const claude_msg_t *m);
void claude_ui_set_link(bool connected);
void claude_ui_set_touch_enabled(bool on);          /* LVGL task: answers ignore taps while the panel is dark */
bool claude_ui_pending(void);                       /* a request awaits an answer */
void claude_ui_refresh_session_locked(void);        /* display lock held: status badge + focused session view */
/* Every answer control (claude_ui.c, question_ui.c), LVGL task */
void claude_ui_note_press(void);                    /* call from LV_EVENT_PRESSED */
bool claude_ui_tap_allowed(void);                   /* request pending, panel lit, press armed (dark: wakes) */
void claude_ui_rearm(void);                         /* new controls under the finger (page change) */
```

and replace the three lines `/* picker_ui.c: Claude session picker (Phase 1: placeholder) */`, `void picker_ui_init(void);`, `lv_obj_t *picker_ui_screen(void);` with:

```c
/* picker_ui.c: Claude session picker; owns the session table */
void picker_ui_init(void);
lv_obj_t *picker_ui_screen(void);
void picker_ui_on_message(const claude_msg_t *m);   /* kinds 4-6; takes the display lock */
void picker_ui_set_link(bool connected);            /* takes the display lock; a lost link clears the rows */
void picker_ui_set_touch_enabled(bool on);          /* LVGL task */
const claude_session_t *picker_ui_focused_locked(void);
int picker_ui_badge_locked(void);
```

Replace `void shell_snapshot(modes_t *out);                  /* current state, for the panel policy */` with

```c
void shell_snapshot(modes_t *out);                  /* current state, for the panel policy */
void shell_resend_mode(void);                       /* tell the Mac the board mode again (Mac link up) */
```

In `firmware/main/clock.h`, append:

```c
/* Device: the current Unix time; false until a time has been received (or if it is implausible). */
bool clock_now_unix(int64_t *out);
```

In `firmware/main/clock_rtc.c`, append:

```c
bool clock_now_unix(int64_t *out)
{
    if (!s_known) {
        return false;
    }
    struct timeval tv;
    gettimeofday(&tv, NULL);
    if (!clock_plausible((int64_t)tv.tv_sec)) {
        return false;
    }
    *out = (int64_t)tv.tv_sec;
    return true;
}
```

- [ ] **Step 2: Board → Mac notify for any input**

In `firmware/main/ble_link.c`, replace the comment

```c
/* Claude companion service (the Mac). Requests: [flags u8][kind u8][id u32 LE][UTF-8], flags as the text chr.
 * Answers (notify): [id u32 LE][decision u8: 1 allow, 2 deny] */
```

with

```c
/* Claude companion service (the Mac). Requests: [flags u8][kind u8][id u32 LE][UTF-8], flags as the text chr.
 * Answers (notify): answers, board mode and focus, at most CLAUDE_INPUT_MAX bytes (see claude_proto.h) */
```

and replace the whole `ble_link_send_claude_answer` function with:

```c
bool ble_link_send_claude_input(const uint8_t *data, size_t len)
{
    uint16_t conn = s_mac_conn;
    if (conn == BLE_HS_CONN_HANDLE_NONE || len == 0 || len > CLAUDE_INPUT_MAX) {
        return false;
    }
    struct os_mbuf *om = ble_hs_mbuf_from_flat(data, (uint16_t)len);
    return om && ble_gatts_notify_custom(conn, s_claude_ans_handle, om) == 0;
}

bool ble_link_send_claude_answer(uint32_t id, uint8_t decision)
{
    uint8_t payload[5];
    claude_encode_answer(id, decision, payload);
    return ble_link_send_claude_input(payload, sizeof(payload));
}
```

- [ ] **Step 3: The shell tells the Mac what the board shows**

In `firmware/main/shell.c`, after the `EV_NAMES` assertion add:

```c
_Static_assert(CLAUDE_BOARD_OTHER == 0 && CLAUDE_BOARD_CLAUDE == 1 && CLAUDE_BOARD_PICKER == 2,
               "modes_report() returns CLAUDE_BOARD_* values");

/* Last board mode the Mac was told; -1 = tell it again. Session rows flow only while it is Claude or picker. */
static volatile int s_reported = -1;

static void report_mode(const modes_t *m)
{
    int r = modes_report(m);
    if (r == s_reported) {
        return;
    }
    uint8_t buf[CLAUDE_INPUT_MAX];
    size_t n = claude_encode_mode((uint8_t)r, buf);
    if (ble_link_send_claude_input(buf, n)) {   /* no Mac: shell_resend_mode() runs when it subscribes */
        s_reported = r;
        ESP_LOGI(TAG, "told the Mac: board mode %d", r);
    }
}

void shell_resend_mode(void)
{
    modes_t m;
    shell_snapshot(&m);
    s_reported = -1;
    report_mode(&m);
}
```

and in `shell_task`, replace

```c
        if (wake && !shutting_down) {
            ui_force_screen_on();
        }
    }
```

with

```c
        if (wake && !shutting_down) {
            ui_force_screen_on();
        }
        report_mode(&next);
    }
```

- [ ] **Step 4: Session picker**

Replace `firmware/main/picker_ui.c` with:

```c
/*
 * Session picker (PWR x3): up to 6 Claude Code sessions from the Mac, "needs you" first, then the most
 * recent. Row: coloured dot (red needs you, yellow working, green idle, grey ended), project (+ "· new" when
 * its turn ended while another session was focused), short state; the focused one has a white outline.
 * Tap a row: focus it (the Mac is told) and go to the Claude screen.
 * The session table (sessions.c) also feeds the Claude screen. It is written from the NimBLE host task and
 * read from the LVGL task, both only under the display lock (functions named *_locked expect it held).
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "lvgl.h"

#include "app.h"
#include "sessions.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

static const char *TAG = "picker_ui";

#define ROW_W 300
#define ROW_H 44

static lv_obj_t *s_scr;
static lv_obj_t *s_list;
static lv_obj_t *s_empty;
static lv_obj_t *s_hint;
static sessions_t s_sessions;
static uint32_t s_row_handle[SESSIONS_SHOWN];
static bool s_touch_on = true;
static bool s_link;

static lv_obj_t *make_label(lv_obj_t *parent, const lv_font_t *font, uint32_t color, int width)
{
    lv_obj_t *l = lv_label_create(parent);
    lv_obj_set_width(l, width);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_DOTS);
    return l;
}

/* LVGL task: a tap on the dark panel ends a manual screen-off (PWR hold on USB) */
static void on_tap(lv_event_t *e)
{
    ui_wake_from_tap();
}

/* LVGL task, lock held. Never rebuilds the list here: this row is running its own event. */
static void on_row(lv_event_t *e)
{
    if (!s_touch_on) {
        ui_wake_from_tap();   /* a tap on a dark panel only wakes it */
        return;
    }
    uint32_t handle = s_row_handle[(int)(intptr_t)lv_event_get_user_data(e)];
    if (handle == 0) {
        return;
    }
    sessions_set_focus(&s_sessions, handle);
    uint8_t buf[CLAUDE_INPUT_MAX];
    size_t n = claude_encode_focus(handle, buf);
    if (!ble_link_send_claude_input(buf, n)) {
        ESP_LOGW(TAG, "focus %lu not sent (Mac not connected)", (unsigned long)handle);
    }
    claude_ui_refresh_session_locked();
    shell_post(MODES_EV_PICK);
}

static void rebuild_locked(void)
{
    lv_obj_clean(s_list);
    memset(s_row_handle, 0, sizeof(s_row_handle));
    const claude_session_t *rows[SESSIONS_SHOWN];
    int n = sessions_sorted(&s_sessions, rows, SESSIONS_SHOWN);
    lv_label_set_text(s_empty, s_link ? "No sessions yet" : "Mac not connected");
    lv_obj_set_hidden(s_empty, n > 0);
    lv_obj_set_hidden(s_hint, n > 0);
    for (int i = 0; i < n; i++) {
        const claude_session_t *r = rows[i];
        s_row_handle[i] = r->handle;

        lv_obj_t *row = lv_obj_create(s_list);
        lv_obj_set_size(row, ROW_W, ROW_H);
        lv_obj_set_style_radius(row, ROW_H / 2, 0);
        lv_obj_set_style_bg_color(row, lv_color_hex(0x1a1a1a), 0);
        lv_obj_set_style_bg_opa(row, LV_OPA_COVER, 0);
        lv_obj_set_style_border_color(row, lv_color_white(), 0);
        lv_obj_set_style_border_width(row, (r->flags & CLAUDE_SESSION_FOCUSED) ? 2 : 0, 0);
        lv_obj_set_style_pad_all(row, 0, 0);
        lv_obj_set_scrollable(row, false);
        lv_obj_add_event_cb(row, on_row, LV_EVENT_CLICKED, (void *)(intptr_t)i);

        lv_obj_t *dot = lv_obj_create(row);
        lv_obj_set_size(dot, 16, 16);
        lv_obj_set_style_radius(dot, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_border_width(dot, 0, 0);
        lv_obj_set_style_bg_color(dot, lv_color_hex(sessions_state_color(r->state)), 0);
        lv_obj_set_style_bg_opa(dot, LV_OPA_COVER, 0);
        lv_obj_set_clickable(dot, false);   /* the tap goes to the row */
        lv_obj_set_scrollable(dot, false);
        lv_obj_align(dot, LV_ALIGN_LEFT_MID, 16, 0);

        char name[CLAUDE_PROJECT_MAX + 16];
        snprintf(name, sizeof(name), "%s%s", r->project, (r->flags & CLAUDE_SESSION_UNSEEN) ? " · new" : "");
        lv_obj_t *label = make_label(row, &font_vi_22, 0xffffff, 150);
        lv_label_set_text(label, name);
        lv_obj_align(label, LV_ALIGN_LEFT_MID, 42, 0);

        lv_obj_t *state = make_label(row, &font_vi_22, 0x9a9a9a, 100);
        lv_obj_set_style_text_align(state, LV_TEXT_ALIGN_RIGHT, 0);
        lv_label_set_text(state, sessions_state_short(r->state));
        lv_obj_align(state, LV_ALIGN_RIGHT_MID, -16, 0);
    }
}

void picker_ui_init(void)
{
    bsp_display_lock((uint32_t)-1);
    s_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_scr, lv_color_black(), 0);
    lv_obj_set_scrollable(s_scr, false);
    lv_obj_add_event_cb(s_scr, on_tap, LV_EVENT_CLICKED, NULL);

    lv_obj_t *title = make_label(s_scr, &font_vi_22, 0xc8c8c8, 300);
    lv_obj_set_style_text_align(title, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_text(title, "Claude sessions");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 48);

    /* 6 rows of 44 px with 6 px gaps: y 90..384, full row width fits the round panel there */
    s_list = lv_obj_create(s_scr);
    lv_obj_set_size(s_list, ROW_W + 10, 300);
    lv_obj_align(s_list, LV_ALIGN_TOP_MID, 0, 90);
    lv_obj_set_style_bg_opa(s_list, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_list, 0, 0);
    lv_obj_set_style_pad_all(s_list, 0, 0);
    lv_obj_set_style_pad_row(s_list, 6, 0);
    lv_obj_set_flex_flow(s_list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(s_list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_scrollable(s_list, false);

    s_empty = make_label(s_scr, &font_vi_36, 0xffffff, 360);
    lv_obj_set_style_text_align(s_empty, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(s_empty, LV_ALIGN_TOP_MID, 0, 190);
    s_hint = make_label(s_scr, &font_vi_22, 0x9a9a9a, 360);
    lv_label_set_long_mode(s_hint, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_set_style_text_align(s_hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_text(s_hint, "Sessions from your Mac\nwill appear here.");
    lv_obj_align(s_hint, LV_ALIGN_TOP_MID, 0, 250);

    rebuild_locked();
    bsp_display_unlock();
}

lv_obj_t *picker_ui_screen(void)
{
    return s_scr;
}

void picker_ui_on_message(const claude_msg_t *m)
{
    static claude_session_t row;   /* NimBLE host task only: kept off its 4 KB stack */
    if (m->kind == CLAUDE_SESSION && !claude_parse_session(m, &row)) {
        ESP_LOGW(TAG, "ignoring bad session row %lu", (unsigned long)m->id);
        return;
    }
    bsp_display_lock((uint32_t)-1);
    if (m->kind == CLAUDE_SESSION) {
        sessions_upsert(&s_sessions, &row);
    } else if (m->kind == CLAUDE_SESSION_REMOVE) {
        sessions_remove(&s_sessions, m->id);
    } else if (m->kind == CLAUDE_SESSIONS_CLEAR) {
        sessions_clear(&s_sessions);
    }
    rebuild_locked();
    claude_ui_refresh_session_locked();
    bsp_display_unlock();
}

void picker_ui_set_link(bool connected)
{
    bsp_display_lock((uint32_t)-1);
    s_link = connected;
    if (!connected) {
        sessions_clear(&s_sessions);   /* stale without the Mac; a full sync follows the next activation */
    }
    rebuild_locked();
    claude_ui_refresh_session_locked();
    bsp_display_unlock();
}

void picker_ui_set_touch_enabled(bool on)
{
    s_touch_on = on;
}

const claude_session_t *picker_ui_focused_locked(void)
{
    return sessions_focused(&s_sessions);
}

int picker_ui_badge_locked(void)
{
    return sessions_badge(&s_sessions);
}
```

- [ ] **Step 5: Claude screen: session view, badge, Always allow**

Replace `firmware/main/claude_ui.c` with:

```c
/*
 * Claude companion screen:
 *   top    : "Claude · Mac connected", "Claude · N new" (done events of other sessions not seen yet),
 *            or "Claude · Mac not connected"
 *   middle : the focused session (project, "State · elapsed", last assistant line), or the request asked
 *   bottom : Deny / Allow, and Always allow when the Mac offers a rule, while a permission request is pending
 * Requests arrive one at a time from the Mac (the daemon queues the rest).
 * Which screen is shown belongs to shell.c: a request takes over the screen there (MODES_EV_URGENT, posted
 * by main.c); once it is answered, cancelled, timed out or the Mac link drops, this file posts
 * MODES_EV_URGENT_DONE after a short look at the result, and the shell restores the mode (or the lock).
 * If the user leaves a shown request (BOOT x1, PWR x1/x2/x3), it stays pending here and on the Mac; the
 * Claude screen shows it again (controls re-armed) until it is answered, cancelled or the Mac drops, and
 * unlocking (PWR x1, lock-screen double tap) brings it back on top (modes.c).
 * A request with no answer or cancel REQUEST_CAP_MS after it arrived is dropped here as if cancelled (the
 * Mac gives up at 90 s and sends a cancel; this covers a lost cancel).
 * Session rows live in picker_ui.c (sessions.c table); this screen shows the focused one.
 */
#include <stdio.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lvgl.h"

#include "app.h"
#include "clock.h"
#include "sessions.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

static const char *TAG = "claude_ui";

static lv_obj_t *s_scr;
static lv_obj_t *s_status;
static lv_obj_t *s_project;
static lv_obj_t *s_title;
static lv_obj_t *s_detail;
static lv_obj_t *s_allow;
static lv_obj_t *s_deny;
static lv_obj_t *s_always;
static volatile uint32_t s_pending_id;   /* 0 = none */
static bool s_always_offered;            /* the pending permission carries a rule */
static bool s_touch_on = true;           /* false while the panel is dark */
static bool s_link;

/* Answer controls go live only ARM_DELAY_US after a request is shown, a page changes or the panel turns on,
 * and only for a press that began after that: a tap aimed at something else (or at a dark panel) never
 * answers an unread request. */
#define ARM_DELAY_US (700 * 1000)
static int64_t s_armed_at_us;
static int64_t s_press_started_us;

/* How long the result ("Allowed", "Denied", ...) stays up before the shell restores the previous screen */
#define RESTORE_DELAY_MS 1200
static lv_timer_t *s_restore_timer;

/* Board-side cap on a shown request: dropped as "Timed out" if neither an answer nor a cancel came */
#define REQUEST_CAP_MS 100000
static lv_timer_t *s_cap_timer;

/* Elapsed time on the session view: refreshed only while this screen is loaded, skipped while dark */
#define ELAPSED_REFRESH_MS 30000
static lv_timer_t *s_elapsed_timer;

static void arm_buttons(void)
{
    s_armed_at_us = esp_timer_get_time() + ARM_DELAY_US;
}

static void restore_cb(lv_timer_t *t)
{
    s_restore_timer = NULL;
    /* A new request arrived meanwhile: stay, it will restore when it is done */
    if (s_pending_id != 0) {
        return;
    }
    claude_ui_refresh_session_locked();   /* the result goes away: back to the session view */
    shell_post(MODES_EV_URGENT_DONE);
}

/* LVGL lock held. Hands the screen back to the shell after a short look at the result. */
static void schedule_restore(void)
{
    if (s_restore_timer) {
        lv_timer_delete(s_restore_timer);
    }
    s_restore_timer = lv_timer_create(restore_cb, RESTORE_DELAY_MS, NULL);
    lv_timer_set_repeat_count(s_restore_timer, 1);
}

static void set_buttons(bool visible)
{
    lv_obj_set_hidden(s_allow, !visible);
    lv_obj_set_hidden(s_deny, !visible);
    lv_obj_set_hidden(s_always, !(visible && s_always_offered));
}

/* Info or result view: no request pending */
static void show_idle(const char *title, const char *detail)
{
    s_pending_id = 0;
    s_always_offered = false;
    if (s_cap_timer) {
        lv_timer_delete(s_cap_timer);
        s_cap_timer = NULL;
    }
    set_buttons(false);
    lv_label_set_text(s_project, "");
    lv_label_set_text(s_title, title);
    lv_label_set_text(s_detail, detail);
}

/* LVGL timer, lock held: no answer and no cancel for REQUEST_CAP_MS. Drop it like a cancel. */
static void cap_cb(lv_timer_t *t)
{
    s_cap_timer = NULL;   /* one-shot: LVGL deletes it after this call */
    if (s_pending_id == 0) {
        return;
    }
    ESP_LOGW(TAG, "request %lu: no answer or cancel after %d s, dropping it", (unsigned long)s_pending_id,
             REQUEST_CAP_MS / 1000);
    show_idle("Timed out", "Answer in the terminal.");
    schedule_restore();
}

/* Lock held: a request was just shown */
static void start_cap(void)
{
    if (s_cap_timer) {
        lv_timer_delete(s_cap_timer);
    }
    s_cap_timer = lv_timer_create(cap_cb, REQUEST_CAP_MS, NULL);
    lv_timer_set_repeat_count(s_cap_timer, 1);
}

static void refresh_status(void)
{
    char status[48];
    int badge = picker_ui_badge_locked();
    if (!s_link) {
        snprintf(status, sizeof(status), "Claude · Mac not connected");
    } else if (badge > 0) {
        snprintf(status, sizeof(status), "Claude · %d new", badge);
    } else {
        snprintf(status, sizeof(status), "Claude · Mac connected");
    }
    lv_label_set_text(s_status, status);
}

void claude_ui_refresh_session_locked(void)
{
    if (s_scr == NULL) {
        return;
    }
    refresh_status();
    if (s_pending_id != 0 || s_restore_timer != NULL) {
        return;   /* a request, or its result, is on screen */
    }
    if (!s_link) {
        show_idle("No requests", "Mac not connected.");
        return;
    }
    const claude_session_t *f = picker_ui_focused_locked();
    if (f == NULL) {
        show_idle("No session", "PWR x3 to pick a session.");
        return;
    }
    char title[48];
    int64_t now;
    if (clock_now_unix(&now)) {
        char elapsed[16];
        sessions_format_elapsed(now - f->since, elapsed, sizeof(elapsed));
        snprintf(title, sizeof(title), "%s · %s", sessions_state_label(f->state), elapsed);
    } else {
        snprintf(title, sizeof(title), "%s", sessions_state_label(f->state));
    }
    show_idle(title, f->line);
    lv_label_set_text(s_project, f->project);
}

static void elapsed_cb(lv_timer_t *t)
{
    if (s_touch_on) {
        claude_ui_refresh_session_locked();
    }
}

/* Runs inside lv_screen_load, i.e. in the shell task with the display lock held: the Claude screen came back
 * (PWR x2, a takeover, an unlock). A request left pending meanwhile must be read again before it takes a tap. */
static void on_screen_loaded(lv_event_t *e)
{
    arm_buttons();
    claude_ui_refresh_session_locked();
    if (s_elapsed_timer == NULL) {
        s_elapsed_timer = lv_timer_create(elapsed_cb, ELAPSED_REFRESH_MS, NULL);
    }
}

static void on_screen_unloaded(lv_event_t *e)
{
    if (s_elapsed_timer) {
        lv_timer_delete(s_elapsed_timer);
        s_elapsed_timer = NULL;
    }
}

/* Runs in the LVGL task (lock already held). A tap on the dark panel (the answer buttons are not clickable
 * then, so it lands here) ends a manual screen-off; the controls re-arm when the panel turns on. */
static void on_screen_tap(lv_event_t *e)
{
    ui_wake_from_tap();
}

void claude_ui_note_press(void)
{
    s_press_started_us = esp_timer_get_time();
}

bool claude_ui_tap_allowed(void)
{
    /* A tap on a dark panel only wakes it; it must never answer blind */
    if (!s_touch_on) {
        ui_wake_from_tap();
        return false;
    }
    if (s_pending_id == 0) {
        return false;
    }
    /* Pressed before the controls were armed (request just appeared, page changed, panel just woke) */
    if (s_press_started_us < s_armed_at_us) {
        ESP_LOGI(TAG, "ignoring tap that began before the answer controls were armed");
        return false;
    }
    return true;
}

void claude_ui_rearm(void)
{
    arm_buttons();
}

/* Runs in the LVGL task (lock already held) */
static void on_press(lv_event_t *e)
{
    claude_ui_note_press();
}

/* Runs in the LVGL task (lock already held) */
static void on_answer(lv_event_t *e)
{
    uint8_t decision = (uint8_t)(uintptr_t)lv_event_get_user_data(e);
    if (!claude_ui_tap_allowed()) {
        return;
    }
    if (decision == CLAUDE_DECISION_ALWAYS && !s_always_offered) {
        return;
    }
    bool sent = ble_link_send_claude_answer(s_pending_id, decision);
    const char *result = decision == CLAUDE_DECISION_ALLOW    ? "Allowed"
                         : decision == CLAUDE_DECISION_ALWAYS ? "Always allowed"
                                                              : "Denied";
    ESP_LOGI(TAG, "%s for %lu (%s)", result, (unsigned long)s_pending_id, sent ? "sent" : "NOT sent");
    show_idle(result, sent ? "Claude continues." : "Not sent — answer in the terminal");
    schedule_restore();
}

static lv_obj_t *make_button(const char *text, uint32_t color, int width, int x, int y_from_bottom, uint8_t decision)
{
    lv_obj_t *b = lv_button_create(s_scr);
    lv_obj_set_size(b, width, 56);
    lv_obj_align(b, LV_ALIGN_BOTTOM_MID, x, y_from_bottom);
    lv_obj_set_style_radius(b, 28, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(color), 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_add_event_cb(b, on_press, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(b, on_answer, LV_EVENT_CLICKED, (void *)(uintptr_t)decision);
    lv_obj_t *l = lv_label_create(b);
    lv_obj_set_style_text_font(l, &font_vi_22, 0);
    lv_obj_set_style_text_color(l, lv_color_white(), 0);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    return b;
}

static lv_obj_t *make_label(const lv_font_t *font, uint32_t color, int width, int y)
{
    lv_obj_t *l = lv_label_create(s_scr);
    lv_obj_set_width(l, width);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_align(l, LV_ALIGN_TOP_MID, 0, y);
    return l;
}

void claude_ui_init(void)
{
    bsp_display_lock((uint32_t)-1);
    s_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_scr, lv_color_black(), 0);
    lv_obj_set_scrollable(s_scr, false);
    lv_obj_add_event_cb(s_scr, on_screen_loaded, LV_EVENT_SCREEN_LOADED, NULL);
    lv_obj_add_event_cb(s_scr, on_screen_unloaded, LV_EVENT_SCREEN_UNLOADED, NULL);
    lv_obj_add_event_cb(s_scr, on_screen_tap, LV_EVENT_CLICKED, NULL);

    s_status = make_label(&font_vi_22, 0xc8c8c8, 300, 48);
    s_project = make_label(&font_vi_22, 0x9a9a9a, 360, 86);
    s_title = make_label(&font_vi_36, 0xffffff, 380, 116);
    s_detail = make_label(&font_vi_22, 0xffffff, 380, 166);
    lv_obj_set_height(s_detail, 96);
    lv_label_set_long_mode(s_detail, LV_LABEL_LONG_MODE_DOTS);

    /* Deny / Allow at y 270..326; Always allow below at y 336..392. Any tap that began before the request
     * was shown (e.g. aimed at the translator's Mic button) is ignored by the arming. */
    s_deny = make_button("Deny", 0x8a1c1c, 150, -80, -140, CLAUDE_DECISION_DENY);
    s_allow = make_button("Allow", 0x1f9d55, 150, 80, -140, CLAUDE_DECISION_ALLOW);
    s_always = make_button("Always allow", 0x1f5f8b, 220, 0, -74, CLAUDE_DECISION_ALWAYS);

    show_idle("No requests", "Mac not connected.");
    refresh_status();
    bsp_display_unlock();
}

lv_obj_t *claude_ui_screen(void)
{
    return s_scr;
}

void claude_ui_set_link(bool connected)
{
    bsp_display_lock((uint32_t)-1);
    s_link = connected;
    if (!connected && s_pending_id) {
        show_idle("No requests", "Mac disconnected.\nAnswer in the terminal.");
        schedule_restore();
    }
    claude_ui_refresh_session_locked();
    bsp_display_unlock();
}

bool claude_ui_on_message(const claude_msg_t *m)
{
    /* NimBLE host task only: static, kept off its 4 KB stack */
    static char text[CLAUDE_TEXT_MAX + 1];
    static char detail[CLAUDE_TEXT_MAX + 16];
    snprintf(text, sizeof(text), "%s", m->text);
    /* permission: "project\ntool\nsummary[\nrule]" */
    char *f[4];
    size_t nf = claude_split_lines(text, f, 4);
    bool show = false;

    bsp_display_lock((uint32_t)-1);
    switch (m->kind) {
    case CLAUDE_PERMISSION:
        if (s_restore_timer) {   /* the previous result was still on screen: this request replaces it */
            lv_timer_delete(s_restore_timer);
            s_restore_timer = NULL;
        }
        s_pending_id = m->id;
        s_always_offered = nf >= 4 && f[3][0] != '\0';
        lv_label_set_text(s_project, f[0]);
        lv_label_set_text(s_title, nf >= 2 ? f[1] : "Permission");
        if (s_always_offered) {
            snprintf(detail, sizeof(detail), "%s\nRule: %s", nf >= 3 ? f[2] : "", f[3]);
            lv_label_set_text(s_detail, detail);
        } else {
            lv_label_set_text(s_detail, nf >= 3 ? f[2] : "");
        }
        set_buttons(true);
        arm_buttons();
        start_cap();
        show = true;
        break;
    case CLAUDE_CANCEL:
        if (m->id == s_pending_id) {
            show_idle("No requests", "Answered in the terminal\nor timed out.");
            schedule_restore();
        }
        break;
    default:
        /* finished: main.c chimes and toasts, the session view shows the line; sessions: picker_ui.c */
        break;
    }
    bsp_display_unlock();
    return show;
}

/* Runs in the LVGL task (screen timer) when the panel turns on/off */
void claude_ui_set_touch_enabled(bool on)
{
    s_touch_on = on;
    picker_ui_set_touch_enabled(on);
    if (s_scr == NULL) {
        return;
    }
    if (on) {
        arm_buttons();   /* the request may have been unread while the panel was dark */
        if (lv_screen_active() == s_scr) {
            claude_ui_refresh_session_locked();   /* elapsed time may be stale */
        }
    }
    /* Not clickable: the tap falls through to the screen object and wakes the panel */
    lv_obj_set_clickable(s_allow, on);
    lv_obj_set_clickable(s_deny, on);
    lv_obj_set_clickable(s_always, on);
}

bool claude_ui_pending(void)
{
    return s_pending_id != 0;
}
```

- [ ] **Step 6: Dispatch the new kinds**

In `firmware/main/main.c`, replace the whole `app_on_claude_link` function with:

```c
void app_on_claude_link(bool connected)
{
    s_claude_link = connected;
    if (!connected && !s_connected) {
        s_disconnected_since = esp_timer_get_time();
    }
    ESP_LOGI(TAG, "Claude link %s", connected ? "up" : "down");
    claude_ui_set_link(connected);
    picker_ui_set_link(connected);
    if (connected) {
        shell_resend_mode();   /* the Mac pushes session rows only while the board shows Claude or the picker */
    }
    ui_mark_activity();
}
```

and the whole `app_on_claude_message` function with:

```c
/* msg points to a static buffer overwritten by the next BLE write: consume it synchronously */
void app_on_claude_message(const claude_msg_t *msg)
{
    ESP_LOGI(TAG, "claude msg kind=%d id=%lu", msg->kind, (unsigned long)msg->id);
    switch (msg->kind) {
    case CLAUDE_PERMISSION:
    case CLAUDE_QUESTION:
        if (claude_ui_on_message(msg)) {
            shell_post(MODES_EV_URGENT);   /* takes over the screen (even when locked) and wakes the panel */
            chime_play(CHIME_REQUEST);
        }
        break;
    case CLAUDE_FINISHED: {
        /* The focused session finished a turn: "<project> · <last line>". Host task only: static buffer. */
        static char toast[CLAUDE_TEXT_MAX + 8];
        const char *nl = strchr(msg->text, '\n');
        int project_len = nl ? (int)(nl - msg->text) : (int)strlen(msg->text);
        snprintf(toast, sizeof(toast), "%.*s · %s", project_len, msg->text, nl ? nl + 1 : "");
        ui_toast(toast, 3000);
        chime_play(CHIME_DONE);
        break;
    }
    case CLAUDE_CANCEL:
        claude_ui_on_message(msg);
        break;
    case CLAUDE_TIME:
        clock_sync_text(msg->text);
        break;
    case CLAUDE_SESSION:
    case CLAUDE_SESSION_REMOVE:
    case CLAUDE_SESSIONS_CLEAR:
        picker_ui_on_message(msg);
        break;
    default:
        ESP_LOGW(TAG, "ignoring unknown claude kind %d", msg->kind);
        break;
    }
}
```

- [ ] **Step 7: Fake Mac for the on-device checks**

Create `firmware/test/claude_ble_phase2.py`:

```python
# firmware/test/claude_ble_phase2.py — fake Mac daemon for the Phase 2 on-device checks.
# The board takes one Claude subscriber: stop the real daemon first and restart it afterwards:
#   launchctl bootout gui/$(id -u)/dev.cicca.claude-board
#   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.cicca.claude-board.plist
# usage: python3 claude_ble_phase2.py sessions|permission|question|cancel|all
import asyncio
import struct
import sys
import time

from bleak import BleakClient, BleakScanner

B = "-3b2f-4c1e-9d8a-5f6e7d8c9b0a"
TRANSLATOR_SVC = "a7c00001" + B
REQ, ANS = "a7c00011" + B, "a7c00012" + B


def message(kind, mid, text=""):
    return bytes([kind]) + struct.pack("<I", mid) + text.encode()


def chunks(data, size):
    out = []
    for off in range(0, len(data), size - 1):
        part = data[off:off + size - 1]
        flags = (1 if off == 0 else 0) | (2 if off + size - 1 >= len(data) else 0)
        out.append(bytes([flags]) + part)
    return out


def describe(d):
    mid, code = struct.unpack("<IB", d[:5])
    if mid == 0 and code == 0x20:
        return "mode " + {0: "other", 1: "claude", 2: "picker"}.get(d[5], str(d[5]))
    if mid == 0 and code == 0x21:
        return "focus %d" % struct.unpack("<I", d[5:9])[0]
    if code in (1, 2, 3):
        return "id %d %s" % (mid, {1: "allow", 2: "deny", 3: "always allow"}[code])
    if code == 0x10:
        return "id %d answers %s" % (mid, [bin(m) for m in d[6:6 + d[5]]])
    return "unknown " + d.hex()


async def main(what):
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: TRANSLATOR_SVC in [u.lower() for u in ad.service_uuids], timeout=15)
    assert dev, "board not found"
    async with BleakClient(dev) as c:
        inputs = asyncio.Queue()

        def on_input(_, data):
            data = bytes(data)
            print("board ->", describe(data))
            inputs.put_nowait(data)

        await c.start_notify(ANS, on_input)

        async def send(kind, mid, text=""):
            for ch in chunks(message(kind, mid, text), c.mtu_size - 3):
                await c.write_gatt_char(REQ, ch, response=True)

        async def wait_for(pred, secs):
            end = time.monotonic() + secs
            while time.monotonic() < end:
                try:
                    d = await asyncio.wait_for(inputs.get(), end - time.monotonic())
                except asyncio.TimeoutError:
                    break
                if pred(d):
                    return d
            raise SystemExit("timed out")

        def is_id(mid):
            return lambda d: struct.unpack("<I", d[:4])[0] == mid

        now = int(time.time())
        await send(3, 0, "%d %d" % (now, time.localtime().tm_gmtoff // 60))

        if what in ("sessions", "all"):
            print("Press PWR x3 on the board (picker).")
            await wait_for(lambda d: d[:5] == b"\0\0\0\0\x20" and d[5] in (1, 2), 60)
            await send(6, 0)
            await send(4, 1, "w %d %d 1\nesp32-translator\nRunning the tests" % (now - 300, now))
            await send(4, 2, "i %d %d 2\nwebsite\nDeployed to staging." % (now - 60, now - 30))
            await send(4, 3, "n %d %d 0\napi\n" % (now - 10, now - 10))
            await send(4, 4, "e %d %d 0\nold-repo\nBye." % (now - 900, now - 900))
            print("Expect: api (red), esp32-translator (yellow, outlined), website · new (green), old-repo (grey). Tap website.")
            await wait_for(lambda d: d[:5] == b"\0\0\0\0\x21", 120)
            await send(4, 1, "w %d %d 0\nesp32-translator\nRunning the tests" % (now - 300, now))
            await send(4, 2, "i %d %d 1\nwebsite\nDeployed to staging." % (now - 60, now - 30))
            print("Expect the Claude screen: website / Idle · 1m / Deployed to staging.")

        if what in ("permission", "all"):
            await send(0, 4242, "esp32-translator\nBash\nnpm test -- --watch=false")
            print("Expect Deny / Allow only. Tap Allow.")
            print("answer:", describe(await wait_for(is_id(4242), 90)))
            await asyncio.sleep(2)
            await send(0, 4243, "esp32-translator\nBash\nnpm test -- --watch=false\nBash(npm test:*)")
            print("Expect Deny / Allow / Always allow and 'Rule: Bash(npm test:*)'. Tap Always allow.")
            print("answer:", describe(await wait_for(is_id(4243), 90)))

        if what in ("question", "all"):
            await asyncio.sleep(2)
            await send(7, 5151, "0 2 0 3\nesp32-translator\nColor\nWhich colour should the ring use?\n"
                                "Red\nWarm and loud\nGreen\nCalm\nBlue\nThe current colour")
            await send(7, 5151, "1 2 1 4\nesp32-translator\nFruits\nWhich fruits?\n"
                                "Apple\nCrisp\nBanana\nSoft\nCherry\nSmall and red\nDurian\nStrong smell")
            print("Page 1/2 single-select, page 2/2 checkboxes. Pick Green, Next, tick Apple and Cherry, Send.")
            d = await wait_for(is_id(5151), 180)
            assert d[4] == 0x10, describe(d)
            print("answers:", describe(d), "(expect ['0b10', '0b101'])")

        if what in ("cancel", "all"):
            await asyncio.sleep(2)
            await send(7, 6161, "0 1 0 2\nesp32-translator\nGo\nProceed?\nYes\n\nNo\n")
            print("Question shown; cancelling in 5 s, as if answered in the terminal.")
            await asyncio.sleep(5)
            await send(2, 6161)
            print("Expect 'Answered in the terminal or timed out.', then the previous screen.")
            await asyncio.sleep(3)


asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "all"))
```

- [ ] **Step 8: Build and re-run the host tests**

Run: `. ~/esp/esp-idf/export.sh && cd firmware && idf.py build 2>&1 | tail -3`
Expected: `Project build complete.`

Run each host test from Task 9 Step 6 again; expect the four "all tests passed" lines.

- [ ] **Step 9: On-device checks (USB, monitor open, real daemon stopped)**

Run: `launchctl bootout gui/$(id -u)/dev.cicca.claude-board; idf.py -p /dev/cu.usbmodem1101 flash monitor`, and in a second terminal `cd firmware/test && python3 claude_ble_phase2.py sessions`, then `… permission`. Check each row; restart the daemon afterwards (`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.cicca.claude-board.plist`).

| # | Do | Expect |
|---|---|---|
| 1 | Script connects (board on the translator) | Script prints `board -> mode other`; board log `told the Mac: board mode 0` |
| 2 | PWR ×3 | `board -> mode picker`; four rows in order api (red dot), esp32-translator (yellow, white outline), `website · new` (green), old-repo (grey); state words on the right |
| 3 | Tap `website` | `board -> focus 2`, then `board -> mode claude`; Claude screen: `website`, `Idle · 1m`, `Deployed to staging.`; status `Claude · Mac connected` |
| 4 | Keep the Claude screen on past the next minute boundary | Within 30 s of it the title reads `Idle · 2m` |
| 5 | BOOT ×1; then PWR ×2; then PWR ×1 (lock) | `mode other` on BOOT; `mode claude` on PWR ×2; `mode other` on lock (a locked board gets no session rows) |
| 6 | Run `… permission` from the Claude screen | First request: Deny / Allow only; tap within 700 ms ignored (log `ignoring tap that began before …`); Allow → `id 4242 allow` |
| 7 | Second request | Always allow under Deny / Allow, detail ends with `Rule: Bash(npm test:*)`; tap → `id 4243 always allow`; `Always allowed` result, then the session view |
| 8 | Stop the script (Ctrl-C) | Status `Claude · Mac not connected`; picker shows `Mac not connected` |

- [ ] **Step 10: Commit**

```bash
git add firmware/main/picker_ui.c firmware/main/claude_ui.c firmware/main/app.h firmware/main/main.c \
        firmware/main/ble_link.c firmware/main/shell.c firmware/main/clock.h firmware/main/clock_rtc.c \
        firmware/test/claude_ble_phase2.py
git commit -F - <<'EOF'
firmware: session picker, focused session on the Claude screen, Always allow, mode reports

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---
### Task 11: Firmware — AskUserQuestion pages

**Files:**
- Create: `firmware/main/question_ui.c`
- Modify: `firmware/main/claude_ui.c` (question hand-off), `firmware/main/app.h`, `firmware/main/CMakeLists.txt:1`

**Interfaces:**
- Consumes: `question_set_t` and `question_*` (Task 9); `claude_parse_question`, `CLAUDE_Q_STR`, `CLAUDE_INPUT_MAX` (Task 8); `claude_ui_note_press`, `claude_ui_tap_allowed`, `claude_ui_rearm`, `ble_link_send_claude_input`, and the static helpers `show_idle`, `set_buttons`, `arm_buttons`, `schedule_restore`, `start_cap` in `claude_ui.c` (Task 10).
- Produces:
  - `void question_ui_init(lv_obj_t *scr, question_set_t *set);`, `void question_ui_show(void);`, `void question_ui_hide(void);` (all with the display lock held)
  - `void claude_ui_question_send_locked(const uint8_t *answer, size_t len);`
  - `claude_ui_on_message` returns true for the last missing page of a question set (main.c then takes over the screen and chimes, as for a permission).

Layout on the 466 px round panel (one page): counter `1/2 · project` (y 36, grey), header (y 64, blue), question (y 92, up to 3 lines with `…`), option list 344 × 186 at y 178 (rows ≥ 52 px, scrolls when they do not fit), Back 110 px at bottom-left and Next/Send 130 px at bottom-right (Next/Send centred on page 1, where Back is hidden). The description overlay (380 × 260) sits on top until tapped. No "Other" row (Phase 3).

- [ ] **Step 1: Declarations and build entry**

In `firmware/main/app.h`, after `#include "modes.h"` add `#include "question.h"`, and after the line `void claude_ui_rearm(void); …` add:

```c
/* claude_ui.c: Send on the last question page (LVGL task): sends the answers and shows the result */
void claude_ui_question_send_locked(const uint8_t *answer, size_t len);

/* question_ui.c: AskUserQuestion pages on the Claude screen (display lock held for every call) */
void question_ui_init(lv_obj_t *scr, question_set_t *set);
void question_ui_show(void);                        /* page 1 of a complete set */
void question_ui_hide(void);                        /* safe before init */
```

In `firmware/main/CMakeLists.txt`, add `"question_ui.c"` after `"claude_ui.c"` in `SRCS`.

- [ ] **Step 2: The pages**

Create `firmware/main/question_ui.c`:

```c
/*
 * AskUserQuestion pages on the Claude screen, one page per question:
 *   top    : "1/3 · project", the question's header, the question (up to 3 lines)
 *   middle : one full-width row per option, radio (single-select) or checkbox (multi-select);
 *            the list scrolls when it does not fit; long-press a row for its description
 *   bottom : Back (from page 2) and Next, or Send on the last page (disabled until answered)
 * No "Other" row in Phase 2 (voice answers come with Phase 3).
 * Selection and the answer bytes: question.c (host-tested). claude_ui.c owns the pending request, the
 * 700 ms arming and the dark-panel rule: every control asks claude_ui_tap_allowed() before acting, and
 * every page change re-arms (a double tap on Next never lands on Send).
 * Every function runs with the display lock held (LVGL callbacks, or claude_ui.c under the lock).
 * Rows are rebuilt only from the Back / Next buttons, never from a row's own event.
 */
#include <stdint.h>
#include <stdio.h>

#include "lvgl.h"

#include "app.h"
#include "question.h"

LV_FONT_DECLARE(font_vi_22);

#define COLOR_ACCENT 0x1e6fd9
#define COLOR_ROW    0x1a1a1a
#define COLOR_ROW_ON 0x16324f
#define COLOR_MUTED  0x9a9a9a
#define COLOR_OFF    0x333333
#define COLOR_BACK   0x3a3a3a

static question_set_t *s_set;   /* owned by claude_ui.c */
static lv_obj_t *s_box;
static lv_obj_t *s_counter;
static lv_obj_t *s_header;
static lv_obj_t *s_text;
static lv_obj_t *s_list;
static lv_obj_t *s_back;
static lv_obj_t *s_next;
static lv_obj_t *s_next_label;
static lv_obj_t *s_desc;
static lv_obj_t *s_desc_label;
static lv_obj_t *s_rows[CLAUDE_OPT_MAX];
static lv_obj_t *s_marks[CLAUDE_OPT_MAX];

static void build_page(void);

static void on_pressed(lv_event_t *e)
{
    claude_ui_note_press();
}

static void refresh_marks(void)
{
    const claude_question_t *q = &s_set->q[s_set->page];
    uint8_t mask = s_set->mask[s_set->page];
    for (int i = 0; i < q->nopt; i++) {
        bool on = (mask >> i) & 1u;
        lv_obj_set_style_bg_color(s_marks[i], lv_color_hex(on ? COLOR_ACCENT : 0x000000), 0);
        lv_obj_set_style_bg_color(s_rows[i], lv_color_hex(on ? COLOR_ROW_ON : COLOR_ROW), 0);
    }
    bool last = question_last_page(s_set);
    bool ready = last ? question_all_answered(s_set) : question_page_answered(s_set, s_set->page);
    lv_label_set_text(s_next_label, last ? "Send" : "Next");
    lv_obj_set_state(s_next, LV_STATE_DISABLED, !ready);
}

/* SHORT_CLICKED: a long press (description) never selects */
static void on_row_tap(lv_event_t *e)
{
    if (!claude_ui_tap_allowed()) {
        return;
    }
    question_tap(s_set, (uint8_t)(uintptr_t)lv_event_get_user_data(e));
    refresh_marks();
}

static void on_row_long(lv_event_t *e)
{
    if (!claude_ui_tap_allowed()) {
        return;
    }
    const claude_question_t *q = &s_set->q[s_set->page];
    int i = (int)(uintptr_t)lv_event_get_user_data(e);
    const char *d = CLAUDE_Q_STR(q, desc[i]);
    lv_label_set_text(s_desc_label, d[0] ? d : "No description.");
    lv_obj_set_hidden(s_desc, false);
}

static void on_desc_tap(lv_event_t *e)
{
    lv_obj_set_hidden(s_desc, true);
}

static void on_back(lv_event_t *e)
{
    if (!claude_ui_tap_allowed() || s_set->page == 0) {
        return;
    }
    question_back(s_set);
    build_page();
    claude_ui_rearm();
}

static void on_next(lv_event_t *e)
{
    if (!claude_ui_tap_allowed()) {
        return;
    }
    if (!question_last_page(s_set)) {
        if (question_page_answered(s_set, s_set->page)) {
            question_next(s_set);
            build_page();
            claude_ui_rearm();   /* Send may now sit under the finger */
        }
        return;
    }
    uint8_t answer[CLAUDE_INPUT_MAX];
    size_t n = question_encode(s_set, answer);
    if (n > 0) {
        claude_ui_question_send_locked(answer, n);   /* hides this box; do not touch s_set afterwards */
    }
}

static lv_obj_t *make_label(uint32_t color, int width, int y)
{
    lv_obj_t *l = lv_label_create(s_box);
    lv_obj_set_width(l, width);
    lv_obj_set_style_text_font(l, &font_vi_22, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_align(l, LV_ALIGN_TOP_MID, 0, y);
    return l;
}

static lv_obj_t *make_button(const char *text, int width, lv_event_cb_t cb, lv_obj_t **label_out)
{
    lv_obj_t *b = lv_button_create(s_box);
    lv_obj_set_size(b, width, 52);
    lv_obj_set_style_radius(b, 26, 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(COLOR_ACCENT), 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(COLOR_OFF), LV_STATE_DISABLED);
    lv_obj_add_event_cb(b, on_pressed, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *l = lv_label_create(b);
    lv_obj_set_style_text_font(l, &font_vi_22, 0);
    lv_obj_set_style_text_color(l, lv_color_white(), 0);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    if (label_out) {
        *label_out = l;
    }
    return b;
}

static lv_obj_t *make_row(int i, const claude_question_t *q)
{
    lv_obj_t *row = lv_obj_create(s_list);
    lv_obj_set_width(row, 330);
    lv_obj_set_height(row, LV_SIZE_CONTENT);
    lv_obj_set_style_min_height(row, 52, 0);
    lv_obj_set_style_radius(row, 16, 0);
    lv_obj_set_style_border_width(row, 0, 0);
    lv_obj_set_style_bg_opa(row, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_hor(row, 14, 0);
    lv_obj_set_style_pad_ver(row, 10, 0);
    lv_obj_set_style_pad_column(row, 12, 0);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_scrollable(row, false);   /* a drag scrolls the list */
    lv_obj_add_event_cb(row, on_pressed, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(row, on_row_tap, LV_EVENT_SHORT_CLICKED, (void *)(uintptr_t)i);
    lv_obj_add_event_cb(row, on_row_long, LV_EVENT_LONG_PRESSED, (void *)(uintptr_t)i);

    lv_obj_t *mark = lv_obj_create(row);   /* radio (circle) or checkbox (rounded square) */
    lv_obj_set_size(mark, 22, 22);
    lv_obj_set_style_radius(mark, q->multi ? 4 : LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(mark, 2, 0);
    lv_obj_set_style_border_color(mark, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(mark, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(mark, 0, 0);
    lv_obj_set_clickable(mark, false);
    lv_obj_set_scrollable(mark, false);

    lv_obj_t *label = lv_label_create(row);
    lv_obj_set_width(label, 262);
    lv_obj_set_style_text_font(label, &font_vi_22, 0);
    lv_obj_set_style_text_color(label, lv_color_white(), 0);
    lv_label_set_long_mode(label, LV_LABEL_LONG_MODE_WRAP);
    lv_label_set_text(label, CLAUDE_Q_STR(q, label[i]));

    s_marks[i] = mark;
    return row;
}

static void build_page(void)
{
    const claude_question_t *q = &s_set->q[s_set->page];
    char counter[96];
    snprintf(counter, sizeof(counter), "%u/%u · %s", (unsigned)s_set->page + 1, (unsigned)s_set->count,
             CLAUDE_Q_STR(q, project));
    lv_label_set_text(s_counter, counter);
    lv_label_set_text(s_header, CLAUDE_Q_STR(q, header));
    lv_label_set_text(s_text, CLAUDE_Q_STR(q, question));
    lv_obj_clean(s_list);
    for (int i = 0; i < CLAUDE_OPT_MAX; i++) {
        s_rows[i] = NULL;
        s_marks[i] = NULL;
    }
    for (int i = 0; i < q->nopt; i++) {
        s_rows[i] = make_row(i, q);
    }
    lv_obj_scroll_to_y(s_list, 0, LV_ANIM_OFF);
    bool first = s_set->page == 0;
    lv_obj_set_hidden(s_back, first);
    lv_obj_align(s_next, LV_ALIGN_BOTTOM_MID, first ? 0 : 75, -42);
    lv_obj_set_hidden(s_desc, true);
    refresh_marks();
}

void question_ui_init(lv_obj_t *scr, question_set_t *set)
{
    s_set = set;
    s_box = lv_obj_create(scr);   /* opaque, covers the Claude screen's own widgets while shown */
    lv_obj_set_size(s_box, 466, 466);
    lv_obj_center(s_box);
    lv_obj_set_style_bg_color(s_box, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(s_box, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_box, 0, 0);
    lv_obj_set_style_radius(s_box, 0, 0);
    lv_obj_set_style_pad_all(s_box, 0, 0);
    lv_obj_set_scrollable(s_box, false);

    s_counter = make_label(COLOR_MUTED, 300, 36);
    s_header = make_label(COLOR_ACCENT, 300, 64);
    s_text = make_label(0xffffff, 360, 92);
    lv_obj_set_height(s_text, 80);   /* three lines, then "…" */

    s_list = lv_obj_create(s_box);
    lv_obj_set_size(s_list, 344, 186);
    lv_obj_align(s_list, LV_ALIGN_TOP_MID, 0, 178);
    lv_obj_set_style_bg_opa(s_list, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_list, 0, 0);
    lv_obj_set_style_pad_all(s_list, 0, 0);
    lv_obj_set_style_pad_row(s_list, 6, 0);
    lv_obj_set_flex_flow(s_list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(s_list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_scroll_dir(s_list, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(s_list, LV_SCROLLBAR_MODE_AUTO);

    s_back = make_button("Back", 110, on_back, NULL);
    lv_obj_set_style_bg_color(s_back, lv_color_hex(COLOR_BACK), 0);
    lv_obj_align(s_back, LV_ALIGN_BOTTOM_MID, -70, -42);
    s_next = make_button("Next", 130, on_next, &s_next_label);
    lv_obj_align(s_next, LV_ALIGN_BOTTOM_MID, 75, -42);

    s_desc = lv_obj_create(s_box);   /* created last: on top of the list and the buttons */
    lv_obj_set_size(s_desc, 380, 260);
    lv_obj_center(s_desc);
    lv_obj_set_style_bg_color(s_desc, lv_color_hex(0x202020), 0);
    lv_obj_set_style_bg_opa(s_desc, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(s_desc, 20, 0);
    lv_obj_set_style_border_width(s_desc, 0, 0);
    lv_obj_set_style_pad_all(s_desc, 20, 0);
    lv_obj_set_scrollable(s_desc, false);
    lv_obj_add_event_cb(s_desc, on_desc_tap, LV_EVENT_CLICKED, NULL);
    s_desc_label = lv_label_create(s_desc);
    lv_obj_set_width(s_desc_label, 340);
    lv_obj_set_style_text_font(s_desc_label, &font_vi_22, 0);
    lv_obj_set_style_text_color(s_desc_label, lv_color_white(), 0);
    lv_obj_set_style_text_align(s_desc_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(s_desc_label, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_center(s_desc_label);

    lv_obj_set_hidden(s_desc, true);
    lv_obj_set_hidden(s_box, true);
}

void question_ui_show(void)
{
    if (s_box == NULL || !question_complete(s_set)) {
        return;
    }
    s_set->page = 0;
    build_page();
    lv_obj_set_hidden(s_box, false);
}

void question_ui_hide(void)
{
    if (s_box == NULL) {
        return;
    }
    lv_obj_set_hidden(s_desc, true);
    lv_obj_set_hidden(s_box, true);
}
```

- [ ] **Step 3: Hand questions from the Claude screen to the pages**

In `firmware/main/claude_ui.c`:

After `static bool s_link;` add:

```c
static question_set_t s_qset;            /* pages of the question shown (or still arriving) */
static claude_question_t s_page;         /* parse buffer: NimBLE host task only, ~0.4 KB off its stack */
```

In `show_idle`, replace

```c
    set_buttons(false);
    lv_label_set_text(s_project, "");
```

with

```c
    set_buttons(false);
    question_ui_hide();
    lv_label_set_text(s_project, "");
```

In `claude_ui_init`, replace

```c
    s_always = make_button("Always allow", 0x1f5f8b, 220, 0, -74, CLAUDE_DECISION_ALWAYS);
```

with

```c
    s_always = make_button("Always allow", 0x1f5f8b, 220, 0, -74, CLAUDE_DECISION_ALWAYS);
    question_ui_init(s_scr, &s_qset);   /* after the buttons: the page box covers them while shown */
```

In `claude_ui_set_link`, replace

```c
    s_link = connected;
    if (!connected && s_pending_id) {
```

with

```c
    s_link = connected;
    if (!connected) {
        question_reset(&s_qset);   /* the Mac falls back to the terminal; drop pages still arriving */
    }
    if (!connected && s_pending_id) {
```

In `claude_ui_on_message`, replace

```c
        s_pending_id = m->id;
        s_always_offered = nf >= 4 && f[3][0] != '\0';
```

with

```c
        question_reset(&s_qset);   /* the Mac shows one request at a time: no question is pending now */
        question_ui_hide();
        s_pending_id = m->id;
        s_always_offered = nf >= 4 && f[3][0] != '\0';
```

replace

```c
    case CLAUDE_CANCEL:
        if (m->id == s_pending_id) {
```

with

```c
    case CLAUDE_CANCEL:
        if (m->id == s_qset.id) {
            question_reset(&s_qset);   /* also drops a set that was still arriving */
        }
        if (m->id == s_pending_id) {
```

and replace

```c
    default:
        /* finished: main.c chimes and toasts, the session view shows the line; sessions: picker_ui.c */
```

with

```c
    case CLAUDE_QUESTION:
        if (!claude_parse_question(m, &s_page)) {
            ESP_LOGW(TAG, "ignoring bad question page for %lu", (unsigned long)m->id);
            break;
        }
        if (question_add(&s_qset, m->id, &s_page)) {   /* the last missing page: show page 1 */
            if (s_restore_timer) {
                lv_timer_delete(s_restore_timer);
                s_restore_timer = NULL;
            }
            s_pending_id = m->id;
            s_always_offered = false;
            set_buttons(false);
            question_ui_show();
            arm_buttons();
            start_cap();
            show = true;
        }
        break;
    default:
        /* finished: main.c chimes and toasts, the session view shows the line; sessions: picker_ui.c */
```

Append to the end of the file:

```c
/* LVGL task (Send on the last question page): the answers go to the Mac, the result shows briefly */
void claude_ui_question_send_locked(const uint8_t *answer, size_t len)
{
    bool sent = ble_link_send_claude_input(answer, len);
    ESP_LOGI(TAG, "answers for %lu (%s)", (unsigned long)s_pending_id, sent ? "sent" : "NOT sent");
    question_reset(&s_qset);
    show_idle(sent ? "Answer sent" : "Not sent", sent ? "Claude continues." : "Answer in the terminal.");
    schedule_restore();
}
```

- [ ] **Step 4: Build and re-run the host tests**

Run: `. ~/esp/esp-idf/export.sh && cd firmware && idf.py build 2>&1 | tail -3`
Expected: `Project build complete.`

Run the four host tests from Task 9 Step 6; expect the four "all tests passed" lines.

- [ ] **Step 5: On-device checks (USB, monitor open, real daemon stopped)**

Run: `launchctl bootout gui/$(id -u)/dev.cicca.claude-board; idf.py -p /dev/cu.usbmodem1101 flash monitor`; second terminal `cd firmware/test && python3 claude_ble_phase2.py question`, then `… cancel`. Restart the daemon afterwards.

| # | Do | Expect |
|---|---|---|
| 1 | Board on the translator; run `… question` | Chime; the Claude screen takes over with `1/2 · esp32-translator`, `Color`, the question, three rows with round marks; `Next` grey (disabled) |
| 2 | Tap `Green` at once (< 0.7 s) | Ignored (log `ignoring tap that began before …`); then a tap highlights `Green` and enables `Next` |
| 3 | Tap `Red`, then `Red` again | Only `Red` highlighted both times |
| 4 | Long-press `Blue`, release, tap the overlay; then tap `Green`; double-tap `Next` fast | Overlay shows `The current colour` and closes on tap; selection unchanged by the long press; the second tap of the double tap lands on page 2 before arming and does nothing |
| 5 | Page 2 | `2/2 · esp32-translator`, `Fruits`, four rows with square marks, list scrolls to `Durian`; `Back` visible; `Send` disabled |
| 6 | Tick `Apple` and `Cherry`, untick and re-tick `Cherry`; `Back`, then `Next` | Page 1 still has `Green`, page 2 still `Apple` + `Cherry`; `Send` enabled |
| 7 | `Send` | Script prints `answers: id 5151 answers ['0b10', '0b101']`; board shows `Answer sent`, then the previous screen |
| 8 | Run `… cancel` | A one-page question appears; after 5 s `Answered in the terminal or timed out.`, then the previous screen; tapping where `Send` was does nothing |
| 9 | Lock (PWR ×1), run `… question` | Panel lights with page 1 over the lock; answer both pages; panel goes dark, still locked |

- [ ] **Step 6: Commit**

```bash
git add firmware/main/question_ui.c firmware/main/claude_ui.c firmware/main/app.h firmware/main/CMakeLists.txt
git commit -F - <<'EOF'
firmware: AskUserQuestion pages (single/multi-select, descriptions, Send on the last page)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 12: README and end-to-end acceptance with a real Claude session (controller + user)

This task is run by the controller together with the user (hardware in hand, real Claude Code sessions). The controller edits the README; the user performs the physical steps and reports what the board shows.

**Files:**
- Modify: `README.md` (Buttons and lock screen paragraph, Repository layout, BLE protocol table, Claude companion mode)

**Interfaces:**
- Consumes: everything above; the spike's Decisions table (which answer path and whether Always allow exists).
- Produces: user documentation; nothing for code.

- [ ] **Step 1: Document sessions, questions and the protocol**

In `README.md`:

Replace the line `The session picker lists Claude sessions from Phase 2 on; for now it shows "No sessions yet".` with:

```markdown
The session picker (PWR ×3) lists up to 6 Claude Code sessions from the Mac, "needs you" first, then the most
recent: a red dot needs you, yellow is working, green is idle, grey has ended (ended sessions leave after
10 min). "· new" marks a session that finished while another one was focused. Tap a row to focus it.
```

In the `## Repository layout` table, replace `` `claude_ui.c`, `lock_ui.c`, `picker_ui.c`, `` with `` `claude_ui.c`, `question_ui.c` + `question.c` (question pages), `lock_ui.c`, `picker_ui.c` + `sessions.c` (session picker), ``.

In the `## BLE protocol` table, replace the `…0011` and `…0012` rows with:

```markdown
| `…0011` Claude request | write (with response), encrypted | Mac → board, `[kind u8][id u32 LE][UTF-8 ≤ 400 bytes]`, chunked: 0 permission (`project\ntool\nsummary[\nrule]`), 1 finished (focused session), 2 cancel, 3 time (id 0, same text as above, sent on connect), 4 session row, 5 session removed, 6 sessions cleared, 7 question page. See `firmware/main/claude_proto.h` |
| `…0012` Claude answer | notify, encrypted | Board → Mac: Allow / Deny / Always allow, question answers (one option bitmask per question), board mode (translator / Claude / picker), focused session |
```

In `## Claude companion mode`, replace `When Claude finishes a turn, the board plays a done chime and a "Claude finished: <project>" toast, and the Claude screen shows the last line of the reply.` with `When the focused session finishes a turn, the board plays a done chime and a "<project> · <last line>" toast; other sessions finish silently and show up as "N new" on the Claude screen and "· new" in the picker.`

Replace `It adds three hooks: `PermissionRequest`, `Stop` and `Notification` (`idle_prompt`).` with `It adds these hooks: `PermissionRequest` (waits for the board), and, in the background (`async`), `Stop`, `Notification` (all types), `UserPromptSubmit`, `SessionStart` and `SessionEnd`. The hook passes `$TMUX_PANE` on to the daemon when Claude runs inside tmux.` (If the spike's `SESSION_HOOKS` is `false`, drop `SessionStart and SessionEnd` from that sentence and add: `Sessions end on their own after 2 h without events.`)

Insert before `**Bluetooth permission.**`:

```markdown
**Sessions.** The Claude screen shows the focused session: project, state with elapsed time ("Working · 12m"),
and the last line of Claude's reply. Session updates reach the board only while it shows the Claude screen or
the picker (battery); requests, cancels and the focused session's "done" arrive in any mode.

**Questions.** When Claude asks a multiple-choice question (AskUserQuestion), the board shows one page per
question ("1/2 · project"). Single choice: tap an option, then Next / Send. Several choices: tick the boxes.
Long-press an option to read its description. Send on the last page answers every question at once.
Questions the board cannot show (more than 4 questions or options) stay in the terminal.

**Always allow.** When Claude Code suggests a permission rule for the request, a third button "Always allow"
adds that rule (shown under the command as "Rule: …"), so the same kind of call is not asked again.
```

If the spike found `ALWAYS_ALLOW = unsupported`, replace that last paragraph with: `**Always allow** is not offered: this Claude Code version gives hooks no way to add a rule.` If it found `QUESTION_ANSWERS = denyWithReason`, append to the Questions paragraph: `Claude receives the choice as "The user answered on the board: <question> → <choice>".` If `terminalOnly`, replace the Questions paragraph with `Multiple-choice questions are answered in the terminal.`

In `**Safety rules**`, replace `- Nothing is ever auto-approved. Only an explicit Allow on the board approves a request.` with `- Nothing is ever auto-approved. Only an explicit Allow / Always allow tap approves a request, and only a Send tap answers a question; taps in the first 700 ms after anything appears, and taps on a dark panel, never count.`

- [ ] **Step 2: Install the Mac side and flash the board**

```bash
cd mac && swift test 2>&1 | tail -1 && python3 -m unittest test_claude_settings 2>&1 | tail -1 && bash install.sh
python3 -c 'import json,os; h=json.load(open(os.path.expanduser("~/.claude/settings.json")))["hooks"]; print(sorted(h))'
. ~/esp/esp-idf/export.sh && cd ../firmware && idf.py -p /dev/cu.usbmodem1101 flash monitor
```

Expected: tests pass; `claude-board installed`; the printed hook events include `Notification`, `PermissionRequest`, `Stop`, `UserPromptSubmit` (and `SessionEnd`, `SessionStart` when the spike said so); the board boots and the daemon log (`tail -f ~/.claude-board/daemon.log`) shows `ready`.

- [ ] **Step 3: End-to-end acceptance (user performs, controller watches the logs)**

Two terminals, each in its own tmux session in a different project directory: `tmux new -s alpha -c ~/some/project-a` and `tmux new -s beta -c ~/some/project-b`, then `claude` in each.

| # | Do | Expect |
|---|---|---|
| 1 | Board: PWR ×2 | Daemon log `board mode claude`; Claude screen shows the first session (`project-a`), `Idle` (elapsed once the clock is set) |
| 2 | In alpha: ask Claude to run a Bash command that needs permission (e.g. `touch e2e.txt`) | Board chimes and shows `project-a` / `Bash` / the command, Deny / Allow (+ Always allow with `Rule: …` if offered); picker row (PWR ×3) shows a red dot |
| 3 | Deny | Claude reports the call was denied; board `Denied`, then the session view, state `Working` → `Idle` |
| 4 | Ask again; Allow | The command runs; board `Allowed` |
| 5 | (Only if Always allow is offered) Ask for a similar command; tap Always allow; ask for the same command again | Second time no prompt anywhere (the rule was added) |
| 6 | In alpha: "Use AskUserQuestion to ask me two questions: one single-choice with 3 options, one multiple-choice with 4 options" | Board shows `1/2 · project-a`; single page highlights; Send disabled until answered; page 2 checkboxes; long-press shows a description; Send → Claude's next message uses exactly the chosen options |
| 7 | Same again, but answer in the terminal while the board shows page 1 | Board drops the pages (`Answered in the terminal or timed out.`) and goes back |
| 8 | Board in translator mode (BOOT ×1); let beta finish a turn | Silent; no session messages in the board log (`claude msg kind=4` absent); PWR ×2 later shows `Claude · 1 new` |
| 9 | PWR ×3, then tap `project-b` | Picker: `project-b · new` and `project-a` (outlined); after the tap the Claude screen shows `project-b` and its last line, and `· new` is gone |
| 10 | Focused session (beta) finishes a turn while the board shows the translator | Done chime + toast `project-b · <last line>` |
| 11 | Lock the board (PWR ×1); in alpha trigger a permission request | Panel wakes with the request (project tagged); answer; dark and locked again |
| 12 | `/exit` in alpha | Picker shows `project-a` with a grey dot `ended`; it disappears after 10 min |
| 13 | Turn the Mac's Bluetooth off and on while in the picker | After reconnect the picker shows the same rows once (no duplicates, no stale ones) |

Record any failure with the board log and `~/.claude-board/daemon.log` lines; fix it in the owning task's files with a test first, then re-run the affected rows.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -F - <<'EOF'
README: Claude sessions, session picker, questions and Always allow

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```
