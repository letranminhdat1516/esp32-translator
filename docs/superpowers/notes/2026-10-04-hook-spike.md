# Hook spike findings (2026-10-04)

Claude Code version: `2.1.289 (Claude Code)`. Method: interactive `claude --permission-mode default` in tmux (session
`cbspike`, 220x60), project-local `.claude/settings.local.json` hooks in a throwaway temp project
(`$TMPDIR/cb-spike.pK93bQ/proj`), board daemon stopped (`launchctl bootout`) for the whole run and restarted afterwards
(`state = running`, log `listening` / `[ble] ready`). Rounds as in Phase 2 plan Task 1. Model: Opus 5.5, effort medium.

Rounds run: A (worked, so B skipped), C with `message` (worked, so the `reason` retry skipped), D, E1 (`touch`), E1c (an
extra E1 run with a command that touches no files, see below), idle wait, `/exit`. E2 (`rule_remember`) skipped because
E1c worked.

## Decisions

| Name | Value | Evidence |
|---|---|---|
| DENY_MESSAGE_KEY | `message` | Round C: deny + `message` reached Claude as the tool_result (`is_error: true`); Round D: same for Bash (`"content": "SPIKE-D1-DENIED"`). `reason` NOT VERIFIED (not tried). |
| ALWAYS_ALLOW | `suggestionsVerbatim` | Round E1c: `updatedPermissions` = the `addRules` suggestion verbatim; Claude wrote `Bash(python3 -c "print\(4242\)")` to `.claude/settings.local.json` `permissions.allow` and the repeat ran with no PermissionRequest. Caveat: applying an `addDirectories` suggestion (Round E1) did NOT stop the re-prompt, so only `addRules` suggestions should get the button. `ruleRemember` NOT VERIFIED (not tried). |
| QUESTION_ANSWERS | `updatedInputJoined` | Round A: allow + `updatedInput.answers` with values joined by `", "`; no dialog in the pane; tool_result `"Which color?"="Green", "Which fruits?"="Apple, Cherry"`. `updatedInputArrays` NOT VERIFIED (Round B skipped). `denyWithReason` also works (Round C) as fallback. |
| SESSION_HOOKS | `true` | SessionStart (`source: "startup"`) and SessionEnd (`reason: "prompt_input_exit"`) both logged from `settings.local.json` hooks. |
| TMUX_PANE_VISIBLE | `true` | All 23 logged events had `"TMUX_PANE": "%0"` and `"TMUX": "/private/tmp/tmux-501/default,93688,0"`. |
| SUGGESTIONS_SHAPE | `{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "python3 -c \"print(4242)\""}], "behavior": "allow", "destination": "localSettings"}` | Round E1c `permission_suggestions[0]`. Other real shapes seen (Round D/E1, `touch` in the temp dir): `{"type": "addDirectories", "directories": ["<cwd>"], "destination": "session"}` and `{"type": "setMode", "mode": "acceptEdits", "destination": "session"}`. |

Rule for QUESTION_ANSWERS: Round A worked → updatedInputJoined; else Round B worked → updatedInputArrays; else Round C worked →
denyWithReason; else terminalOnly.

### Other observations

- `Stop` stdin carries `last_assistant_message` (the last assistant text), so the tracker does not need to read the
  transcript for the last line.
- `Notification` with `notification_type: "permission_prompt"` fires only when the terminal dialog is actually shown
  (hook printed nothing). When the hook answered (Rounds A, C, D, E1, E1c) no `permission_prompt` notification was logged.
- `idle_prompt` arrived about 60 s after the last Stop (`message: "Claude is waiting for your input"`).
- Interrupting a pending terminal permission dialog with Escape produced NO `Stop` event (7 UserPromptSubmit, 6 Stop).
  A session can therefore stay "working" after an interrupt until the next event.
- `cwd` is the resolved path (`/private/var/...`) even though tmux started in `/var/folders/...` (a symlink). The
  `touch` rounds got `addDirectories` suggestions for the cwd itself, most likely because of that temp-dir/symlink
  setup; a normal project directory is expected to get `addRules` for such commands (NOT VERIFIED).
- No hook-approval or settings dialog appeared for project-local hooks; the folder-trust dialog appeared once
  (default choice was "No, exit"; "Yes, I trust this folder" was selected for the temp project).
- `PermissionRequest` stdin has no `permission_suggestions` key for AskUserQuestion.

## Verified stdin per event

Home directory shown as `~`. Each block is the first logged record of that event (stdin under `event`, hook env under `env`).

### SessionStart
```json
{
  "event": {
    "session_id": "1446dfe2-fbee-4854-8c19-3c744971e58f",
    "transcript_path": "~/.claude/projects/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f.jsonl",
    "cwd": "/private/var/folders/5w/04vl1bzx1b58rxgxq5_zskhr0000gn/T/cb-spike.pK93bQ/proj",
    "scratchpad_dir": "/private/tmp/claude-501/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f/scratchpad",
    "hook_event_name": "SessionStart",
    "source": "startup",
    "model": "claude-opus-5-5[1m]"
  },
  "env": {
    "TMUX_PANE": "%0",
    "TMUX": "/private/tmp/tmux-501/default,93688,0"
  }
}
```

### SessionEnd
```json
{
  "event": {
    "session_id": "1446dfe2-fbee-4854-8c19-3c744971e58f",
    "transcript_path": "~/.claude/projects/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f.jsonl",
    "cwd": "/private/var/folders/5w/04vl1bzx1b58rxgxq5_zskhr0000gn/T/cb-spike.pK93bQ/proj",
    "scratchpad_dir": "/private/tmp/claude-501/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f/scratchpad",
    "prompt_id": "a3b7b9e9-4ec2-49f2-8d18-424ce6a09e0f",
    "hook_event_name": "SessionEnd",
    "reason": "prompt_input_exit"
  },
  "env": {
    "TMUX_PANE": "%0",
    "TMUX": "/private/tmp/tmux-501/default,93688,0"
  }
}
```

### UserPromptSubmit
```json
{
  "event": {
    "session_id": "1446dfe2-fbee-4854-8c19-3c744971e58f",
    "transcript_path": "~/.claude/projects/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f.jsonl",
    "cwd": "/private/var/folders/5w/04vl1bzx1b58rxgxq5_zskhr0000gn/T/cb-spike.pK93bQ/proj",
    "scratchpad_dir": "/private/tmp/claude-501/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f/scratchpad",
    "prompt_id": "27a528bd-2180-4cc9-98b7-429878beab3c",
    "permission_mode": "default",
    "hook_event_name": "UserPromptSubmit",
    "prompt": "Call the AskUserQuestion tool exactly once with exactly two questions. Question 1: question \"Which color?\", header \"Color\", options Red, Green, Blue (each with a one-sentence description), multiSelect false. Question 2: question \"Which fruits?\", header \"Fruits\", options Apple, Banana, Cherry (each with a one-sentence description), multiSelect true. After the tool returns, reply with one line that starts with RESULT: followed by exactly what the tool result told you."
  },
  "env": {
    "TMUX_PANE": "%0",
    "TMUX": "/private/tmp/tmux-501/default,93688,0"
  }
}
```

### Stop
```json
{
  "event": {
    "session_id": "1446dfe2-fbee-4854-8c19-3c744971e58f",
    "transcript_path": "~/.claude/projects/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f.jsonl",
    "cwd": "/private/var/folders/5w/04vl1bzx1b58rxgxq5_zskhr0000gn/T/cb-spike.pK93bQ/proj",
    "scratchpad_dir": "/private/tmp/claude-501/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f/scratchpad",
    "prompt_id": "27a528bd-2180-4cc9-98b7-429878beab3c",
    "permission_mode": "default",
    "effort": {
      "level": "medium"
    },
    "hook_event_name": "Stop",
    "stop_hook_active": false,
    "last_assistant_message": "RESULT: Your questions have been answered: \"Which color?\"=\"Green\", \"Which fruits?\"=\"Apple, Cherry\". You can now continue with these answers in mind.",
    "background_tasks": [],
    "session_crons": []
  },
  "env": {
    "TMUX_PANE": "%0",
    "TMUX": "/private/tmp/tmux-501/default,93688,0"
  }
}
```

### Notification (permission_prompt)
```json
{
  "event": {
    "session_id": "1446dfe2-fbee-4854-8c19-3c744971e58f",
    "transcript_path": "~/.claude/projects/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f.jsonl",
    "cwd": "/private/var/folders/5w/04vl1bzx1b58rxgxq5_zskhr0000gn/T/cb-spike.pK93bQ/proj",
    "scratchpad_dir": "/private/tmp/claude-501/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f/scratchpad",
    "prompt_id": "cc155eb3-28c4-4990-97f5-4254b1d23a4f",
    "hook_event_name": "Notification",
    "message": "Claude needs your permission",
    "notification_type": "permission_prompt"
  },
  "env": {
    "TMUX_PANE": "%0",
    "TMUX": "/private/tmp/tmux-501/default,93688,0"
  }
}
```

### Notification (idle_prompt)
```json
{
  "event": {
    "session_id": "1446dfe2-fbee-4854-8c19-3c744971e58f",
    "transcript_path": "~/.claude/projects/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f.jsonl",
    "cwd": "/private/var/folders/5w/04vl1bzx1b58rxgxq5_zskhr0000gn/T/cb-spike.pK93bQ/proj",
    "scratchpad_dir": "/private/tmp/claude-501/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f/scratchpad",
    "prompt_id": "c5725dcc-3950-449f-aa4c-2941a792ef13",
    "hook_event_name": "Notification",
    "message": "Claude is waiting for your input",
    "notification_type": "idle_prompt"
  },
  "env": {
    "TMUX_PANE": "%0",
    "TMUX": "/private/tmp/tmux-501/default,93688,0"
  }
}
```

### PermissionRequest (AskUserQuestion)
```json
{
  "event": {
    "session_id": "1446dfe2-fbee-4854-8c19-3c744971e58f",
    "transcript_path": "~/.claude/projects/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f.jsonl",
    "cwd": "/private/var/folders/5w/04vl1bzx1b58rxgxq5_zskhr0000gn/T/cb-spike.pK93bQ/proj",
    "scratchpad_dir": "/private/tmp/claude-501/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f/scratchpad",
    "prompt_id": "27a528bd-2180-4cc9-98b7-429878beab3c",
    "permission_mode": "default",
    "effort": {
      "level": "medium"
    },
    "hook_event_name": "PermissionRequest",
    "tool_name": "AskUserQuestion",
    "tool_input": {
      "questions": [
        {
          "question": "Which color?",
          "header": "Color",
          "options": [
            {"label": "Red", "description": "A warm, bold color."},
            {"label": "Green", "description": "A calm color found throughout nature."},
            {"label": "Blue", "description": "A cool color like the sky and sea."}
          ],
          "multiSelect": false
        },
        {
          "question": "Which fruits?",
          "header": "Fruits",
          "options": [
            {"label": "Apple", "description": "A crisp fruit that can be sweet or tart."},
            {"label": "Banana", "description": "A soft, sweet fruit in a yellow peel."},
            {"label": "Cherry", "description": "A small, round stone fruit that is usually red."}
          ],
          "multiSelect": true
        }
      ]
    }
  },
  "env": {
    "TMUX_PANE": "%0",
    "TMUX": "/private/tmp/tmux-501/default,93688,0"
  }
}
```
(Option objects compacted onto one line each; content unchanged.)

### PermissionRequest (Bash, addRules suggestion — Round E1c)
```json
{
  "event": {
    "session_id": "1446dfe2-fbee-4854-8c19-3c744971e58f",
    "transcript_path": "~/.claude/projects/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f.jsonl",
    "cwd": "/private/var/folders/5w/04vl1bzx1b58rxgxq5_zskhr0000gn/T/cb-spike.pK93bQ/proj",
    "scratchpad_dir": "/private/tmp/claude-501/-private-var-folders-5w-04vl1bzx1b58rxgxq5-zskhr0000gn-T-cb-spike-pK93bQ-proj/1446dfe2-fbee-4854-8c19-3c744971e58f/scratchpad",
    "prompt_id": "fb0cdb86-5c00-4f19-94d2-5dba060eb9a6",
    "permission_mode": "default",
    "effort": {
      "level": "medium"
    },
    "hook_event_name": "PermissionRequest",
    "tool_name": "Bash",
    "tool_input": {
      "command": "python3 -c \"print(4242)\"",
      "description": "Print 4242 using Python"
    },
    "permission_suggestions": [
      {
        "type": "addRules",
        "rules": [
          {
            "toolName": "Bash",
            "ruleContent": "python3 -c \"print(4242)\""
          }
        ],
        "behavior": "allow",
        "destination": "localSettings"
      }
    ]
  },
  "env": {
    "TMUX_PANE": "%0",
    "TMUX": "/private/tmp/tmux-501/default,93688,0"
  }
}
```

### PermissionRequest (Bash, addDirectories/setMode suggestions — Round D, `touch spike-d1.txt`)
```json
{
  "event": {
    "hook_event_name": "PermissionRequest",
    "tool_name": "Bash",
    "tool_input": {
      "command": "touch spike-d1.txt",
      "description": "Create empty file spike-d1.txt"
    },
    "permission_suggestions": [
      {
        "type": "addDirectories",
        "directories": [
          "/private/var/folders/5w/04vl1bzx1b58rxgxq5_zskhr0000gn/T/cb-spike.pK93bQ/proj"
        ],
        "destination": "session"
      },
      {
        "type": "setMode",
        "mode": "acceptEdits",
        "destination": "session"
      }
    ]
  }
}
```
(Excerpt: the common fields `session_id` … `effort` and `env` are identical to the block above apart from `prompt_id`.)

## Replies tried and what Claude saw

### Round A — allow + `updatedInput.answers` joined (WORKS)
Reply:
```json
{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow", "updatedInput": {"questions": [<the two questions exactly as received>], "answers": {"Which color?": "Green", "Which fruits?": "Apple, Cherry"}}}}}
```
tool_result (check.py):
```json
{"type": "tool_result", "content": "Your questions have been answered: \"Which color?\"=\"Green\", \"Which fruits?\"=\"Apple, Cherry\". You can now continue with these answers in mind.", "tool_use_id": "toolu_011PhifaHiVMuS8YGMXtAhWa"}
```
Pane (no question dialog appeared):
```
⏺ User answered Claude's questions:
  ⎿  · Which color? → Green
     · Which fruits? → Apple, Cherry
  ⎿  Allowed by PermissionRequest hook
⏺ RESULT: Your questions have been answered: "Which color?"="Green", "Which fruits?"="Apple, Cherry". You can now continue with these answers in mind.
```

### Round B — answers as arrays: NOT RUN (Round A worked).

### Round C — deny + `message` (WORKS)
Reply:
```json
{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "deny", "message": "The user answered on the board: Which planet? → Mars; Which moons? → Io, Titan"}}}
```
tool_result:
```json
{"type": "tool_result", "content": "The user answered on the board: Which planet? → Mars; Which moons? → Io, Titan", "is_error": true, "tool_use_id": "toolu_01Wh43Wvvi3zDiMQ3BZFeiPx"}
```
Pane (no dialog):
```
  ⎿  Error: The user answered on the board: Which planet? → Mars; Which moons? → Io, Titan
  ⎿  Denied by PermissionRequest hook
⏺ RESULT: The tool came back as an error, but the message said: "The user answered on the board: Which planet? → Mars; Which moons? → Io, Titan"
```
Note: Claude sees it as an error, so the deny-with-reason path is clearly worse than Round A; it stays only as fallback.
The `reason` key retry was not run.

### Round D — Bash deny + `message` (WORKS)
Reply:
```json
{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "deny", "message": "SPIKE-D1-DENIED"}}}
```
tool_result:
```json
{"type": "tool_result", "content": "SPIKE-D1-DENIED", "is_error": true, "tool_use_id": "toolu_01Hwm2wLbC3U94rLFCgKY3MR"}
```
Pane:
```
  ⎿  Denied by PermissionRequest hook
⏺ The command didn't run. It was blocked and returned SPIKE-D1-DENIED, so spike-d1.txt wasn't created. I won't try it again unless you tell me to.
```

### Round E1 — allow + first suggestion verbatim, `touch spike-e1.txt` (asked again)
The suggestion was `addDirectories` (session) for the cwd. Reply:
```json
{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow", "updatedPermissions": [{"type": "addDirectories", "directories": ["/private/var/folders/5w/04vl1bzx1b58rxgxq5_zskhr0000gn/T/cb-spike.pK93bQ/proj"], "destination": "session"}]}}}
```
First run allowed (`Allowed by PermissionRequest hook`); `settings.local.json` got no `permissions` key. The repeat produced a
new PermissionRequest with the same two suggestions; the hook printed nothing and the terminal dialog appeared:
```
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /private/var/folders/5w/04vl1bzx1b58rxgxq5_zskhr0000gn/T/cb-spike.pK93bQ/proj from this project
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No
```
It was cancelled with Escape (`Interrupted · What should Claude do instead?`; no Stop event followed).

### Round E1c — extra run: allow + first suggestion verbatim, `python3 -c "print(4242)"` (WORKS)
Added because E1's suggestion was not a rule. Reply:
```json
{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow", "updatedPermissions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "python3 -c \"print(4242)\""}], "behavior": "allow", "destination": "localSettings"}]}}}
```
`.claude/settings.local.json` afterwards: `"permissions": {"allow": ["Bash(python3 -c \"print\\(4242\\)\")"]}`.
The repeat ran with no new PermissionRequest (count unchanged) and no dialog:
```
❯ Run the exact same command again with the Bash tool: python3 -c "print(4242)"
  Ran 1 shell command
⏺ It ran again and printed 4242.
```

### Round E2 — `{"rule": …, "remember": true}`: NOT RUN (E1c worked). ruleRemember NOT VERIFIED.

### Idle and exit
`idle_prompt` Notification logged about 60 s after the last Stop; `/exit` produced SessionEnd with `reason: "prompt_input_exit"`.
