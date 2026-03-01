# Terminal Completion Alerts Design

**Date:** 2026-03-01

## Goal
When a `codex` or `claude` command finishes in Terminal.app, the corresponding Terminal tab should be visibly marked and a sound should play. The visual status must remain until the user interacts with that tab (click/focus/key interaction).

## Scope
- Existing app: `TerminalGridMenubar`
- Terminal target: `Terminal.app` only
- Triggered commands: `codex`, `claude`
- Status persistence: stays active until user interaction with that same tab

## Functional Requirements
1. Detect start/end of `codex`/`claude` commands from shell.
2. On completion:
   - identify the exact Terminal tab by `tty`
   - color the tab green on success (`exit 0`)
   - color the tab red/orange on failure (`exit != 0`)
   - play one notification sound
3. Keep status visible until user interaction on the same tab.
4. On interaction, restore original tab colors.
5. Support multiple terminals/tabs in parallel (state keyed by `tty`).
6. Fail safely if tab lookup fails (no crash; status log only).

## Architecture
- **Shell integration (`zsh`)**
  - `preexec` tracks whether current command is a monitored command.
  - `precmd` emits a completion event containing `tty`, command, and exit code.
- **App integration (native Swift menubar app)**
  - Unix domain socket listener receives completion events.
  - Event handler performs Terminal AppleScript operations.
  - Highlight state map stores original colors per `tty` to restore later.
  - Local input monitors (mouse/key) detect user interaction and clear highlight for selected tab.

## Data Flow
1. User runs `codex ...` in Terminal tab (`tty` known to shell).
2. Command exits.
3. Hook sends JSON line to socket: `{type:"job_done",tty:"/dev/ttysXYZ",command:"codex",exitCode:0}`.
4. App receives event.
5. App finds tab matching `tty`.
6. App saves current `background` + `normal text` colors.
7. App applies status color and plays sound.
8. User clicks/focuses/types in that tab.
9. App detects interaction, restores original colors, removes highlight state.

## UI/UX
- Existing menubar app remains primary control surface.
- No additional window needed.
- Status line in menu reflects recent event or errors.

## Error Handling
- Socket unavailable: hooks fail silently.
- Invalid/closed tab reference: skip update for that event.
- AppleScript error: update app status line, continue processing future events.

## Security and Privacy
- Local-only Unix socket path in user home.
- No network exposure.
- No command content persistence beyond minimal event payload.

## Testing Strategy
1. Success flow (`codex` exits 0): green + sound.
2. Failure flow (non-zero): red/orange + sound.
3. Multi-tab flow: only matching `tty` is updated.
4. Reset flow: click/keypress in highlighted tab restores original colors.
5. Non-monitored command: no event emitted.
6. App restart: listener resumes and accepts new events.

## Out of Scope
- iTerm2 support
- Rich per-model themes
- Cross-user/system-wide daemon mode
