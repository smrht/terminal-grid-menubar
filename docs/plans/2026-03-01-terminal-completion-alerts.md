# Terminal Completion Alerts Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add completion notifications for `codex` and `claude` commands: highlight the right Terminal tab, play a sound, and clear highlight on user interaction.

**Architecture:** `zsh` hooks emit local completion events with `tty` and exit code. The menubar app listens on a Unix domain socket, highlights the tab that matches `tty`, and restores original tab colors when the user interacts with that tab.

**Tech Stack:** Swift (AppKit, Foundation, Carbon), AppleScript bridge (`NSAppleScript`), Unix domain sockets (`DispatchSourceRead` + POSIX), zsh hooks (`preexec`, `precmd`).

---

### Task 1: Event Protocol and Listener Infrastructure

**Files:**
- Modify: `Sources/TerminalGridMenubar/TerminalGridMenubar.swift`
- Test: Manual runtime verification via app status updates

**Step 1: Write a failing runtime check**
Create listener start call in app startup and expect status to show listener active.

**Step 2: Run app to verify missing listener behavior**
Run: `./scripts/build-app.sh && open dist/TerminalGridMenubar.app`
Expected: no listener status (current behavior).

**Step 3: Implement minimal listener**
Add local Unix socket listener at `~/.terminal-grid-menubar/events.sock` that parses newline-delimited JSON events.

**Step 4: Run app to verify listener starts**
Run: `./scripts/build-app.sh && open dist/TerminalGridMenubar.app`
Expected: status can report listener started and app stays stable.

**Step 5: Commit**
```bash
git add Sources/TerminalGridMenubar/TerminalGridMenubar.swift
git commit -m "feat: add local completion event listener"
```

### Task 2: TTY-Based Highlight Apply/Restore

**Files:**
- Modify: `Sources/TerminalGridMenubar/TerminalGridMenubar.swift`
- Test: Manual AppleScript-backed integration checks

**Step 1: Write a failing runtime check**
Send synthetic event for known `tty`; verify no color change in current app.

**Step 2: Run check to verify failure**
Run: `printf '%s\n' '{"type":"job_done","tty":"/dev/ttysXYZ","command":"codex","exitCode":0}' | socat - UNIX-CONNECT:$HOME/.terminal-grid-menubar/events.sock`
Expected: no highlight before implementation.

**Step 3: Implement minimal highlight manager**
- Find tab by `tty` via AppleScript.
- Snapshot existing colors.
- Apply green (success) or red/orange (failure).
- Store per-tty state and restore on demand.

**Step 4: Run check to verify pass**
Repeat synthetic event against real `tty`.
Expected: target tab color changes + no crash.

**Step 5: Commit**
```bash
git add Sources/TerminalGridMenubar/TerminalGridMenubar.swift
git commit -m "feat: highlight terminal tabs on codex/claude completion"
```

### Task 3: Interaction Reset + Sound Notification

**Files:**
- Modify: `Sources/TerminalGridMenubar/TerminalGridMenubar.swift`

**Step 1: Write a failing runtime check**
After highlight, click the highlighted tab; verify highlight does not reset (current behavior).

**Step 2: Run check to verify failure**
Run app and trigger completion event.
Expected: highlight remains permanently before reset logic.

**Step 3: Implement minimal reset and audio behavior**
- Play `NSSound` on completion event.
- Install local monitors for `.leftMouseDown` and `.keyDown`.
- On interaction, read currently selected tab `tty` and restore only that tab if highlighted.

**Step 4: Run check to verify pass**
Trigger completion -> hear sound -> click/type in same tab -> color restores.
Expected: correct reset and stable app.

**Step 5: Commit**
```bash
git add Sources/TerminalGridMenubar/TerminalGridMenubar.swift
git commit -m "feat: restore highlighted tab on interaction and play completion sound"
```

### Task 4: Shell Hooks for codex/claude Completion Events

**Files:**
- Create: `scripts/install-shell-hooks.sh`
- Create: `scripts/terminal-grid-hooks.zsh`
- Modify: `README.md`
- Modify (user env): `~/.zshrc` (idempotent include)

**Step 1: Write a failing runtime check**
Run `codex --help` and verify no event reaches app.

**Step 2: Run check to verify failure**
Expected: no app status change from command completion.

**Step 3: Implement hook files and install script**
- Add `preexec`/`precmd` with `tty`, command detection (`codex|claude`), and JSON emit to socket.
- Add idempotent installer that appends sourcing block to `~/.zshrc`.

**Step 4: Run check to verify pass**
Source shell config and run `codex --help` in Terminal.
Expected: app highlights tab and plays sound on completion.

**Step 5: Commit**
```bash
git add scripts/install-shell-hooks.sh scripts/terminal-grid-hooks.zsh README.md
git commit -m "feat: add zsh hooks for codex/claude completion events"
```

### Task 5: Build, Deploy, and End-to-End Verification

**Files:**
- Modify: `/Applications/TerminalGridMenubar.app` (deployment artifact)

**Step 1: Build release bundle**
Run: `./scripts/build-app.sh`
Expected: successful build.

**Step 2: Deploy app bundle**
Run: `/usr/bin/ditto dist/TerminalGridMenubar.app /Applications/TerminalGridMenubar.app`
Expected: app replaced in Applications.

**Step 3: Restart service**
Run: `launchctl kickstart -k gui/$(id -u)/io.terminalgrid.menubar`
Expected: app restarts with new binary.

**Step 4: Verify full behavior**
- Run `codex --help` (or other short codex/claude command).
- Confirm sound + highlight.
- Click highlighted tab.
- Confirm color reset.

**Step 5: Commit**
```bash
git add .
git commit -m "chore: release terminal completion alerts"
```
