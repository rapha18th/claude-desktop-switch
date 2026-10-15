<#
Hands running Code-session jobs over across an app restart or account switch.

Background jobs started by Claude Code keep running when the desktop app quits.
The resumed session starts with an empty task list, so it loses sight of them and
can start them a second time. This script closes that gap:

  JobHandover.ps1 capture [-Out <file>]
      Records every job running under a Code session: session id, folder, command,
      process ids and log files. The switcher runs this before it closes the app.

  JobHandover.ps1 hook
      SessionStart hook for Claude Code. Reads the hook JSON on stdin, finds jobs of
      this session or folder that outlived their session process, and prints them
      for the model to monitor. Prints nothing when there is nothing to hand over.
#>
param(
    [Parameter(Position = 0)][ValidateSet('capture', 'hook', 'list')][string]$Mode = 'list',
    [string]$Out = (Join-Path $env:LOCALAPPDATA 'ClaudeAccountSwitch\handover.json')
)

$ErrorActionPreference = 'Stop'

function Get-Processes {
    Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CommandLine, CreationDate
}

# A Claude Code tool call runs inside one of these wrappers.
function Test-ToolWrapper($p) {
    $c = [string]$p.CommandLine
    ($p.Name -eq 'bash.exe' -and $c -like '*/.claude/shell-snapshots/*') -or
    ($p.Name -eq 'powershell.exe' -and $c -like '*__claudeCodeScript*') -or
    ($p.Name -eq 'cmd.exe' -and $c -like '*__claudeCodeScript*')
}

function Get-SessionId([string]$cmd) {
    if ($cmd -match '--resume[= ]([0-9a-f-]{36})') { return $Matches[1] }
    if ($cmd -match '--session-id[= ]([0-9a-f-]{36})') { return $Matches[1] }
    return ''
}

function Convert-BashPath([string]$p) {
    if ($p -match '^/([a-zA-Z])/(.*)$') { return ('{0}:\{1}' -f $Matches[1].ToUpper(), ($Matches[2] -replace '/', '\')) }
    return $p
}

function Get-JobInfo($root, $all, [string]$sessionId) {
    $c = [string]$root.CommandLine
    $command = ''
    $dir = ''
    if ($c -match "eval '(.*)' < /dev/null") {
        $command = $Matches[1] -replace "'\\''", "'"
        if ($command -match '^\s*cd\s+("?)([^"&;]+)\1\s*&&') { $dir = Convert-BashPath $Matches[2].Trim() }
    } elseif ($c -like '*__claudeCodeScript*') {
        $command = '(PowerShell tool call; the command text lives in the session transcript)'
    }
    $logs = @([regex]::Matches($command, '(?<![0-9&])>>?\s*([^\s;&|<>]+)') | ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -notmatch '^/dev/' -and $_ -notmatch '^&' } | Select-Object -Unique)
    if ($dir) { $logs = @($logs | ForEach-Object { if ($_ -match '^(/|[A-Za-z]:)') { Convert-BashPath $_ } else { Join-Path $dir ($_ -replace '/', '\') } }) }
    $tree = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($root)
    while ($queue.Count -gt 0) {
        $n = $queue.Dequeue()
        $tree.Add($n)
        foreach ($k in $all | Where-Object { $_.ParentProcessId -eq $n.ProcessId }) { $queue.Enqueue($k) }
    }
    $work = @($tree | Where-Object { $_.Name -notin @('bash.exe', 'conhost.exe', 'cmd.exe') })
    $leaf = if ($work.Count -gt 0) { $work[-1] } else { $tree[-1] }
    [pscustomobject]@{
        sessionId = $sessionId
        dir       = $dir
        command   = $command
        logs      = $logs
        rootPid   = [int]$root.ProcessId
        workPid   = [int]$leaf.ProcessId
        workName  = $leaf.Name
        pids      = @($tree | ForEach-Object { [int]$_.ProcessId })
        started   = ([datetime]$root.CreationDate).ToString('s')
    }
}

# Jobs running under live Code sessions, tagged with their session id.
function Get-SessionJobs($all) {
    $clis = @($all | Where-Object { $_.Name -eq 'claude.exe' -and ([string]$_.CommandLine) -like '*\claude-code\*' })
    foreach ($cli in $clis) {
        $sid = Get-SessionId ([string]$cli.CommandLine)
        foreach ($w in $all | Where-Object { $_.ParentProcessId -eq $cli.ProcessId -and (Test-ToolWrapper $_) }) {
            Get-JobInfo $w $all $sid
        }
    }
}

# Tool wrappers whose session process has exited: jobs left running by an earlier app run.
function Get-OrphanJobs($all) {
    $alive = @{}
    foreach ($p in $all) { $alive[[int]$p.ProcessId] = $p }
    foreach ($w in $all | Where-Object { Test-ToolWrapper $_ }) {
        $parent = $alive[[int]$w.ParentProcessId]
        $parentIsWrapper = $parent -and (Test-ToolWrapper $parent)
        $parentIsCli = $parent -and $parent.Name -eq 'claude.exe'
        if (-not $parentIsWrapper -and -not $parentIsCli) { Get-JobInfo $w $all '' }
    }
}

function Read-Manifest([switch]$Recent) {
    if (-not (Test-Path $Out)) { return @() }
    try {
        $m = Get-Content $Out -Raw | ConvertFrom-Json
        if ($Recent -and ([datetime]$m.captured) -lt (Get-Date).AddHours(-12)) { return @() }
        return @($m.jobs)
    } catch { return @() }
}

switch ($Mode) {
    'capture' {
        $all = @(Get-Processes)
        $jobs = @(Get-SessionJobs $all)
        $dirOut = Split-Path $Out
        if (-not (Test-Path $dirOut)) { New-Item -ItemType Directory -Force $dirOut | Out-Null }
        # Keep earlier entries whose processes still run, so a second switch keeps the trail.
        $alive = @{}
        foreach ($p in $all) { $alive[[int]$p.ProcessId] = $true }
        $kept = @(Read-Manifest | Where-Object { $alive[[int]$_.workPid] -and ($jobs.rootPid -notcontains $_.rootPid) })
        [pscustomobject]@{ captured = (Get-Date).ToString('s'); jobs = @($kept + $jobs) } |
            ConvertTo-Json -Depth 5 | Set-Content -Path $Out -Encoding UTF8
        foreach ($j in $jobs) { Write-Output ("{0}  {1}" -f $j.workPid, ($j.command -replace '\s+', ' ').Substring(0, [Math]::Min(100, $j.command.Length))) }
    }

    'list' {
        $all = @(Get-Processes)
        'Running under sessions:'; Get-SessionJobs $all | Format-Table workPid, sessionId, dir, command -AutoSize | Out-String -Width 220
        'Orphaned (session process gone):'; Get-OrphanJobs $all | Format-Table workPid, dir, command -AutoSize | Out-String -Width 220
    }

    'hook' {
        try {
            $raw = [Console]::In.ReadToEnd()
            $in = if ($raw) { $raw | ConvertFrom-Json } else { [pscustomobject]@{} }
            $sid = [string]$in.session_id
            $cwd = [string]$in.cwd
            $all = @(Get-Processes)
            $manifest = @(Read-Manifest)
            $bySid = @{}
            foreach ($m in $manifest) { $bySid[[int]$m.rootPid] = $m.sessionId }
            $mine = @(Get-OrphanJobs $all | Where-Object {
                $owner = $bySid[[int]$_.rootPid]
                if ($owner) { $owner -eq $sid }
                elseif ($_.dir -and $cwd) { $_.dir.TrimEnd('\').StartsWith($cwd.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) }
                else { $false }
            })
            $alivePids = @{}
            foreach ($p in $all) { $alivePids[[int]$p.ProcessId] = $true }
            $finished = @(Read-Manifest -Recent | Where-Object { $_.sessionId -eq $sid -and -not $alivePids[[int]$_.workPid] })
            if ($mine.Count -eq 0 -and $finished.Count -eq 0) { exit 0 }

            $lines = New-Object System.Collections.Generic.List[string]
            if ($mine.Count -gt 0) {
                $lines.Add('Background jobs from an earlier run of this session are still running. The desktop app restarted (an account switch or app restart), and these jobs kept going outside the new task list. Treat them as yours: monitor them, and leave them running instead of starting them again.')
                foreach ($j in $mine) {
                    $lines.Add('')
                    $lines.Add(("- PID {0} ({1}), started {2}, folder {3}" -f $j.workPid, $j.workName, $j.started, $(if ($j.dir) { $j.dir } else { 'unknown' })))
                    $lines.Add(("  Command: {0}" -f $j.command))
                    foreach ($l in $j.logs) { $lines.Add(("  Log: {0}" -f $l)) }
                    $lines.Add(("  Wait for it: powershell -NoProfile -Command ""Wait-Process -Id {0} -ErrorAction SilentlyContinue"" (run in the background), then read the log." -f $j.workPid))
                    $lines.Add(("  Stop it: taskkill /PID {0} /T /F" -f $j.rootPid))
                }
            }
            if ($finished.Count -gt 0) {
                $lines.Add('')
                $lines.Add('Jobs of this session that finished during the restart. Read their logs for the result:')
                foreach ($j in $finished) {
                    $lines.Add(("- {0}" -f $j.command))
                    foreach ($l in $j.logs) { $lines.Add(("  Log: {0}" -f $l)) }
                }
            }
            $lines -join "`n"
        } catch {
            # A hook failure must never block a session.
        }
        exit 0
    }
}
