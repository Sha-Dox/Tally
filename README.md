# Tally

A macOS menu bar app for keeping an eye on Claude Code: plan limits, live
sessions and how big their context is getting, plus daily token usage. It also
lets you control sessions right from the menu bar. Built with SwiftUI and
Liquid Glass.

## Features

- **Menu bar:** your 5-hour and weekly plan usage stacked in one compact item.
  The gauge turns into ⚠️ when any session is over the context warning level.
- **Plan limits:** current session and weekly utilization with reset times,
  the same numbers Claude Code's `/usage` shows.
- **Live sessions:** each running Claude Code session with its project,
  status, model and current context size. The bar shifts gradually from green
  through orange (400K by default) to red (600K by default).
- **Context warnings:** a banner plus a notification with a *Compact Now*
  action when a session crosses the warning level. The warning re-arms after
  you compact.
- **Session controls** (for sessions running in the Rex terminal): go to
  the session, compact (queued until the session is idle), interrupt, or send
  it a message. Also: pin to top, copy resume command, show transcript, end
  session.
- **Keep awake:** the ☕ button in the header keeps your Mac and its network
  awake while any session is working, and lets it sleep normally once they're
  all idle. The display can still turn off.
  - **Lid closed:** macOS always sleeps when the lid closes, and that drops
    Wi-Fi mid-request. *Settings → Keep Awake → Set Up…* asks for your
    password once and installs `/etc/sudoers.d/tally-pmset`, which allows only
    `pmset -a disablesleep 0|1`. Tally then turns lid-closed sleep off while a
    session is working, and turns it back on when sessions are idle, when Tally
    quits, on its next launch after a crash, or below 15% battery. *Remove*
    deletes the rule.
- **Today:** total, output and cache-read tokens, replies, a 7-day chart and
  your top projects.

- **Startup:** *Open at login*, and *Open and quit with Claude Code*. The
  second adds a `SessionStart` hook to `~/.claude/settings.json` that runs
  `open -g -b com.mert.tally`, and makes Tally quit 30 seconds after the last
  session ends. Turning it off removes the hook. The first time Tally edits the
  file, it saves a copy as `settings.json.tally-backup`.

## Requirements

- macOS 26 or later
- Claude Code, signed in with a Claude subscription (needed for plan limits)
- Rex, optional (needed for the session controls)
- Xcode 26 or later to build

## Build and install

```sh
./build.sh      # build, install to ~/Applications/Tally.app and launch
./release.sh    # build a universal, signed build/Tally-<version>.zip
```

`release.sh` signs ad-hoc unless `SIGN_IDENTITY` is set. To share it with
other Macs without Gatekeeper warnings, sign with a *Developer ID Application*
identity and notarize the zip.

## How it works and privacy

Tally runs entirely on your Mac and reads only what Claude Code already keeps:

| Data | Source |
|---|---|
| Live sessions | `~/.claude/sessions/<pid>.json` |
| Context size | usage of the latest main-thread reply in the session's transcript |
| Token totals | `~/.claude/projects/**/*.jsonl`, read incrementally and cached in `~/Library/Application Support/Tally/` |
| Plan limits | `api.anthropic.com/api/oauth/usage`, using the token Claude Code stores in the Keychain |

The token is used read-only. Tally never refreshes it, so it can't interfere
with Claude Code's own sign-in, and it's sent only to `api.anthropic.com`.

Session controls use the `REX_BLOCK` of each Claude Code process to drive its
terminal with `rex send` / `rex send-key` / `rex focus`.
