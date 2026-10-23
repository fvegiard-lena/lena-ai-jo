#Requires -Version 7
# Cree / met a jour les taches planifiees de Lena pour Jo.
#   lena-claude-backup        -> scripts\backup-claude.ps1  (ouverture de session + 03:00)
#   lena-auto-commit          -> scripts\auto-commit.ps1    (12:00 + ouverture de session +5 min)
#   lena-nightly-ci           -> scripts\lena-nightly.ps1   (02:00, rattrapee au reveil, 2 h max)
#   Desktop Commander Remote  -> desktop-commander remote --persist-session (relance si mort)
# Retire l'ancienne tache lena-ai-jo-copilot-sync.
# Usage : pwsh -File scripts\install-tasks.ps1 [-WhatIf]
# Pas besoin d'admin : tout tourne en RunLevel Limited sous le compte de Jo.
# Register-ScheduledTask -Force met a jour sur place (pas de Unregister : l'historique
# et une instance en cours ne sont pas coupes).
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
$repo    = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $repo 'scripts'

# Les taches doivent pointer sur le checkout principal (lena-ai-jo, branche main) : lancees depuis un
# jumeau (lena-<branche>, RUNBOOK section 11), auto-commit et nightly refuseraient de tourner a chaque fois.
$leaf   = Split-Path -Leaf $repo
$branch = (git -C $repo rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
if ($leaf -ne 'lena-ai-jo' -or $branch -ne 'main') {
    Write-Host "Refus : ce script doit etre lance depuis le checkout principal lena-ai-jo sur main (ici : '$leaf' sur '$branch')."
    Write-Host "Commande : pwsh -File `"`$env:USERPROFILE\dev\lena-ai-jo\scripts\install-tasks.ps1`""
    exit 1
}

# Alias Store de pwsh : stable d'une version a l'autre (jamais le chemin Program Files\WindowsApps\...7.x)
$pwsh = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
if (-not (Test-Path $pwsh)) { $pwsh = (Get-Command pwsh -ErrorAction Stop).Source }
$dc = Join-Path $env:LOCALAPPDATA 'mise\shims\desktop-commander.exe'
$dcTaskName = 'Desktop Commander Remote'

$user      = "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

function New-PwshAction([string]$Script) {
    New-ScheduledTaskAction -Execute $pwsh -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $scripts $Script))
}

function New-LogonTrigger([string]$Delay) {
    $t = New-ScheduledTaskTrigger -AtLogOn -User $user
    if ($Delay) { $t.Delay = $Delay }
    $t
}

# New-ScheduledTaskTrigger -At ecrit l'heure en UTC (« ...T16:00:00Z ») : la tache se decale
# d'une heure au changement d'heure. On reecrit StartBoundary en heure locale, sans « Z ».
function New-DailyTrigger([string]$At) {
    $t = New-ScheduledTaskTrigger -Daily -At $At
    $t.StartBoundary = (Get-Date $At).ToString('s')
    $t
}

$scriptSettings = @{
    MultipleInstances          = 'IgnoreNew'
    ExecutionTimeLimit         = New-TimeSpan -Hours 1
    StartWhenAvailable         = $true
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
}
$nightlySettings = $scriptSettings.Clone()
$nightlySettings.ExecutionTimeLimit = New-TimeSpan -Hours 2

# Desktop Commander : declencheur quotidien 00:05 repete chaque heure pendant 1 jour
$dcDaily = New-DailyTrigger '00:05'
$dcDaily.Repetition = (New-ScheduledTaskTrigger -Once -At '00:05' -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 1)).Repetition

$defs = @(
    @{
        Name        = 'lena-claude-backup'
        Description = 'Sauvegarde additive des conversations Claude vers D:\Backups\claude (repo lena-ai-jo).'
        Action      = New-PwshAction 'backup-claude.ps1'
        Triggers    = @((New-LogonTrigger), (New-DailyTrigger '03:00'))
        Settings    = New-ScheduledTaskSettingsSet @scriptSettings
    }
    @{
        Name        = 'lena-auto-commit'
        Description = 'Snapshot de la config + commit + push du repo lena-ai-jo.'
        Action      = New-PwshAction 'auto-commit.ps1'
        Triggers    = @((New-DailyTrigger '12:00'), (New-LogonTrigger 'PT5M'))
        Settings    = New-ScheduledTaskSettingsSet @scriptSettings
    }
    @{
        Name        = 'lena-nightly-ci'
        Description = 'CI locale de nuit : tests plan-tools + code-rag ; si rouge, correction par Claude Code headless (plafond 2 $). Voir docs\CI-CD.md.'
        Action      = New-PwshAction 'lena-nightly.ps1'
        Triggers    = @((New-DailyTrigger '02:00'))
        Settings    = New-ScheduledTaskSettingsSet @nightlySettings
    }
    @{
        Name        = $dcTaskName
        Description = 'Keeps the Desktop Commander remote device connected to mcp.desktopcommander.app so claude.ai can reach this machine.'
        Action      = New-ScheduledTaskAction -Execute $dc -Argument 'remote --persist-session'
        Triggers    = @((New-LogonTrigger 'PT1M'), $dcDaily)
        Settings    = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    }
)

function Format-Triggers($Triggers) {
    ($Triggers | ForEach-Object {
        $kind = $_.CimClass.CimClassName -replace '^MSFT_Task|Trigger$', ''
        $s = $kind
        if ($_.StartBoundary) { $s += ' ' + $_.StartBoundary }
        if ($_.Delay) { $s += " +$($_.Delay)" }
        if ($_.Repetition.Interval) { $s += " every $($_.Repetition.Interval) for $($_.Repetition.Duration)" }
        $s
    }) -join '; '
}

# --- Plan --------------------------------------------------------------------
Write-Host "pwsh : $pwsh"
$defs | ForEach-Object {
    [pscustomobject]@{
        Task      = $_.Name
        Execute   = $_.Action.Execute
        Arguments = $_.Action.Arguments
        Triggers  = Format-Triggers $_.Triggers
        RunLevel  = $principal.RunLevel
        TimeLimit = $_.Settings.ExecutionTimeLimit
    }
} | Format-List | Out-String | Write-Host

# --- Application -------------------------------------------------------------
foreach ($d in $defs) {
    if ($PSCmdlet.ShouldProcess($d.Name, 'Register-ScheduledTask -Force (creation ou mise a jour sur place)')) {
        Register-ScheduledTask -TaskName $d.Name -Description $d.Description -Action $d.Action -Trigger $d.Triggers `
            -Settings $d.Settings -Principal $principal -Force | Out-Null
    }
}

$old = 'lena-ai-jo-copilot-sync'
if (Get-ScheduledTask -TaskName $old -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($old, 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $old -Confirm:$false
    }
}

# --- Desktop Commander doit rester en ligne, et sous la tache --------------------
# Un process « desktop-commander ... remote » lance a la main (tache pas Running) n'a ni
# relance auto ni RunLevel garanti : on l'arrete et on relance la tache a la place.
$dcTask = Get-ScheduledTask -TaskName $dcTaskName -ErrorAction SilentlyContinue
$dcProcs = @(Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='desktop-commander.exe'" |
    Where-Object { $_.CommandLine -match 'desktop-commander.*\bremote\b' })
if ($dcTask -and $dcTask.State -ne 'Running') {
    foreach ($p in $dcProcs) {
        if ($PSCmdlet.ShouldProcess("PID $($p.ProcessId) ($($p.Name))", 'Stop-Process (desktop-commander remote hors tache)')) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    if ($PSCmdlet.ShouldProcess($dcTaskName, 'Start-ScheduledTask')) {
        if ($dcProcs) { Start-Sleep -Seconds 2 }  # laisse le relais liberer la session
        Start-ScheduledTask -TaskName $dcTaskName
    }
} elseif ($dcTask) {
    Write-Host "$dcTaskName : deja Running sous la tache ($($dcProcs.Count) process) - rien a faire"
}

# --- Etat resultant ----------------------------------------------------------
$defs.Name + $old | ForEach-Object {
    $t = Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue
    if (-not $t) { return [pscustomobject]@{ Task = $_; State = '(absente)' } }
    $i = $t | Get-ScheduledTaskInfo
    [pscustomobject]@{
        Task       = $_
        State      = $t.State
        LastRun    = $i.LastRunTime
        LastResult = '0x{0:X}' -f $i.LastTaskResult
        NextRun    = $i.NextRunTime
        Execute    = ($t.Actions | Select-Object -First 1).Execute
    }
} | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
