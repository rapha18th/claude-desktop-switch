# Claude Desktop Switch

Two Claude accounts. One desktop app. One click to switch.

Claude Desktop Switch moves the Claude desktop app on Windows between your saved accounts. A click closes Claude, saves the account you were on, restores the next one and reopens Claude. Your Code sessions follow you into every account. Settings, memory, permission rules and skills on your PC stay shared.

## Start with Claude

**[Start with Claude](https://rapha18th.github.io/claude-desktop-switch/)** opens the Claude desktop app with the setup prompt ready in a new Code session. Press Enter and Claude installs the tool with you.

GitHub shows app links as plain text. To paste one yourself, put it in your browser's address bar.

Claude desktop app:

```text
claude://code/new?q=Set%20up%20Claude%20Desktop%20Switch%20on%20this%20PC%20from%20https%3A%2F%2Fgithub.com%2Frapha18th%2Fclaude-desktop-switch.%20Clone%20it%20into%20%25USERPROFILE%25%5CTools%5Cclaude-desktop-switch%2C%20confirm%20Python%203.8%20or%20newer%20runs%2C%20and%20read%20the%20README.%20The%20switch%20closes%20this%20app%2C%20so%20ClaudeSwitch.ps1%20is%20mine%20to%20run%3A%20when%20everything%20is%20ready%2C%20tell%20me%20to%20double-click%20Setup.cmd%20in%20that%20folder.
```

Claude Code in a terminal:

```text
claude-cli://open?q=Set%20up%20Claude%20Desktop%20Switch%20on%20this%20PC%20from%20https%3A%2F%2Fgithub.com%2Frapha18th%2Fclaude-desktop-switch.%20Clone%20it%20into%20%25USERPROFILE%25%5CTools%5Cclaude-desktop-switch%2C%20confirm%20Python%203.8%20or%20newer%20runs%2C%20and%20read%20the%20README.%20The%20switch%20closes%20this%20app%2C%20so%20ClaudeSwitch.ps1%20is%20mine%20to%20run%3A%20when%20everything%20is%20ready%2C%20tell%20me%20to%20double-click%20Setup.cmd%20in%20that%20folder.
```

Both links fill in the prompt and wait for you to press Enter.

## Quick start

1. Install Python 3.8 or newer: `winget install Python.Python.3.12`
2. Download this repository (**Code**, then **Download ZIP**) and unzip it into a folder you keep, such as `C:\Users\<you>\Tools\claude-desktop-switch`.
3. Open Claude and sign in to your first account.
4. Double-click `Setup.cmd`. Name the account signed in now, then name the account to add.
5. Claude reopens at the sign-in screen. Sign in to your second account.

Start > **Claude Accounts** and your Desktop now hold a shortcut per account. Click one to switch.

Sign-in runs through your browser. If it lands on your first account again, sign out of claude.ai in the browser and sign in once more.

## Daily use

- **Claude (name)** switches to that account. Claude closes, the switch takes a few seconds, Claude reopens.
- A switch stops running Code sessions, so the tool asks first.
- **Claude Accounts - Share sessions** copies new sessions across your accounts in place.
- Run `Setup.cmd` again any time to rebuild the shortcuts.

### Commands

Run these from a normal PowerShell window in the tool's folder, for example `powershell -ExecutionPolicy Bypass -File .\ClaudeSwitch.ps1 list`.

| Command | What it does |
| --- | --- |
| `list` | Saved accounts, the live data folder, Python and health |
| `setup` | First run, or a fresh set of shortcuts |
| `add <name> [-CurrentName <name>]` | Saves the live login, then opens Claude at the sign-in screen for a new account |
| `use <name> [-Force]` | Switches accounts. `-Force` skips the question about running sessions |
| `sync [-Force]` | Shares sessions across accounts in place |
| `remove <name>` | Forgets an account. Its login moves to the stash |
| `shortcuts [-Desktop]` | Rebuilds the Start menu shortcuts, and the Desktop ones with `-Desktop` |

A switch closes the app that runs it, so the tool stops early inside Claude's own terminal or a Claude session. Claude can install it for you; the switching is yours.

## How it works

### The login

Claude keeps each login in a few places inside its data folder: the `oauth:*` keys and `lastKnownAccountUuid` in `config.json`, the cookie database, and the `Local Storage`, `Session Storage` and `IndexedDB` folders. Each saved account holds its own copy of exactly these. Everything else in the folder stays shared.

A switch:

1. Asks Claude to quit the way Windows does at sign-out, and waits for its files.
2. Applies Claude's last pending settings write, if one is waiting.
3. Saves the live login back into its account. Tokens rotate, so this captures the newest copy every time.
4. Shares Code sessions across accounts.
5. Moves the live login into the stash and restores the target account.
6. Reopens Claude.

### Sessions

The desktop app files Code sessions per account in `claude-code-sessions\<account>\<organization>`. Transcripts live in `~\.claude\projects`, which every account already shares. `sessions.py` copies the session files across your saved accounts while Claude is closed:

- the newest copy of a session wins;
- a session deleted in one account leaves every account, and each removed copy waits in the stash;
- scheduled tasks merge by id;
- Remote Control links and saved-environment links stay with the account that made them.

A session resumed under another organization shows a notice about thinking from another organization. The conversation is whole. Claude rereads it and thinks afresh, so the first reply takes a little longer.

### Background jobs

Jobs that a Code session starts in the background keep running when Claude closes. The resumed session starts with a fresh task list, so it loses sight of them and may start them again. `JobHandover.ps1` hands them back:

- before Claude closes, the switch records each running job: session, folder, command, process and log files;
- a `SessionStart` hook in `~\.claude\settings.json` runs `JobHandover.ps1 hook` as each session opens, finds that session's jobs still running, and tells Claude to watch them and leave them running;
- the hook also catches jobs left by an app update or restart, matched by folder;
- jobs that finished during the switch arrive as a list of logs to read.

Add the hook once:

```json
"hooks": { "SessionStart": [ { "matcher": "startup|resume", "hooks": [ {
  "type": "command", "command": "powershell.exe",
  "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\JobHandover.ps1", "hook"],
  "timeout": 30 } ] } ] }
```

`JobHandover.ps1 list` shows the jobs under each session and any orphans.

### Office skills on Windows

The docx, pptx and xlsx skills convert documents through LibreOffice with `scripts/office/soffice.py`. That helper probes a Unix socket type that Windows Python lacks, and stops before LibreOffice starts. `office_skills.py patch` adds a Windows path to the helper; the switch runs it after every change of account, because the app downloads fresh skill copies per account. Add `C:\Program Files\LibreOffice\program` to your PATH as well, so the helper finds `soffice`.

### Safety

- Every account stays signed in, because a logout revokes the saved token. Switch with the shortcuts and leave Claude's own Sign out alone.
- A login that looks signed out goes to the stash, and the saved copy stays as it was.
- A lock lets one switch run at a time.
- Each move rolls back if a file is busy.
- Displaced logins wait in the stash. It keeps the ten newest of each kind and everything from the last two weeks. Logins outside your saved accounts stay until you delete them.
- Saved logins are encrypted with this PC's key, so they belong to this PC.

Everything the tool keeps lives in `%LOCALAPPDATA%\ClaudeAccountSwitch`: `state.json`, `slots`, `stash` and `switch.log`.

## Set these once per account

Claude keeps a few things with each account in its own browser storage. The tool carries that storage whole with each login, so these stay per account:

- **Folder groups in the sidebar.** The sidebar groups sessions by saved environments. A new account starts with an empty list, so shared sessions gather in one **Local** group. Start a new session, open the environment picker, choose **New environment** and pick a project folder. Sessions from that exact folder join its group at once. Repeat for each folder you use.
- **Project order in the sidebar.** Drag the groups once.
- **Permission mode per folder**, such as Auto. Pick it once in a session in that folder.
- **Code appearance**: editor font, themes, text size and preferred editor.
- **Connectors and Claude in Chrome.** Link them again under each account.
- **Plugins and skills from claude.ai.** Install them again. Features your organization gates come from its admin.
- **Organization policy**, such as Remote Control, comes from each organization's admin settings.
- **The terminal `claude` CLI** keeps its own login in `~\.claude.json`. Run `/login` there.
- **Cowork sessions** stay with the account that made them.

## Contributing

Each item in the list above is an open invitation. Issues and pull requests are welcome, especially for:

- carrying sidebar environments and project order across accounts through a safe path;
- sharing Cowork sessions;
- a tray app for switching;
- macOS, where Claude keeps its data in `~/Library/Application Support/Claude`.

Test on copies. Every command takes `-AppData`, `-Store`, `-ShortcutRoot` and `-NoApp`, so a run can point at copied folders and leave the real app as it is.

## Requirements

Windows 10 or 11, Windows PowerShell 5.1 (built in), Python 3.8 or newer, and the Claude desktop app from the Microsoft Store or claude.ai.

## Acknowledgements

Claude Desktop Switch is inspired by [claude-swap](https://github.com/realiti4/claude-swap) by realiti4, which switches accounts for Claude Code in the terminal. Its core idea carries over: save the live login first, restore the target, keep every account signed in. This project brings that to people who live in the desktop app.

## Authors

Rairo Mukamuri ([@rapha18th](https://github.com/rapha18th)) and Claude (Anthropic), as co-authors. Built together in Claude Code.

## License

MIT. See [LICENSE](LICENSE).
