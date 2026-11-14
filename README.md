# Tally

A macOS menu bar app for Claude Code. It shows your plan limits, every live
session and how big its context is getting, and your token usage by project.
It tells you when a session finishes or needs you, keeps your Mac awake while
Claude works, and lets you control sessions from the menu bar. Built with
SwiftUI and Liquid Glass.

> Tally is an independent project. It isn't made by or affiliated with Anthropic.

## Install

Requires macOS 26 or later and Claude Code. Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/Sha-Dox/Tally/master/install.sh | bash
```

That downloads the latest release into `~/Applications`, and Tally appears in
your menu bar. A **Set Up Tally** window opens with the recommended options
already selected. Click **Set Up** and you're done. The only thing you'll be
asked for is your password, once, for keeping the Mac awake with the lid
closed. You can rerun it any time from *Settings → General → Run Setup…*.

<details>
<summary>Install by hand instead</summary>

Download `Tally-<version>.zip` from
[Releases](https://github.com/Sha-Dox/Tally/releases), unzip it and move
`Tally.app` to Applications. The build isn't notarized, so the first time,
right-click Tally and choose **Open**, or run
`xattr -dr com.apple.quarantine /Applications/Tally.app`.
</details>

## Features

- **Menu bar:** your 5-hour and weekly plan usage stacked in one small item.
  The gauge turns into ⚠️ when a session is over the context warning level, and
  a dot appears when a session needs you or has finished.
- **Plan limits:** current session and weekly use with reset times, the same
  numbers Claude Code's `/usage` shows.
- **Live sessions:** each running session with its title, project, status,
  model and context size. The bar shifts gradually from green through orange
  (400K by default) to red (600K by default). Pin sessions to the top; the
  order never jumps around.
- **Alerts** (each can be switched off in *Settings → Alerts*):
  - **Done:** a notification when a session finishes a turn of 30 seconds or
    more.
  - **Needs you:** a notification when a session stops at a permission prompt
    or a question.
  - **Badge:** a dot in the menu bar until you open Tally.
  - **Context:** a warning with a *Compact Now* button when a session crosses
    the warning level.
  - **Plan:** a heads-up at 90% of a limit.

  Clicking a session notification takes you to that session's terminal.
- **Usage:** today's tokens, output, cache reads and replies, plus a 7-day
  chart stacked by project. Hover a day for its breakdown; click a project to
  focus on it.
- **Session controls** (for sessions running in the Rex terminal): go to the
  session, compact (waits until the session is idle), interrupt, or send it a
  message. Also: copy resume command, show transcript, end session.
- **Keep awake:** the ☕ button keeps your Mac and its network awake while any
  session is working, and lets it sleep normally once they're idle.
  - **Lid closed:** macOS always sleeps when the lid closes, which drops Wi-Fi
    mid-request. Setup installs `/etc/sudoers.d/tally-pmset`, which allows
    only `pmset -a disablesleep 0|1`. Tally turns lid-closed sleep off only
    while a session is working, and back on when sessions are idle, when Tally
    quits, on the next launch after a crash, or below 15% battery.
- **Startup:** open at login, and/or open and quit with Claude Code. The
  second adds a `SessionStart` hook to `~/.claude/settings.json` (a copy of the
  original is saved as `settings.json.tally-backup`), and Tally quits 30
  seconds after the last session ends.

## How it works and privacy

Tally runs entirely on your Mac and reads only what Claude Code already keeps:

| Data | Source |
|---|---|
| Live sessions and status | `~/.claude/sessions/<pid>.json` |
| Session titles and context size | the end of each session's transcript |
| Token totals | `~/.claude/projects/**/*.jsonl`, read incrementally and cached in `~/Library/Application Support/Tally/` |
| Plan limits | `api.anthropic.com/api/oauth/usage`, using the token Claude Code stores in the Keychain |

The token is used read-only. Tally never refreshes it, so it can't interfere
with Claude Code's own sign-in, and it's sent only to `api.anthropic.com`.

Session controls use each Claude Code process's `REX_BLOCK` to drive its
terminal with `rex send`, `rex send-key` and `rex focus`.

## Build from source

Needs Xcode 26 or later.

```sh
./build.sh      # build, install to ~/Applications/Tally.app and launch
./release.sh    # build a universal, signed build/Tally-<version>.zip
```

`release.sh` signs ad-hoc unless `SIGN_IDENTITY` is set. For downloads without
Gatekeeper warnings, sign with a *Developer ID Application* identity and
notarize the zip.

To check layout without opening the menu,
`Tally.app/Contents/MacOS/Tally --render-menu out.png` saves the menu as an
image (without Liquid Glass) and quits. Quit the running copy first.

## License

[MIT](LICENSE)
