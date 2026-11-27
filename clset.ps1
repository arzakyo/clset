<#
.SYNOPSIS
    clset - Lightweight Windows CLI to schedule and toggle Claude 5-hour session window triggers.
#>

$ErrorActionPreference = "Stop"
$Version = "0.2.0"
$ConfigDir = Join-Path $env:USERPROFILE ".config\clset"
$ConfigPath = Join-Path $ConfigDir "config.json"
$TaskPrefix = "clset-"

$Command = if ($args.Count -gt 0) { [string]$args[0] } else { "status" }
$Rest = if ($args.Count -gt 1) { [string[]]$args[1..($args.Count - 1)] } else { @() }

function Get-DefaultPreset {
    return @{
        slots    = @("0930", "1430", "1930", "0030")
        defaults = @("0930", "0030")
        model    = "haiku"
        prompt   = "hi"
    }
}

function Normalize-Slot {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $clean = $Raw.Trim() -replace ":", ""
    if ($clean -match "^\d{3}$") { $clean = "0$clean" }
    if ($clean -notmatch "^([01]\d|2[0-3])[0-5]\d$") { return $null }
    return $clean
}

function Format-Slot {
    param([string]$Slot)
    return $Slot.Insert(2, ":")
}

function Get-AnchorSlots {
    param([string]$AnchorHHMM)
    $start = [datetime]::ParseExact($AnchorHHMM, "HHmm", $null)
    $result = @()
    for ($i = 0; $i -lt 4; $i++) {
        $result += $start.AddHours($i * 5).ToString("HHmm")
    }
    return $result
}

function Get-Config {
    if (Test-Path $ConfigPath) {
        try {
            $cfg = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
            return @{
                slots    = @($cfg.slots | ForEach-Object { [string]$_ })
                defaults = @($cfg.defaults | ForEach-Object { [string]$_ })
                model    = if ($cfg.model) { [string]$cfg.model } else { "haiku" }
                prompt   = if ($cfg.prompt) { [string]$cfg.prompt } else { "hi" }
            }
        } catch {
            Write-Warning "Failed to parse $ConfigPath; using default preset."
        }
    }
    return Get-DefaultPreset
}

function Save-Config {
    param([hashtable]$Config)
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $Config | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -Path $ConfigPath
}

function Get-ClsetTasks {
    Get-ScheduledTask -TaskName "${TaskPrefix}*" -ErrorAction SilentlyContinue
}

function New-ClsetAction {
    param([hashtable]$Config)
    $claudeCmd = "claude -p $($Config.prompt) --model $($Config.model) --no-session-persistence --safe-mode"
    return New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -Command `"$claudeCmd`""
}

function New-ClsetSettings {
    return New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
}

function Resolve-TargetSlots {
    param([hashtable]$Config, [string[]]$Inputs)
    $tokens = @()
    foreach ($item in $Inputs) {
        if (-not [string]::IsNullOrWhiteSpace($item)) {
            $tokens += ($item -split ",") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
    }
    if ($tokens.Count -eq 0) { return @() }

    $resolved = @()
    foreach ($tok in $tokens) {
        $t = $tok.Trim().ToLower()
        if ($t -match "^s?(\d+)$" -and $t.Length -le 2) {
            $idx = [int]$Matches[1]
            if ($idx -lt 1 -or $idx -gt $Config.slots.Count) {
                throw "Session '$tok' out of range (1..$($Config.slots.Count))."
            }
            $slot = $Config.slots[$idx - 1]
        } else {
            $slot = Normalize-Slot $t
            if (-not $slot) {
                throw "Invalid session or time '$tok'. Use session number (1..$($Config.slots.Count)) or HH:mm / HHmm."
            }
        }
        if ($resolved -notcontains $slot) { $resolved += $slot }
    }
    return $resolved
}

function Show-Status {
    $cfg = Get-Config
    $taskMap = @{}
    foreach ($t in (Get-ClsetTasks)) {
        $taskMap[$t.TaskName.Substring($TaskPrefix.Length)] = $t
    }
    if ($taskMap.Count -eq 0) {
        Write-Host "No clset tasks installed. Run: clset init" -ForegroundColor Yellow
        return
    }

    $orderedSlots = @()
    foreach ($s in $cfg.slots) {
        if ($taskMap.ContainsKey($s)) { $orderedSlots += $s }
    }
    foreach ($k in ($taskMap.Keys | Sort-Object)) {
        if ($orderedSlots -notcontains $k) { $orderedSlots += $k }
    }

    $rows = for ($i = 0; $i -lt $orderedSlots.Count; $i++) {
        $slot = $orderedSlots[$i]
        $t = $taskMap[$slot]
        $info = $t | Get-ScheduledTaskInfo
        $isDef = if ($cfg.defaults -contains $slot) { "yes" } else { "" }
        $nextRun = if ($info.NextRunTime -and $info.NextRunTime.Year -gt 1900) { $info.NextRunTime.ToString("yyyy-MM-dd HH:mm") } else { "-" }
        $lastRun = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 1900) { $info.LastRunTime.ToString("yyyy-MM-dd HH:mm") } else { "-" }
        [pscustomobject]@{
            Session = $i + 1
            Time    = Format-Slot $slot
            State   = $t.State
            Default = $isDef
            NextRun = $nextRun
            LastRun = $lastRun
        }
    }
    $rows | Format-Table -AutoSize
}

function Register-AllSlots {
    param([hashtable]$Config)
    Get-ClsetTasks | ForEach-Object {
        $existing = $_.TaskName.Substring($TaskPrefix.Length)
        if ($Config.slots -notcontains $existing) {
            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false
        }
    }

    $action = New-ClsetAction $Config
    $settings = New-ClsetSettings

    foreach ($slot in $Config.slots) {
        $taskName = "$TaskPrefix$slot"
        $trigger = New-ScheduledTaskTrigger -Daily -At (Format-Slot $slot)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
        if ($Config.defaults -notcontains $slot) {
            Disable-ScheduledTask -TaskName $taskName | Out-Null
        }
    }
}

function Invoke-Init {
    param([string[]]$ArgsList)
    $cfg = Get-Config
    $slots = $null
    $defaults = $null
    $anchor = $null
    $usePreset = $false

    for ($i = 0; $i -lt $ArgsList.Count; $i++) {
        switch ($ArgsList[$i]) {
            "--preset"  { $usePreset = $true }
            "--anchor"  { if ($i + 1 -lt $ArgsList.Count) { $anchor = $ArgsList[++$i] } }
            "--slots"   { if ($i + 1 -lt $ArgsList.Count) { $slots = $ArgsList[++$i] -split "," } }
            "--default" { if ($i + 1 -lt $ArgsList.Count) { $defaults = $ArgsList[++$i] -split "," } }
            "--model"   { if ($i + 1 -lt $ArgsList.Count) { $cfg.model = $ArgsList[++$i] } }
            "--prompt"  { if ($i + 1 -lt $ArgsList.Count) { $cfg.prompt = $ArgsList[++$i] } }
        }
    }

    if ($usePreset) {
        $preset = Get-DefaultPreset
        $cfg.slots = $preset.slots
        $cfg.defaults = $preset.defaults
    }

    if ($anchor) {
        $normAnchor = Normalize-Slot $anchor
        if (-not $normAnchor) { throw "Invalid --anchor time '$anchor'. Use HH:mm or HHmm (e.g. 09:30)." }
        $cfg.slots = Get-AnchorSlots $normAnchor
        if (-not $defaults) {
            $cfg.defaults = @($cfg.slots[0], $cfg.slots[3])
        }
    }

    if ($slots) {
        $parsed = @()
        foreach ($s in $slots) {
            $n = Normalize-Slot $s
            if (-not $n) { throw "Invalid slot '$s'. Use HH:mm or HHmm." }
            $parsed += $n
        }
        $cfg.slots = $parsed
    }

    if ($defaults) {
        $parsedDef = @()
        foreach ($d in $defaults) {
            if ($d -match "^s?(\d+)$" -and $d.Length -le 2) {
                $idx = [int]$Matches[1]
                if ($idx -lt 1 -or $idx -gt $cfg.slots.Count) { throw "Default session '$d' out of range." }
                $parsedDef += $cfg.slots[$idx - 1]
            } else {
                $n = Normalize-Slot $d
                if (-not $n) { throw "Invalid default '$d'. Use session number or HH:mm." }
                $parsedDef += $n
            }
        }
        $cfg.defaults = $parsedDef
    }

    Save-Config $cfg
    Register-AllSlots $cfg
    Show-Status
}

function Set-SlotsState {
    param([string[]]$Slots, [string]$Mode)
    $tasks = @()
    if (-not $Slots -or $Slots.Count -eq 0) {
        $tasks = @(Get-ClsetTasks)
    } else {
        foreach ($s in $Slots) {
            $t = Get-ScheduledTask -TaskName "$TaskPrefix$s" -ErrorAction SilentlyContinue
            if ($t) { $tasks += $t }
            else { Write-Host "No scheduled task for $(Format-Slot $s). Run: clset init" -ForegroundColor Yellow }
        }
    }

    if ($tasks.Count -eq 0) {
        Write-Host "No matching clset tasks found. Run: clset init" -ForegroundColor Yellow
        return
    }

    foreach ($t in $tasks) {
        switch ($Mode) {
            "on"     { Enable-ScheduledTask -TaskName $t.TaskName | Out-Null }
            "off"    { Disable-ScheduledTask -TaskName $t.TaskName | Out-Null }
            "toggle" {
                if ($t.State -eq "Disabled") { Enable-ScheduledTask -TaskName $t.TaskName | Out-Null }
                else { Disable-ScheduledTask -TaskName $t.TaskName | Out-Null }
            }
        }
    }
    Show-Status
}

function Invoke-SetSession {
    param([string[]]$ArgsList)
    if ($ArgsList.Count -lt 2) {
        throw "Usage: clset set <session#> <HH:mm>   (example: clset set 2 15:00)"
    }
    $cfg = Get-Config
    $sel = $ArgsList[0].Trim().ToLower()
    if ($sel -notmatch "^s?(\d+)$") {
        throw "First argument must be a session number (1..$($cfg.slots.Count))."
    }
    $idx = [int]$Matches[1]
    if ($idx -lt 1 -or $idx -gt $cfg.slots.Count) {
        throw "Session $idx out of range (1..$($cfg.slots.Count))."
    }
    $newSlot = Normalize-Slot $ArgsList[1]
    if (-not $newSlot) {
        throw "Invalid time '$($ArgsList[1])'. Use HH:mm or HHmm (e.g. 15:00)."
    }

    $oldSlot = $cfg.slots[$idx - 1]
    if ($oldSlot -ne $newSlot -and ($cfg.slots -contains $newSlot)) {
        throw "Time $(Format-Slot $newSlot) is already configured in another session."
    }

    $oldTask = Get-ScheduledTask -TaskName "$TaskPrefix$oldSlot" -ErrorAction SilentlyContinue
    $wasDisabled = $oldTask -and ($oldTask.State -eq "Disabled")

    $cfg.slots[$idx - 1] = $newSlot
    if ($cfg.defaults -contains $oldSlot) {
        $cfg.defaults = @($cfg.defaults | ForEach-Object { if ($_ -eq $oldSlot) { $newSlot } else { $_ } })
    }
    Save-Config $cfg

    if ($oldTask -and $oldSlot -ne $newSlot) {
        Unregister-ScheduledTask -TaskName "$TaskPrefix$oldSlot" -Confirm:$false
    }
    $newTaskName = "$TaskPrefix$newSlot"
    Register-ScheduledTask -TaskName $newTaskName -Action (New-ClsetAction $cfg) -Trigger (New-ScheduledTaskTrigger -Daily -At (Format-Slot $newSlot)) -Settings (New-ClsetSettings) -Force | Out-Null
    if ($wasDisabled) {
        Disable-ScheduledTask -TaskName $newTaskName | Out-Null
    }
    Show-Status
}

function Invoke-AddSession {
    param([string[]]$ArgsList)
    if ($ArgsList.Count -lt 1) {
        throw "Usage: clset add <HH:mm> [--off]   (example: clset add 22:00)"
    }
    $cfg = Get-Config
    $newSlot = Normalize-Slot $ArgsList[0]
    if (-not $newSlot) { throw "Invalid time '$($ArgsList[0])'. Use HH:mm or HHmm." }
    if ($cfg.slots -contains $newSlot) { throw "Time $(Format-Slot $newSlot) already exists." }

    $startOff = $ArgsList -contains "--off"
    $cfg.slots += $newSlot
    Save-Config $cfg

    $taskName = "$TaskPrefix$newSlot"
    Register-ScheduledTask -TaskName $taskName -Action (New-ClsetAction $cfg) -Trigger (New-ScheduledTaskTrigger -Daily -At (Format-Slot $newSlot)) -Settings (New-ClsetSettings) -Force | Out-Null
    if ($startOff) { Disable-ScheduledTask -TaskName $taskName | Out-Null }
    Show-Status
}

function Invoke-DelSession {
    param([string[]]$ArgsList)
    if ($ArgsList.Count -lt 1) {
        throw "Usage: clset del <session#|HH:mm>   (example: clset del 5)"
    }
    $cfg = Get-Config
    $targets = Resolve-TargetSlots -Config $cfg -Inputs $ArgsList
    foreach ($s in $targets) {
        $cfg.slots = @($cfg.slots | Where-Object { $_ -ne $s })
        $cfg.defaults = @($cfg.defaults | Where-Object { $_ -ne $s })
        if (Get-ScheduledTask -TaskName "$TaskPrefix$s" -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName "$TaskPrefix$s" -Confirm:$false
        }
    }
    Save-Config $cfg
    Show-Status
}

function Show-Help {
    @"
clset v$Version - Schedule & toggle Claude 5-hour session window triggers (Windows)

Default Preset (4 sessions):
  Session 1: 09:30 (ON)   Session 2: 14:30 (OFF)
  Session 3: 19:30 (OFF)  Session 4: 00:30 (ON)

Usage:
  clset | status | list | ls        Show all sessions, state, next/last run
  clset init [options]              Install/update tasks
      --preset                      Reset to default 4-session preset (09:30,14:30,19:30,00:30)
      --anchor  <HH:mm>             Auto-generate 4x 5h sessions from anchor time
      --slots   <t1,t2,...>         Custom comma-separated times
      --default <1,4|t1,t2>         Sessions enabled by default (numbers or times)
      --model   <name>              Claude model alias (default: haiku)
      --prompt  <text>              Minimal trigger prompt (default: hi)

  Toggle (accepts session # like 1, 2, 3, 4 OR time like 14:30 / 1430):
  clset on  [1 2 ...]               Enable all sessions, or specific ones
  clset off [2 3 ...]               Disable all sessions, or specific ones
  clset toggle [2 ...]              Flip all sessions, or specific ones
  clset <1|2|3|4|HH:mm>             Quick-toggle a session (e.g. clset 2, clset 14:30)
  clset default                     Restore default ON/OFF states

  Customize Sessions:
  clset set <#> <HH:mm>             Change a session's time (e.g. clset set 2 15:00)
  clset add <HH:mm> [--off]         Add a custom extra session (e.g. clset add 22:00)
  clset del <#|HH:mm>               Delete a session (e.g. clset del 5)
  clset preset                      Reset back to the default 4-session preset

  Other:
  clset test [#|--direct]           Fire a trigger now (--direct runs claude here)
  clset remove                      Delete all clset scheduled tasks
  clset version                     Print version
"@ | Write-Host
}

$cmd = $Command.ToLower()

switch ($cmd) {
    "status"    { Show-Status }
    "list"      { Show-Status }
    "ls"        { Show-Status }
    "init"      { Invoke-Init -ArgsList $Rest }
    "install"   { Invoke-Init -ArgsList $Rest }
    "preset"    { Invoke-Init -ArgsList @("--preset") }
    "on"        {
        $cfg = Get-Config
        $targets = Resolve-TargetSlots -Config $cfg -Inputs $Rest
        Set-SlotsState -Slots $targets -Mode "on"
    }
    "off"       {
        $cfg = Get-Config
        $targets = Resolve-TargetSlots -Config $cfg -Inputs $Rest
        Set-SlotsState -Slots $targets -Mode "off"
    }
    "toggle"    {
        $cfg = Get-Config
        $targets = Resolve-TargetSlots -Config $cfg -Inputs $Rest
        Set-SlotsState -Slots $targets -Mode "toggle"
    }
    "set"       { Invoke-SetSession -ArgsList $Rest }
    "add"       { Invoke-AddSession -ArgsList $Rest }
    "del"       { Invoke-DelSession -ArgsList $Rest }
    "rm"        { Invoke-DelSession -ArgsList $Rest }
    "default"   {
        $cfg = Get-Config
        foreach ($slot in $cfg.slots) {
            $taskName = "$TaskPrefix$slot"
            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
                if ($cfg.defaults -contains $slot) { Enable-ScheduledTask -TaskName $taskName | Out-Null }
                else { Disable-ScheduledTask -TaskName $taskName | Out-Null }
            }
        }
        Show-Status
    }
    "test"      {
        $arg1 = if ($Rest.Count -gt 0) { $Rest[0] } else { "" }
        if ($arg1 -eq "--direct") {
            $cfg = Get-Config
            Write-Host "Running: claude -p $($cfg.prompt) --model $($cfg.model) --no-session-persistence --safe-mode"
            & claude -p $cfg.prompt --model $cfg.model --no-session-persistence --safe-mode
        } else {
            $cfg = Get-Config
            $targets = Resolve-TargetSlots -Config $cfg -Inputs $Rest
            $taskName = if ($targets.Count -gt 0) { "$TaskPrefix$($targets[0])" } else { (Get-ClsetTasks | Select-Object -First 1).TaskName }
            if (-not $taskName) { Write-Host "No clset tasks installed. Run: clset init" -ForegroundColor Yellow; break }
            Start-ScheduledTask -TaskName $taskName
            Write-Host "Triggered $taskName."
        }
    }
    "remove"    {
        $tasks = Get-ClsetTasks
        if (-not $tasks) { Write-Host "No clset tasks to remove." }
        else {
            $tasks | Unregister-ScheduledTask -Confirm:$false
            Write-Host "Removed $($tasks.Count) clset task(s)."
        }
    }
    "version"   { Write-Host "clset $Version" }
    "--version" { Write-Host "clset $Version" }
    "-v"        { Write-Host "clset $Version" }
    "help"      { Show-Help }
    "--help"    { Show-Help }
    "-h"        { Show-Help }
    default     {
        $cfg = Get-Config
        try {
            $targets = Resolve-TargetSlots -Config $cfg -Inputs (@($Command) + $Rest)
            Set-SlotsState -Slots $targets -Mode "toggle"
        } catch {
            Write-Host "Unknown command: $Command" -ForegroundColor Red
            Show-Help
            exit 1
        }
    }
}
