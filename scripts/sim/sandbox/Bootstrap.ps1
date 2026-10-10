# Dans Windows Sandbox (Windows PowerShell 5.1, rien d'installe). Appele par JoPc.wsb.
# 1. Installe Git for Windows, PowerShell 7, mise, Claude Code (version de config\VERSIONS.md).
# 2. Clone la branche testee depuis GitHub (lecture seule : rien n'est jamais pousse).
# 3. Lance scripts\sim\Test-JoPc.ps1 (meme verification que la CI GitHub).
# 4. Lance les vraies taches planifiees via le Planificateur (session interactive, comme chez Jo)
#    et verifie leur code de retour. Desktop Commander est exclu (appairage = PC de Jo seulement).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$hostDir = 'C:\sim\host'
$out = Join-Path $hostDir 'out'
$work = 'C:\sim\work'
New-Item -ItemType Directory -Force -Path $out, $work | Out-Null
Start-Transcript -Path (Join-Path $out 'bootstrap.log') -Force | Out-Null
$branch = (Get-Content (Join-Path $hostDir 'branch.txt') -Raw).Trim()

function Get-Asset([string]$Repo, [string]$Pattern) {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'lena-sim' }
    $a = $rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $a) { throw "Aucun fichier $Pattern dans $Repo" }
    $dst = Join-Path $work $a.name
    Invoke-WebRequest $a.browser_download_url -OutFile $dst -UseBasicParsing
    $dst
}

function Update-Path {
    $env:Path = @(
        (Join-Path $env:LOCALAPPDATA 'mise\shims'),
        (Join-Path $env:USERPROFILE '.local\bin'),
        [Environment]::GetEnvironmentVariable('Path', 'User'),
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
    ) -join ';'
}

Write-Host '== Git for Windows'
Start-Process (Get-Asset 'git-for-windows/git' '^Git-[\d.]+-64-bit\.exe$') -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL' -Wait
Write-Host '== PowerShell 7'
Start-Process msiexec.exe -ArgumentList '/i', (Get-Asset 'PowerShell/PowerShell' 'win-x64\.msi$'), '/qn', '/norestart' -Wait
Write-Host '== mise (winget absent de la Sandbox : archive officielle)'
$miseZip = Get-Asset 'jdx/mise' '^mise-v[\d.]+-windows-x64\.zip$'
Expand-Archive $miseZip -DestinationPath (Join-Path $env:LOCALAPPDATA 'mise-dist') -Force
$miseBin = Split-Path (Get-ChildItem (Join-Path $env:LOCALAPPDATA 'mise-dist') -Recurse -Filter mise.exe | Select-Object -First 1).FullName
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
[Environment]::SetEnvironmentVariable('Path', "$miseBin;$(Join-Path $env:LOCALAPPDATA 'mise\shims');$userPath", 'User')
Update-Path

Write-Host "== Clone $branch"
$src = 'C:\sim\source'
if (Test-Path $src) { Remove-Item -Recurse -Force $src }
git clone --quiet --branch $branch https://github.com/fvegiard-lena/lena-ai-jo.git $src
if ($LASTEXITCODE -ne 0) { throw 'git clone a echoue' }

Write-Host '== Claude Code'
$v = (Select-String -Path (Join-Path $src 'config\VERSIONS.md') -Pattern '^\| `claude --version` \| ([0-9.]+)').Matches[0].Groups[1].Value
pwsh -NoProfile -Command "& ([scriptblock]::Create((Invoke-RestMethod https://claude.ai/install.ps1))) $v"
Update-Path

Write-Host '== Simulateur'
$env:RUNNER_TEMP = 'C:\sim\tmp'
$env:SIM_OUT = $out
New-Item -ItemType Directory -Force -Path $env:RUNNER_TEMP | Out-Null
pwsh -NoProfile -File (Join-Path $src 'scripts\sim\Test-JoPc.ps1') -Source $src
$simCode = $LASTEXITCODE

Write-Host '== Taches planifiees (Planificateur, session interactive)'
$taskLines = @()
$taskOk = $true
foreach ($n in 'lena-claude-backup', 'lena-auto-commit', 'lena-nightly-ci') {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if (-not $t) { $taskLines += "FAIL $n : absente"; $taskOk = $false; continue }
    $before = ($t | Get-ScheduledTaskInfo).LastRunTime
    Start-ScheduledTask -TaskName $n
    $deadline = (Get-Date).AddMinutes(15)
    do {
        Start-Sleep -Seconds 5
        $info = Get-ScheduledTaskInfo -TaskName $n
        $state = (Get-ScheduledTask -TaskName $n).State
    } while (($state -eq 'Running' -or $info.LastRunTime -eq $before) -and (Get-Date) -lt $deadline)
    $res = '0x{0:X}' -f $info.LastTaskResult
    $ok = ($info.LastRunTime -ne $before) -and ($info.LastTaskResult -eq 0)
    if (-not $ok) { $taskOk = $false }
    $taskLines += ('{0} {1} : resultat {2}, etat {3}' -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $n, $res, $state)
}
$taskLines | Tee-Object -FilePath (Join-Path $out 'taches-planifiees.txt') | Write-Host

$verdict = if ($simCode -eq 0 -and $taskOk) { 'VERT' } else { 'ROUGE' }
"Simulateur : code $simCode ; taches planifiees : $(if ($taskOk) { 'OK' } else { 'FAIL' }) ; verdict $verdict" |
    Tee-Object -FilePath (Join-Path $out 'verdict.txt') | Write-Host
Write-Host ''
Write-Host 'Test avec le vrai Claude (optionnel, ~1 $ max) :'
Write-Host '  1. Ouvre un terminal, tape : claude   puis /login'
Write-Host '  2. pwsh -File C:\sim\host\Start-RealLoop.ps1'
Stop-Transcript | Out-Null
