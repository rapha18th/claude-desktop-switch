<#
Claude Desktop Switch: switch the Claude desktop app between saved accounts on Windows.

The mechanism comes from realiti4/claude-swap (MIT), which does this for the Claude Code CLI:
  - each account's login lives in a slot;
  - every switch first saves the live login back into its slot (tokens rotate, so the
    newest copy is captured), then restores the target slot;
  - only account-specific state moves; settings and memory stay shared;
  - accounts are never logged out, because a logout revokes the saved token.
For the desktop app it adds:
  - Code sessions shared across saved accounts (sessions.py) while the app is closed;
  - the app's pending config journal settled before config.json changes;
  - a signed-out login never saved over a good one;
  - displaced logins kept in a stash; the only copy of a login is never pruned.

Commands:
  ClaudeSwitch.ps1 setup                               guided first run, then shortcuts
  ClaudeSwitch.ps1 list                                accounts and health
  ClaudeSwitch.ps1 add <name> [-CurrentName <name>]    save the live login, open Claude signed out
  ClaudeSwitch.ps1 use <name> [-Force]                 switch accounts
  ClaudeSwitch.ps1 sync [-Force]                       share sessions without switching
  ClaudeSwitch.ps1 remove <name>                       forget an account (its login goes to the stash)
  ClaudeSwitch.ps1 shortcuts [-Desktop]                Start menu (and Desktop) shortcuts per account
#>
param(
    [Parameter(Position = 0)][ValidateSet('setup', 'list', 'add', 'use', 'sync', 'remove', 'shortcuts')][string]$Command = 'list',
    [Parameter(Position = 1)][string]$Name,
    [string]$CurrentName,
    [string]$AppData,
    [string]$Store = (Join-Path $env:LOCALAPPDATA 'ClaudeAccountSwitch'),
    [string]$ShortcutRoot,
    [switch]$Desktop,
    [switch]$Force,
    [switch]$NoApp,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$Families = @('Claude_pzs8sxrjxfjjc', 'AnthropicPBC.Claude_fnn82j28hfe8t')
$Mutating = $Command -ne 'list'
$Store = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Store)

# Account-specific state inside the app's data folder. Everything else stays shared.
$BundleFiles = @('Network\Cookies', 'Network\Cookies-journal', 'Cookies', 'Cookies-journal')
$BundleDirs = @('Local Storage', 'Session Storage', 'IndexedDB')

$Splice = Join-Path $PSScriptRoot 'splice.py'
$SessionsPy = Join-Path $PSScriptRoot 'sessions.py'
$StateFile = Join-Path $Store 'state.json'
$SlotRoot = Join-Path $Store 'slots'
$StashRoot = Join-Path $Store 'stash'
$LogFile = Join-Path $Store 'switch.log'
$SessionSnapshot = Join-Path $Store 'shared-sessions.json'
$Utf8 = New-Object Text.UTF8Encoding $false
$script:LogEnabled = $false

function Say([string]$msg) {
    Write-Host $msg
    if ($script:LogEnabled) {
        [IO.File]::AppendAllText($LogFile, ("{0}  {1}`r`n" -f (Get-Date -Format s), $msg), $Utf8)
    }
}

function Stamp { Get-Date -Format 'yyyyMMdd-HHmmss' }

# ---------- environment ----------

function Resolve-Python {
    foreach ($c in @(@('py', '-3'), @('python3'), @('python'))) {
        if (-not (Get-Command $c[0] -ErrorAction SilentlyContinue)) { continue }
        $pre = @($c | Select-Object -Skip 1)
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $c[0] @pre -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>$null | Out-Null
            $ok = $LASTEXITCODE -eq 0
        } catch {
            $ok = $false
        } finally {
            $ErrorActionPreference = $old
        }
        if ($ok) { return , @($c) }
    }
    return $null
}

function Invoke-Py([string]$Script, [string[]]$PyArgs) {
    $pre = @($Python | Select-Object -Skip 1)
    $enc = $null
    try { $enc = [Console]::OutputEncoding; [Console]::OutputEncoding = $Utf8 } catch { }
    try {
        $out = & $Python[0] @pre -I $Script @PyArgs
        $code = $LASTEXITCODE
    } finally {
        if ($enc) { try { [Console]::OutputEncoding = $enc } catch { } }
    }
    return [pscustomobject]@{ Code = $code; Out = @($out) }
}

function Invoke-Splice([string[]]$SpliceArgs) {
    $r = Invoke-Py $Splice $SpliceArgs
    if ($r.Code -ne 0) { throw "splice.py $($SpliceArgs[0]) failed: $(($r.Out | Out-String).Trim())" }
    return ([string]($r.Out -join "`n")).Trim()
}

function Test-SameView([string]$A, [string]$B) {
    # True when two paths show the same folder, as the MSIX layer does inside the app.
    $probe = '.switch-probe-' + [guid]::NewGuid().ToString('N')
    $file = Join-Path $A $probe
    try {
        [IO.File]::WriteAllText($file, '')
        return [IO.File]::Exists((Join-Path $B $probe))
    } catch {
        return $false
    } finally {
        if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
    }
}

function Test-Locked([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $false }
    try { [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None').Close(); return $false } catch { return $true }
}

function Find-LiveFolder {
    # Candidates the app can use, in the app's own order of preference.
    $cands = New-Object System.Collections.ArrayList
    if ($env:CLAUDE_USER_DATA_DIR) { [void]$cands.Add([pscustomobject]@{ Path = $env:CLAUDE_USER_DATA_DIR; Kind = 'custom'; Family = '' }) }
    foreach ($f in $Families) {
        [void]$cands.Add([pscustomobject]@{ Path = (Join-Path $env:LOCALAPPDATA "Packages\$f\LocalCache\Roaming\Claude"); Kind = 'package'; Family = $f })
        [void]$cands.Add([pscustomobject]@{ Path = (Join-Path $env:LOCALAPPDATA "Claude-Data\$($f.ToLowerInvariant())"); Kind = 'moved'; Family = $f })
    }
    [void]$cands.Add([pscustomobject]@{ Path = (Join-Path $env:APPDATA 'Claude'); Kind = 'exe'; Family = '' })
    $found = @($cands | Where-Object { [IO.File]::Exists((Join-Path $_.Path 'config.json')) })
    # Inside the app, %APPDATA%\Claude is a merged view of the package folder: keep one.
    $pkgs = @($found | Where-Object { $_.Kind -eq 'package' })
    $script:InsideView = $false
    $exe = $found | Where-Object { $_.Kind -eq 'exe' } | Select-Object -First 1
    if ($exe -and $pkgs.Count -gt 0) {
        foreach ($p in $pkgs) {
            if (Test-SameView $p.Path $exe.Path) { $script:InsideView = $true; $found = @($found | Where-Object { $_ -ne $exe }); break }
        }
    }
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -eq 1) { return $found[0] }
    $locked = @($found | Where-Object { Test-Locked (Join-Path $_.Path 'lockfile') })
    if ($locked.Count -eq 1) { return $locked[0] }
    return ($found | Sort-Object { [IO.File]::GetLastWriteTimeUtc((Join-Path $_.Path 'config.json')) } -Descending | Select-Object -First 1)
}

function Test-InsideClaude {
    if ($env:CLAUDE_CODE_DESKTOP_APP_VERSION -or $script:InsideView) { return $true }
    try {
        $id = $PID
        for ($i = 0; $i -lt 8 -and $id; $i++) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop
            if (-not $p) { break }
            if ($p.ExecutablePath -match '\\WindowsApps\\(AnthropicPBC\.)?Claude_' -or $p.ExecutablePath -like '*\AnthropicClaude\*') { return $true }
            $id = $p.ParentProcessId
        }
    } catch { }
    return $false
}

# ---------- state ----------

function Test-SlotName([string]$n) {
    if ($n -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$') { return $false }
    return $n -notmatch '^(con|prn|aux|nul|com[1-9]|lpt[1-9])$'
}

function Assert-SlotName([string]$n) {
    if (-not (Test-SlotName $n)) { throw "Account names use letters, digits, - or _, up to 32 characters, for example personal or work. '$n' needs a change." }
}

function Read-StateFile([string]$path) {
    if (-not [IO.File]::Exists($path)) { return $null }
    $text = [IO.File]::ReadAllText($path)
    if (-not $text.Trim()) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Get-LiveUuid { Invoke-Splice @('uuid', $Config) }

function Get-State {
    $s = Read-StateFile $StateFile
    if (-not $s -and [IO.File]::Exists($StateFile)) {
        $s = Read-StateFile "$StateFile.bak"
        if ($s) { Say 'state.json was damaged. Using state.json.bak.' }
    }
    if (-not $s -and [IO.Directory]::Exists($SlotRoot)) {
        $slots = @(Get-ChildItem -LiteralPath $SlotRoot -Directory | Where-Object { Test-SlotName $_.Name } | ForEach-Object {
                [pscustomobject]@{ name = $_.Name; uuid = (Invoke-Splice @('uuid', (Join-Path $_.FullName 'account.json'))); saved = $_.LastWriteTime.ToString('s') }
            })
        if ($slots.Count -gt 0) {
            $live = Get-LiveUuid
            $match = $slots | Where-Object { $_.uuid -and $_.uuid -eq $live } | Select-Object -First 1
            $s = [pscustomobject]@{ active = $(if ($match) { $match.name } else { '' }); slots = $slots }
            Say 'Rebuilt state.json from the saved logins.'
        }
    }
    if (-not $s) { $s = [pscustomobject]@{ active = ''; slots = @() } }
    foreach ($k in @('active', 'slots')) {
        if ($s.PSObject.Properties.Name -notcontains $k) { $s | Add-Member -NotePropertyName $k -NotePropertyValue '' }
    }
    foreach ($legacy in @('appId', 'appExe')) { $s.PSObject.Properties.Remove($legacy) }
    $s.slots = @($s.slots | Where-Object { $_ -and $_.name })
    return $s
}

function Save-State($s) {
    $bytes = $Utf8.GetBytes(($s | ConvertTo-Json -Depth 5))
    $tmp = "$StateFile.tmp"
    $fs = [IO.File]::Open($tmp, 'Create', 'Write', 'None')
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    if ([IO.File]::Exists($StateFile)) { [IO.File]::Replace($tmp, $StateFile, "$StateFile.bak") } else { [IO.File]::Move($tmp, $StateFile) }
}

function Get-Slot($s, [string]$n) { $s.slots | Where-Object { $_.name -eq $n } | Select-Object -First 1 }

function Set-Slot($s, [string]$n, [string]$uuid) {
    $slot = Get-Slot $s $n
    if ($slot) {
        $slot.uuid = $uuid
        $slot.saved = (Get-Date -Format s)
    } else {
        $s.slots = @($s.slots) + [pscustomobject]@{ name = $n; uuid = $uuid; saved = (Get-Date -Format s) }
    }
}

function Assert-SavedLogin($slot) {
    if (-not $slot.uuid) { throw "'$($slot.name)' waits for its first sign-in. Run: use $($slot.name), then sign in." }
    $saved = Join-Path (Join-Path $SlotRoot $slot.name) 'account.json'
    if ((Invoke-Splice @('uuid', $saved)) -ne $slot.uuid) { throw "The saved login for '$($slot.name)' is damaged. Remove it and add it again." }
}

# ---------- app process control ----------

function Get-ClaudePackages {
    # Store installs, preferring the family whose data folder is live.
    $names = @('Claude', 'AnthropicPBC.Claude')
    if ($Live -and $Live.Family -like 'AnthropicPBC*') { [array]::Reverse($names) }
    $found = @()
    foreach ($n in $names) {
        try { $found += @(Get-AppxPackage -Name $n -ErrorAction SilentlyContinue) } catch { }
    }
    return $found
}

function Get-InstallRoots {
    $roots = @(Get-ClaudePackages | ForEach-Object { Join-Path $_.InstallLocation 'app\' })
    $roots += (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\')
    return $roots
}

function Get-ClaudeProcesses([switch]$CodeSessions) {
    $sid = [Diagnostics.Process]::GetCurrentProcess().SessionId
    @(Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object {
            $p = $_.Path
            if ($_.SessionId -ne $sid -or -not $p) { return $false }
            if ($CodeSessions) {
                # Store builds report these under %APPDATA%\Claude, the package's virtual path.
                if ($p -notlike '*\claude-code\*') { return $false }
                foreach ($r in @($AppData, (Join-Path $env:APPDATA 'Claude'))) {
                    if ($p.StartsWith($r.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
                }
                return $false
            }
            if ($p -like '*\claude-code\*') { return $false }
            foreach ($r in $InstallRoots) { if ($p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
            return $false
        })
}

$EndSessionCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ClaudeSwitchWindows {
    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    // Asks the app to quit the way Windows does at sign-out. A plain close only hides it to the tray.
    public static int EndSession(int[] pids) {
        List<uint> set = new List<uint>();
        foreach (int p in pids) set.Add((uint)p);
        List<IntPtr> windows = new List<IntPtr>();
        EnumWindows(delegate (IntPtr h, IntPtr l) { uint pid; GetWindowThreadProcessId(h, out pid); if (set.Contains(pid)) windows.Add(h); return true; }, IntPtr.Zero);
        IntPtr r;
        foreach (IntPtr h in windows) SendMessageTimeout(h, 0x0011, IntPtr.Zero, (IntPtr)1, 0x2, 5000, out r);
        foreach (IntPtr h in windows) SendMessageTimeout(h, 0x0016, (IntPtr)1, (IntPtr)1, 0x2, 5000, out r);
        return windows.Count;
    }
}
'@

function Wait-Released {
    $deadline = (Get-Date).AddSeconds(20)
    foreach ($rel in $BundleFiles + @('config.json', 'config.json.journal')) {
        $path = Join-Path $AppData $rel
        while (Test-Locked $path) {
            if ((Get-Date) -gt $deadline) { throw "Claude still holds $rel. Quit Claude from the tray and run again." }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Stop-ClaudeApp {
    if ($NoApp) { return }
    $procs = Get-ClaudeProcesses
    if ($procs.Count -gt 0) {
        $busy = Get-ClaudeProcesses -CodeSessions
        if ($busy.Count -gt 0 -and -not $Force) {
            $answer = Read-Host "Claude is running Code sessions. Switching closes them and stops any turn in progress. Continue? [y/N]"
            if ($answer -notmatch '^(y|yes)$') { throw 'Cancelled. Everything stays as it was.' }
        }
        # From here on a failure reopens Claude, because this run closed it.
        $script:StoppedApp = $true
        Say 'Closing Claude...'
        if (-not ('ClaudeSwitchWindows' -as [type])) { Add-Type -TypeDefinition $EndSessionCode }
        [void][ClaudeSwitchWindows]::EndSession([int[]]@($procs | ForEach-Object { $_.Id }))
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-ClaudeProcesses).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        $left = @(Get-ClaudeProcesses) + @(Get-ClaudeProcesses -CodeSessions)
        if ($left.Count -gt 0) {
            Say 'Claude is still running after 20 seconds. Stopping it.'
            $left | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }
    Wait-Released
}

function Start-ClaudeApp {
    if ($NoApp) { return }
    Say 'Opening Claude...'
    $squirrel = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'
    if ($Live.Kind -eq 'exe' -and [IO.File]::Exists($squirrel)) { Start-Process $squirrel; return }
    $p = Get-ClaudePackages | Select-Object -First 1
    if ($p) {
        $appId = 'Claude'
        try { $appId = @((Get-AppxPackageManifest $p).Package.Applications.Application)[0].Id } catch { }
        Start-Process explorer.exe "shell:AppsFolder\$($p.PackageFamilyName)!$appId"
        return
    }
    if ([IO.File]::Exists($squirrel)) { Start-Process $squirrel; return }
    Say 'Open Claude from the Start menu.'
}

# ---------- bundle copy / move ----------

function Move-Path([string]$From, [string]$To) {
    $parent = Split-Path $To
    if (-not [IO.Directory]::Exists($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $sameRoot = [IO.Path]::GetPathRoot($From) -eq [IO.Path]::GetPathRoot($To)
    for ($i = 1; ; $i++) {
        try {
            if (-not $sameRoot) { Move-Item -LiteralPath $From -Destination $To }
            elseif ([IO.Directory]::Exists($From)) { [IO.Directory]::Move($From, $To) }
            else { [IO.File]::Move($From, $To) }
            return
        } catch {
            if ($i -ge 10) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Copy-Bundle([string]$From, [string]$To) {
    foreach ($rel in $BundleFiles) {
        $src = Join-Path $From $rel
        if ([IO.File]::Exists($src)) {
            $dst = Join-Path $To $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }
    foreach ($rel in $BundleDirs) {
        $src = Join-Path $From $rel
        if ([IO.Directory]::Exists($src)) {
            robocopy $src (Join-Path $To $rel) /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "copy failed: $rel" }
        }
    }
}

function Save-LiveTo([string]$Dest) {
    # Writes into Dest.new, then swaps it in, so a failed save never damages the old copy.
    $tmp = "$Dest.new"
    if ([IO.Directory]::Exists($tmp)) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    Copy-Bundle $AppData $tmp
    Invoke-Splice @('export', $Config, (Join-Path $tmp 'account.json')) | Out-Null
    if ([IO.Directory]::Exists($Dest)) {
        Move-Path $Dest (Join-Path $StashRoot ("replaced-{0}-{1}" -f (Split-Path $Dest -Leaf), (Stamp)))
    }
    Move-Path $tmp $Dest
}

function Move-LiveAside([string]$Stash) {
    # Moves the live login into a stash. On failure every moved item goes back.
    New-Item -ItemType Directory -Force -Path $Stash | Out-Null
    Invoke-Splice @('export', $Config, (Join-Path $Stash 'account.json')) | Out-Null
    $moved = New-Object System.Collections.ArrayList
    try {
        foreach ($rel in $BundleFiles + $BundleDirs) {
            $src = Join-Path $AppData $rel
            if ([IO.File]::Exists($src) -or [IO.Directory]::Exists($src)) {
                Move-Path $src (Join-Path $Stash $rel)
                [void]$moved.Add($rel)
            }
        }
        Invoke-Splice @('strip', $Config) | Out-Null
    } catch {
        $why = $_.Exception.Message
        for ($i = $moved.Count - 1; $i -ge 0; $i--) {
            try { Move-Path (Join-Path $Stash $moved[$i]) (Join-Path $AppData $moved[$i]) }
            catch { Say "Move $($moved[$i]) from $Stash back into $AppData by hand." }
        }
        throw "Part of the login is in use ($why). Claude stays on the current account."
    }
    return $Stash
}

function Restore-From([string]$Src) {
    Copy-Bundle $Src $AppData
    Invoke-Splice @('import', $Config, (Join-Path $Src 'account.json')) | Out-Null
}

function Undo-Restore([string]$Stash) {
    try {
        foreach ($rel in $BundleFiles + $BundleDirs) {
            $live = Join-Path $AppData $rel
            if ([IO.File]::Exists($live) -or [IO.Directory]::Exists($live)) { Remove-Item -LiteralPath $live -Recurse -Force }
            $saved = Join-Path $Stash $rel
            if ([IO.File]::Exists($saved) -or [IO.Directory]::Exists($saved)) { Move-Path $saved $live }
        }
        Invoke-Splice @('import', $Config, (Join-Path $Stash 'account.json')) | Out-Null
    } catch {
        # Leave Claude closed: its folder holds part of two logins.
        $script:KeepClosed = $true
        Say "Rollback stopped: $($_.Exception.Message)"
        Say "Your previous login is in $Stash. Copy its files into $AppData, or run use with a saved account."
    }
}

function Resolve-Journal {
    # The app journals each config write and replays it at start only while config.json
    # is unchanged. Settle it now, before the switch changes config.json.
    if (-not [IO.File]::Exists("$Config.journal")) { return }
    $dir = Join-Path $StashRoot ("journal-{0}" -f (Stamp))
    switch (Invoke-Splice @('journal', $Config, $dir)) {
        'replayed' { Say "Applied Claude's last unsaved settings write. The journal is in $dir" }
        'dropped' { Say "Set aside a stale settings journal. It is in $dir" }
    }
}

function Clear-Shadow {
    # Store build only: login files in %APPDATA%\Claude sit under the package folder and
    # could show through once a live file moves away. Move them into the stash.
    if (-not $Shadow) { return }
    $found = @($BundleFiles + $BundleDirs | Where-Object { Test-Path -LiteralPath (Join-Path $Shadow $_) })
    if ($found.Count -eq 0) { return }
    $shadowConfig = Join-Path $Shadow 'config.json'
    if ([IO.File]::Exists($shadowConfig) -and [IO.File]::GetLastWriteTimeUtc($shadowConfig) -gt [IO.File]::GetLastWriteTimeUtc($Config)) {
        Say "Left $Shadow alone: it looks newer than the live folder, so another Claude install may use it."
        return
    }
    $stash = Join-Path $StashRoot ("shadow-{0}" -f (Stamp))
    foreach ($rel in $found) { Move-Path (Join-Path $Shadow $rel) (Join-Path $stash $rel) }
    Say "Moved $($found.Count) old login file(s) out of $Shadow into $stash"
}

function Remove-OldStashes {
    # Keeps the 10 newest of each kind and anything from the last 14 days.
    # Logins that belong to no account (unknown-login, shadow) are never removed.
    try {
        if (-not [IO.Directory]::Exists($StashRoot)) { return }
        $cut = (Get-Date).AddDays(-14)
        Get-ChildItem -LiteralPath $StashRoot -Directory | ForEach-Object {
            if ($_.Name -match '^(.+)-(\d{8}-\d{6})$') {
                [pscustomobject]@{ Dir = $_; Kind = ($Matches[1] -replace '^replaced-.*$', 'replaced' -replace '^signed-out-.*$', 'signed-out' -replace '^removed-.*$', 'removed'); When = [datetime]::ParseExact($Matches[2], 'yyyyMMdd-HHmmss', $null) }
            }
        } | Where-Object { @('unknown-login', 'shadow') -notcontains $_.Kind } | Group-Object Kind | ForEach-Object {
            $_.Group | Sort-Object When -Descending | Select-Object -Skip 10 | Where-Object { $_.When -lt $cut } |
                ForEach-Object { Remove-Item -LiteralPath $_.Dir.FullName -Recurse -Force }
        }
    } catch {
        Say "Stash cleanup skipped: $($_.Exception.Message)"
    }
}

# Saves the live login into the slot it belongs to. Returns that slot name, or ''.
function Save-Current($s, [string]$fallbackName) {
    $live = Get-LiveUuid
    if (-not $live) { Say 'Claude is at the sign-in screen. Moving on.'; return '' }
    $active = if ($s.active) { Get-Slot $s $s.active } else { $null }
    $owner = $s.slots | Where-Object { $_.uuid -eq $live } | Select-Object -First 1
    # A slot still waiting for its first sign-in claims the live login, unless another
    # slot already owns that account (the browser signed in to the same account again).
    if (-not $owner -and $active -and -not $active.uuid) { $owner = $active }
    if (-not $owner -and $fallbackName) {
        $named = Get-Slot $s $fallbackName
        if ($named -and $named.uuid -and $named.uuid -ne $live) {
            throw "'$fallbackName' belongs to a different account than the one in Claude now. Pick a new name with -CurrentName. Everything stays as it was."
        }
    }
    $ownerName = if ($owner) { $owner.name } elseif ($fallbackName) { $fallbackName } else { '' }
    $cookies = Join-Path $AppData 'Network\Cookies'
    if (-not [IO.File]::Exists($cookies)) { $cookies = Join-Path $AppData 'Cookies' }
    $problem = Invoke-Splice @('loginok', $Config, $cookies)
    if ($problem -ne 'ok') {
        $label = if ($ownerName) { $ownerName } else { 'unknown' }
        $stash = Join-Path $StashRoot ("signed-out-{0}-{1}" -f $label, (Stamp))
        Save-LiveTo $stash
        Say "The live login looks signed out ($problem). The saved copy stays as it was. This one is in $stash"
        return ''
    }
    if (-not $ownerName) {
        $stash = Join-Path $StashRoot ("unknown-login-{0}" -f (Stamp))
        Save-LiveTo $stash
        Say "The live login belongs to an account outside your saved list. Kept a copy at $stash"
        return ''
    }
    Save-LiveTo (Join-Path $SlotRoot $ownerName)
    Set-Slot $s $ownerName $live
    Say "Saved the live login as '$ownerName'."
    return $ownerName
}

# Copies Code sessions across every saved account. Runs while the app is closed.
# A failure here never blocks the login switch.
function Sync-Sessions($s) {
    $dir = Join-Path $AppData 'claude-code-sessions'
    if (-not [IO.Directory]::Exists($dir)) { return }
    $accounts = @($s.slots | ForEach-Object { $_.uuid } | Where-Object { $_ } | Select-Object -Unique)
    if ($accounts.Count -lt 2) { return }
    try {
        $r = Invoke-Py $SessionsPy (@('sync', $dir, (Join-Path $StashRoot ("sessions-{0}" -f (Stamp))), $SessionSnapshot) + $accounts)
        if ($r.Code -ne 0) { throw ($r.Out | Out-String).Trim() }
        foreach ($line in $r.Out) { Say "$line" }
    } catch {
        Say "Session sharing failed. The switch goes ahead: $($_.Exception.Message)"
    }
}

# ---------- shortcuts ----------

function Get-ClaudeIcon {
    $exe = ''
    foreach ($p in Get-ClaudePackages) {
        $c = Join-Path $p.InstallLocation 'app\claude.exe'
        if ([IO.File]::Exists($c)) { $exe = $c; break }
    }
    $squirrel = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'
    if (-not $exe -and [IO.File]::Exists($squirrel)) { $exe = $squirrel }
    if (-not $exe) { return '' }
    # Store builds live in a versioned folder, so keep a copy of the icon that outlasts updates.
    $ico = Join-Path $Store 'claude.ico'
    try {
        Add-Type -AssemblyName System.Drawing
        $icon = [Drawing.Icon]::ExtractAssociatedIcon($exe)
        $fs = [IO.File]::Create($ico)
        try { $icon.Save($fs) } finally { $fs.Dispose(); $icon.Dispose() }
        return $ico
    } catch {
        return $exe
    }
}

function Update-Shortcuts($s, [switch]$WithDesktop) {
    $menu = if ($ShortcutRoot) { Join-Path $ShortcutRoot 'Programs\Claude Accounts' } else { Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Accounts' }
    $desk = if ($ShortcutRoot) { Join-Path $ShortcutRoot 'Desktop' } else { [Environment]::GetFolderPath('Desktop') }
    $dirs = @($menu)
    if ($WithDesktop) { $dirs += $desk }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $icon = Get-ClaudeIcon
    $items = @($s.slots | ForEach-Object { [pscustomobject]@{ Title = "Claude ($($_.name))"; Args = "use $($_.name)"; Tip = "Switch Claude to $($_.name)" } })
    $items += [pscustomobject]@{ Title = 'Claude Accounts - Share sessions'; Args = 'sync'; Tip = 'Copy Code sessions across your Claude accounts' }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($d in $dirs) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        # Remove shortcuts this tool made for accounts that no longer exist.
        Get-ChildItem -LiteralPath $d -Filter 'Claude (*).lnk' -ErrorAction SilentlyContinue | ForEach-Object {
            $l = $shell.CreateShortcut($_.FullName)
            if ($l.Arguments.Contains($PSCommandPath) -and @($items.Title) -notcontains $_.BaseName) { Remove-Item -LiteralPath $_.FullName -Force }
        }
        foreach ($it in $items) {
            $lnk = $shell.CreateShortcut((Join-Path $d "$($it.Title).lnk"))
            $lnk.TargetPath = $ps
            $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($it.Args)"
            $lnk.WorkingDirectory = $PSScriptRoot
            $lnk.Description = $it.Tip
            if ($icon) { $lnk.IconLocation = "$icon,0" }
            $lnk.Save()
        }
    }
    Say ("Shortcuts ready in {0}." -f ($dirs -join ' and '))
}

# ---------- commands ----------

function Show-List($s) {
    Write-Host "Claude Desktop Switch $Version"
    Write-Host ("Live folder:  {0} ({1})" -f $AppData, $Live.Kind)
    Write-Host ("Shadow layer: {0}" -f $(if ($Shadow) { $Shadow } else { '-' }))
    Write-Host ("Python:       {0}" -f $(if ($Python) { $Python -join ' ' } else { 'missing: install Python 3.8 or newer' }))
    if ($Inside) { Write-Host 'Running inside Claude: switching works from the shortcuts or a normal PowerShell window.' }
    if ([IO.File]::Exists("$Config.journal")) { Write-Host 'Claude has a pending settings write. The next switch applies it.' }
    if (-not $s.slots -or $s.slots.Count -eq 0) { Write-Host 'Run setup to save your first account.'; return }
    foreach ($slot in $s.slots) {
        $mark = if ($slot.name -eq $s.active) { '*' } else { ' ' }
        $who = if ($slot.uuid) { $slot.uuid } else { '(waiting for first sign-in)' }
        Write-Host ("{0} {1,-16} {2}  saved {3}" -f $mark, $slot.name, $who, $slot.saved)
    }
}

function Read-SlotName([string]$prompt, [string]$taken) {
    while ($true) {
        $n = (Read-Host $prompt).Trim()
        if (-not (Test-SlotName $n)) { Write-Host 'Use letters, digits, - or _, up to 32 characters.'; continue }
        if ($taken -and $n -eq $taken) { Write-Host 'Pick a different name.'; continue }
        return $n
    }
}

function Open-ClaudeAfterRead {
    if (-not $NoPause -and -not $NoApp) { Read-Host 'Press Enter to open Claude' | Out-Null }
    Start-ClaudeApp
}

function Invoke-Add($s, [string]$NewName, [string]$LiveName, [switch]$Deferred) {
    Assert-SlotName $NewName
    if ($LiveName) { Assert-SlotName $LiveName }
    if (Get-Slot $s $NewName) { throw "An account named '$NewName' already exists." }
    if ($LiveName -and $LiveName -eq $NewName) { throw 'The two accounts need different names.' }
    if (-not $s.active -and -not $LiveName) { throw 'First run: name the account signed in now with -CurrentName, or run setup.' }
    if ($LiveName) {
        # Early hint; Save-Current checks again once the live login is final.
        $named = Get-Slot $s $LiveName
        if ($named -and $named.uuid -and $named.uuid -ne (Get-LiveUuid)) {
            throw "'$LiveName' belongs to a different account than the one in Claude now. Pick a new name with -CurrentName."
        }
    }
    Stop-ClaudeApp
    Resolve-Journal
    Clear-Shadow
    $saved = Save-Current $s $LiveName
    if (-not $saved -and -not $s.active) { throw "Claude needs a working login first. Sign in to the account for '$LiveName', then run again." }
    if ($saved) { $s.active = $saved }
    Save-State $s
    Sync-Sessions $s
    $stash = Move-LiveAside (Join-Path $StashRoot ("before-add-{0}" -f (Stamp)))
    Set-Slot $s $NewName ''
    $s.active = $NewName
    Save-State $s
    Say "Claude opens at the sign-in screen. Sign in with the account for '$NewName'."
    Say "Sign-in runs through your browser. If it lands on your other account, sign out of claude.ai in the browser and sign in again."
    Say "Your other login is saved and stays signed in. Safety copy: $stash"
    if (-not $Deferred) { Open-ClaudeAfterRead }
}

# ---------- main ----------

$exitCode = 0
$lock = $null
$paused = $false
$script:StoppedApp = $false
$script:KeepClosed = $false
try {
    $Python = Resolve-Python
    if ($AppData) {
        $Live = [pscustomobject]@{ Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($AppData); Kind = 'given'; Family = '' }
    } else {
        $Live = Find-LiveFolder
        if (-not $Live) { throw 'Open Claude and sign in once, then run this again.' }
    }
    $AppData = $Live.Path
    $Config = Join-Path $AppData 'config.json'
    $Shadow = ''
    if ($Live.Kind -eq 'package' -and -not $script:InsideView) {
        $exeFolder = Join-Path $env:APPDATA 'Claude'
        if ([IO.Directory]::Exists($exeFolder)) { $Shadow = $exeFolder }
    }
    $InstallRoots = Get-InstallRoots
    $Inside = Test-InsideClaude

    if ($Mutating) {
        if ($Inside -and -not $NoApp) {
            throw 'This runs from the Start menu shortcuts or a normal PowerShell window. Inside Claude, a switch would close the app that runs it.'
        }
        if (-not $Python) { throw 'Python 3.8 or newer is needed. Install it from python.org or with: winget install Python.Python.3.12' }
        $lock = New-Object Threading.Mutex($false, 'Local\ClaudeDesktopSwitch')
        try { $owned = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { $lock = $null; throw 'A switch is already running. Wait for it to finish.' }
        New-Item -ItemType Directory -Force -Path $Store, $SlotRoot, $StashRoot | Out-Null
        $script:LogEnabled = $true
    }
    $state = if ($Python) { Get-State } else { [pscustomobject]@{ active = ''; slots = @() } }

    switch ($Command) {
        'list' { Show-List $state }

        'setup' {
            Write-Host "Claude Desktop Switch $Version setup"
            if ($state.slots.Count -ge 2) {
                Write-Host 'Your accounts are saved. Refreshing the shortcuts.'
                Update-Shortcuts $state -WithDesktop
                Show-List $state
                break
            }
            if (-not (Get-LiveUuid)) { throw 'Sign in to Claude first, then run setup again.' }
            if ($state.slots.Count -eq 1) {
                # A first setup that stopped halfway: one account is saved, add the second.
                $first = if ($state.active) { $state.active } else { $state.slots[0].name }
                Write-Host "'$first' is saved. Name the account you want to add."
            } else {
                Write-Host 'Claude is signed in to one account now. Name it, then name the account you want to add.'
                $first = Read-SlotName 'Name for the account signed in now (for example personal)' ''
            }
            $second = Read-SlotName 'Name for the account to add (for example work)' $first
            Invoke-Add $state $second $first -Deferred
            Update-Shortcuts $state -WithDesktop
            Say "Done. Switch with the 'Claude ($first)' and 'Claude ($second)' shortcuts."
            Open-ClaudeAfterRead
        }

        'add' {
            if (-not $Name) { throw 'Give the new account a name, for example: add work' }
            Invoke-Add $state $Name $CurrentName
        }

        'use' {
            if (-not $Name) { throw 'Name the account to switch to, for example: use work' }
            Assert-SlotName $Name
            $target = Get-Slot $state $Name
            if (-not $target) { throw "Saved accounts: $(@($state.slots | ForEach-Object { $_.name }) -join ', '). '$Name' is outside that list." }
            # Check the saved login before closing Claude. The active account is the live
            # login and needs no saved copy yet; right after add it has none.
            if ($Name -ne $state.active -and $target.uuid) { Assert-SavedLogin $target }
            Stop-ClaudeApp
            Resolve-Journal
            Clear-Shadow
            $current = Save-Current $state ''
            if ($current) { $state.active = $current }
            Save-State $state
            Sync-Sessions $state
            if ($current -eq $Name) {
                Say "Already on '$Name'."
            } elseif (-not (Get-Slot $state $Name).uuid) {
                $stash = Move-LiveAside (Join-Path $StashRoot ("displaced-{0}" -f (Stamp)))
                $state.active = $Name
                Save-State $state
                Say "'$Name' waits for its first sign-in. Claude opens at the sign-in screen: sign in with the account for '$Name'."
                if ($current) { Say "You were signed in as '$current' again. If the browser does that, sign out of claude.ai in the browser first." }
            } else {
                Assert-SavedLogin (Get-Slot $state $Name)
                $stash = Move-LiveAside (Join-Path $StashRoot ("displaced-{0}" -f (Stamp)))
                try {
                    Restore-From (Join-Path $SlotRoot $Name)
                } catch {
                    Say "Restore failed: $($_.Exception.Message). Rolling back."
                    Undo-Restore $stash
                    throw
                }
                $state.active = $Name
                Save-State $state
                Say "Switched to '$Name'."
            }
            Remove-OldStashes
            Start-ClaudeApp
        }

        'sync' {
            if (@($state.slots | Where-Object { $_.uuid }).Count -lt 2) { throw 'Sessions are shared once two accounts have signed in.' }
            Stop-ClaudeApp
            Sync-Sessions $state
            Remove-OldStashes
            Start-ClaudeApp
        }

        'remove' {
            if (-not $Name) { throw 'Name the account to remove, for example: remove work' }
            Assert-SlotName $Name
            $gone = Get-Slot $state $Name
            if (-not $gone) { throw "'$Name' is outside your saved accounts." }
            if ($Name -eq $state.active -or ($gone.uuid -and $gone.uuid -eq (Get-LiveUuid))) { throw "'$Name' is the login Claude has now. Switch to another account first." }
            $dir = Join-Path $SlotRoot $Name
            if ([IO.Directory]::Exists($dir)) { Move-Path $dir (Join-Path $StashRoot ("removed-{0}-{1}" -f $Name, (Stamp))) }
            $state.slots = @($state.slots | Where-Object { $_.name -ne $Name })
            Save-State $state
            Say "Removed '$Name'. Its login is in the stash. Its sessions stay in Claude."
            Update-Shortcuts $state -WithDesktop:([IO.File]::Exists((Join-Path ([Environment]::GetFolderPath('Desktop')) "Claude ($Name).lnk")))
        }

        'shortcuts' {
            if ($state.slots.Count -eq 0) { throw 'Run setup to save your first account.' }
            Update-Shortcuts $state -WithDesktop:$Desktop
        }
    }
} catch {
    Say "ERROR: $($_.Exception.Message)"
    $exitCode = 1
    # Reopen Claude only when this run closed it and its folder holds one whole login.
    if ($script:StoppedApp -and -not $script:KeepClosed -and -not $NoApp -and (Get-ClaudeProcesses).Count -eq 0) {
        if (-not $NoPause) { Read-Host 'Press Enter to reopen Claude' | Out-Null; $paused = $true }
        Start-ClaudeApp
    }
} finally {
    if ($lock) { $lock.ReleaseMutex(); $lock.Dispose() }
}

if (-not $NoPause -and -not $paused) {
    if ($exitCode -ne 0) { Read-Host 'Press Enter to close' | Out-Null } elseif ($Command -ne 'list') { Start-Sleep -Seconds 3 }
}
exit $exitCode
