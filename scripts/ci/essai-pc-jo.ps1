#Requires -Version 7.2
# Essai de la mise a jour du PC de Jo AVANT un merge dans main (workflow .github/workflows/essai-pc-jo.yml).
# Sur un runner Windows jetable, avec les VRAIS scripts du repo :
#   pc-jo   : le PC part de main tel qu'il est avant la PR (checkout CRLF, taches planifiees reelles, snapshot
#             pousse) ; la PR est fusionnee sur un origin local (merge commit, comme le bouton GitHub) ; le PC la
#             recoit par auto-commit et par la CI de nuit ; les jumeaux des estimateurs sont installes a cote.
#             Verifie que rien de ce qui roule deja chez Jo ne change (scripts, taches, checkout, .claude).
#   pc-neuf : PC d'un estimateur sans mise ni Claude Code ; install-twin.ps1 installe ce qui manque.
# Rien ne sort du runner : « origin » est un depot nu local ; ni GitHub ni le PC de Jo ne sont contactes.
# Garde-fous : runner GitHub heberge seulement, et refus si %USERPROFILE%\dev\lena-ai-jo ou %USERPROFILE%\.claude
# existent deja (le script n'efface jamais rien qu'il n'a pas cree). Jamais sur un vrai PC.
# Sortie : tableau OK / FAIL / WARN + taux de succes ; code 1 si une verification obligatoire echoue.
[CmdletBinding()]
param(
    [string]$Source = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [ValidateSet('pc-jo', 'pc-neuf')][string]$Scenario = 'pc-jo'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:GIT_TERMINAL_PROMPT = '0'

$dev       = Join-Path $env:USERPROFILE 'dev'
$main      = Join-Path $dev 'lena-ai-jo'
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$hosted = ($IsWindows -and $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted')
$local  = (-not $IsWindows -and $env:LENA_ESSAI_LOCAL -eq '1')   # essai du script lui-meme, hors Windows
if (-not ($hosted -or $local)) { throw 'Refus : essai pour runner GitHub heberge seulement (il cree un faux PC de Jo dans %USERPROFILE%).' }
foreach ($p in $main, $claudeDir) {
    if (Test-Path $p) { throw "Refus : $p existe deja - ce n'est pas une machine jetable." }
}

$tmp    = $env:RUNNER_TEMP
$out    = if ($env:ESSAI_OUT) { $env:ESSAI_OUT } else { Join-Path $tmp 'essai-out' }
$origin = Join-Path $tmp 'origin.git'
New-Item -ItemType Directory -Force -Path $out, $dev | Out-Null
$script:checks = [Collections.Generic.List[object]]::new()

function Add-Check([string]$Name, [bool]$Ok, [string]$Detail = '', [bool]$Required = $true) {
    $script:checks.Add([pscustomobject]@{ Check = $Name; OK = $Ok; Required = $Required; Detail = $Detail })
    $mark = if ($Ok) { 'OK  ' } elseif ($Required) { 'FAIL' } else { 'WARN' }
    Write-Host ("[{0}] {1}{2}" -f $mark, $Name, $(if ($Detail) { " - $Detail" } else { '' }))
}

# Lance un script / une commande, garde toute la sortie dans un journal, renvoie le code de sortie.
function Invoke-Logged([string]$LogName, [scriptblock]$Block, [string]$WorkDir = $null) {
    $log = Join-Path $out "$LogName.log"
    $global:LASTEXITCODE = 0
    if ($WorkDir) { Push-Location $WorkDir }
    try { & $Block *>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log | Out-Null; $code = $LASTEXITCODE }
    catch { "$_" | Add-Content $log; $code = 1 }
    finally { if ($WorkDir) { Pop-Location } }
    Write-Host "  ($LogName : code $code)"
    $code
}

function Get-Sha([string]$Dir, [string]$Rev) { (git -C $Dir rev-parse -q --verify $Rev 2>$null | Out-String).Trim() }
function Get-Status([string]$Dir) { (git -C $Dir status --porcelain --untracked-files=all | Out-String).Trim() }
function Get-LogText([string]$LogName) { Get-Content -Raw (Join-Path $out "$LogName.log") -ErrorAction SilentlyContinue }

# Empreinte d'un dossier (contenu + chemins) : pour prouver qu'il n'a pas bouge.
function Get-TreeHash([string]$Dir) {
    if (-not (Test-Path $Dir)) { return '(absent)' }
    (Get-ChildItem $Dir -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        '{0} {1}' -f (Get-FileHash $_.FullName).Hash, [IO.Path]::GetRelativePath($Dir, $_.FullName) }) -join "`n"
}

# Definition des taches planifiees (ce qu'elles lancent, quand, a quel niveau) : pour prouver qu'elles n'ont pas bouge.
$taskNames = 'lena-claude-backup', 'lena-auto-commit', 'lena-nightly-ci', 'Desktop Commander Remote'
function Get-TaskDefs {
    foreach ($n in $taskNames) {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $t) { "$n | absente"; continue }
        $a = $t.Actions | Select-Object -First 1
        $trig = (@($t.Triggers) | ForEach-Object {
            '{0} {1} {2} {3}' -f ($_.CimClass.CimClassName -replace '^MSFT_Task', ''), ("$($_.StartBoundary)" -replace '^\d{4}-\d\d-\d\d', ''), $_.Delay, $_.Repetition.Interval }) -join ' ; '
        '{0} | {1} | {2} | {3} | {4}' -f $n, $a.Execute, $a.Arguments, $t.Principal.RunLevel, $trig
    }
}

function Write-Bilan {
    $failed = @($script:checks | Where-Object { -not $_.OK -and $_.Required })
    $warn   = @($script:checks | Where-Object { -not $_.OK -and -not $_.Required })
    $okN    = @($script:checks | Where-Object OK).Count
    $rate   = if ($script:checks.Count) { [math]::Round(100.0 * $okN / $script:checks.Count, 1) } else { 0 }
    $script:checks | Format-Table -AutoSize -Wrap Check, OK, Required, Detail | Out-String -Width 220 | Tee-Object -FilePath (Join-Path $out 'bilan.txt') | Write-Host
    $line = "Taux de succes ($Scenario) : $okN/$($script:checks.Count) ($rate %) - obligatoires en echec : $($failed.Count), avertissements : $($warn.Count)"
    Write-Host $line
    if ($env:GITHUB_STEP_SUMMARY) {
        $md = @("### Essai $Scenario", '', '| Verification | Resultat | Detail |', '|---|---|---|') + ($script:checks | ForEach-Object {
            "| $($_.Check) | $(if ($_.OK) { 'OK' } elseif ($_.Required) { '**FAIL**' } else { 'avertissement' }) | $(($_.Detail -replace '\|', '/') -replace '\r?\n', ' ') |" })
        ($md + '', "**$line**") | Add-Content -Path $env:GITHUB_STEP_SUMMARY
    }
    exit $(if ($failed) { 1 } else { 0 })
}

# --- Commits testes : main avant la PR, tete de la PR -----------------------------------------
if ($env:GITHUB_EVENT_NAME -eq 'pull_request') {
    # actions/checkout a pris le commit de merge de la PR : parent 1 = main, parent 2 = tete de la PR.
    $base = Get-Sha $Source 'HEAD^1'; $head = Get-Sha $Source 'HEAD^2'
} else {
    $base = Get-Sha $Source 'origin/main'; $head = Get-Sha $Source 'HEAD'
}
if (-not $base -or -not $head) { throw 'Commits introuvables : il faut un checkout complet (fetch-depth: 0) avec origin/main.' }
Write-Host "main avant la PR : $base`ntete de la PR    : $head"

# Origin local : main = avant la PR ; les branches des jumeaux = tete de la PR.
git init -q --bare -b main $origin
git -C $Source push -q $origin "${base}:refs/heads/main" "${head}:refs/heads/Estimateur-2" "${head}:refs/heads/estimateur-junior"
if ($LASTEXITCODE) { throw 'push vers origin local impossible' }

# Fusion de la PR dans main sur origin, par merge commit (« Create a merge commit »).
function Merge-PrIntoMain {
    $work = Join-Path $tmp 'merge-work'
    git clone -q --branch main $origin $work
    git -C $work config user.name 'GitHub (essai)'; git -C $work config user.email 'essai@example.invalid'
    $code = Invoke-Logged 'merge-pr' { git -C $work merge --no-ff -m "Merge pull request (essai) : $head" origin/Estimateur-2 }
    if ($code -eq 0) { git -C $work push -q origin main; $code = $LASTEXITCODE }
    Add-Check 'PR fusionnee dans main par merge commit, sans conflit' ($code -eq 0) (Get-Sha $origin 'main')
    if ($code -ne 0) { Write-Bilan }
}

# =================================================================================================
if ($Scenario -eq 'pc-neuf') {
    Write-Host "`n== PC neuf d'un estimateur (apres le merge) =="
    Merge-PrIntoMain
    git clone -q -c core.autocrlf=true --branch main $origin $main
    $code = Invoke-Logged 'install-twin' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'install-twin.ps1') -Branch Estimateur-2 -Remote $origin }
    Add-Check 'install-twin.ps1 sur PC neuf (code 0)' ($code -eq 0)
    $twin = Join-Path $dev 'lena-Estimateur-2'
    Add-Check 'jumeau Estimateur-2 sur sa branche' ((Test-Path $twin) -and ((Get-Sha $twin 'HEAD') -eq $head))
    Add-Check 'CLAUDE.local.md importe LENA.md' ((Test-Path "$twin/CLAUDE.local.md") -and ((Get-Content -Raw "$twin/CLAUDE.local.md") -match '@docs/LENA.md'))
    $launcher = Join-Path $dev 'lena-Estimateur-2.cmd'
    Add-Check 'lanceur ecrit' (Test-Path $launcher) $launcher
    Add-Check 'dossier de config du compte estimateur + settings.json' (Test-Path (Join-Path $env:USERPROFILE '.claude-routeur' 'settings.json'))
    Add-Check 'compte principal du PC jamais cree ni touche (.claude)' (-not (Test-Path $claudeDir))
    # Outils installes par le script : nouvelle session = PATH relu du registre.
    $env:Path = @((Join-Path $env:LOCALAPPDATA 'mise\shims'), (Join-Path $env:USERPROFILE '.local\bin'),
        [Environment]::GetEnvironmentVariable('Path', 'User'), [Environment]::GetEnvironmentVariable('Path', 'Machine'), $env:Path) -join ';'
    foreach ($t in 'mise', 'uv', 'node', 'claude') {
        $cmd = Get-Command $t -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        Add-Check "outil $t present apres le script" ([bool]$cmd) $(if ($cmd) { $cmd.Source } else { 'pas installe sur ce runner (reseau / winget) : voir install-twin.log' }) $false
    }
    if (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue) {
        $code = Invoke-Logged 'lanceur-version' { & $launcher --version }
        Add-Check 'lanceur : lance le vrai Claude Code (--version)' (($code -eq 0) -and ((Get-LogText 'lanceur-version') -match '\d+\.\d+\.\d+')) ((Get-LogText 'lanceur-version') -replace '\s+', ' ') $false
    }
    Write-Bilan
}

# =================================================================================================
# --- 1. Le PC de Jo AVANT la PR -------------------------------------------------------------------
Write-Host "`n== 1. PC de Jo avant la PR =="
git clone -q -c core.autocrlf=true --branch main $origin $main
Add-Check 'checkout principal sur main (avant la PR), fins de ligne Windows' ((Get-Sha $main 'HEAD') -eq $base) $base
New-Item -ItemType Directory -Force -Path (Join-Path $claudeDir 'projects' 'essai') | Out-Null
Copy-Item (Join-Path $main 'config' 'claude' '*') $claudeDir -Recurse -Force
'{"type":"user","message":"conversation d''essai"}' | Set-Content (Join-Path $claudeDir 'projects' 'essai' 'session.jsonl')
if ($IsWindows -and -not (Test-Path 'D:\')) {
    $dRoot = Join-Path $tmp 'drive-d'
    New-Item -ItemType Directory -Force -Path $dRoot | Out-Null
    subst D: $dRoot
}

$prod = 'scripts/auto-commit.ps1', 'scripts/lena-nightly.ps1', 'scripts/backup-claude.ps1', 'scripts/snapshot-config.ps1'
if ($IsWindows) {
    $code = Invoke-Logged 'install-tasks-avant' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'install-tasks.ps1') }
    Add-Check 'avant : taches planifiees creees par le script de main' ($code -eq 0)
    $tasksBefore = @(Get-TaskDefs)
    $tasksBefore | Set-Content (Join-Path $out 'taches-avant.txt')
    Add-Check 'avant : les 4 taches existent' (@($tasksBefore | Where-Object { $_ -match '\| absente$' }).Count -eq 0) ($tasksBefore -join ' // ')
}
$code = Invoke-Logged 'auto-commit-avant' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'auto-commit.ps1') }
Add-Check 'avant : auto-commit (snapshot + push) fonctionne' ($code -eq 0)
Add-Check 'avant : PC a jour avec origin' ((Get-Sha $main 'HEAD') -eq (Get-Sha $origin 'main'))

# Deux autres PC dans le meme etat « avant » : un pour le tirage simple, un pour le pire cas.
$nuit = Join-Path $tmp 'pc-nuit' 'lena-ai-jo'
$pire = Join-Path $tmp 'pc-pire-cas' 'lena-ai-jo'
foreach ($d in $nuit, $pire) { git clone -q -c core.autocrlf=true --branch main $origin $d }

# --- 2. La PR entre dans main -----------------------------------------------------------------------
Write-Host "`n== 2. Merge de la PR dans main (origin) =="
Merge-PrIntoMain
$merged = Get-Sha $origin 'main'

# --- 3. Le PC de Jo recoit la PR par ses taches planifiees ------------------------------------------
Write-Host "`n== 3. Le PC de Jo recoit la PR =="
# Un changement de config en attente (comme un jour normal) : auto-commit commite, tire main, pousse.
Add-Content -Path (Join-Path $claudeDir 'CLAUDE.md') -Value "`n<!-- essai : changement local en attente -->"
$code = Invoke-Logged 'auto-commit-apres' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'auto-commit.ps1') }
Get-Content (Join-Path $main 'scripts' 'auto-commit.log') -ErrorAction SilentlyContinue | Set-Content (Join-Path $out 'auto-commit.script.log')
Add-Check 'auto-commit apres le merge (code 0)' ($code -eq 0)
Add-Check 'la PR est arrivee sur le PC (install-twin.ps1, CLAUDE.md, skills)' (
    (Test-Path (Join-Path $main 'scripts' 'install-twin.ps1')) -and (Test-Path (Join-Path $main 'CLAUDE.md')) -and (Test-Path (Join-Path $main '.claude' 'skills' 'plan-qpl' 'SKILL.md')))
git -C $main merge-base --is-ancestor $merged HEAD
Add-Check 'main local contient le merge, et origin = local (snapshot pousse)' (($LASTEXITCODE -eq 0) -and ((Get-Sha $main 'HEAD') -eq (Get-Sha $origin 'main')))
$snapFiles = @(git -C $main diff --name-only "$merged" HEAD)
$outside = @($snapFiles | Where-Object { $_ -notmatch '^config/' -and $_ -ne 'docs/INVENTAIRE.md' })
Add-Check 'snapshot de Jo : seulement config/ et docs/INVENTAIRE.md' ($outside.Count -eq 0) "$($snapFiles.Count) fichier(s)$(if ($outside) { ' ; hors zone : ' + ($outside -join ', ') })"
Add-Check 'checkout principal propre (rien de modifie, rien en trop)' (-not (Get-Status $main)) (Get-Status $main)
git -C $main diff --quiet $base HEAD -- @prod
Add-Check 'scripts de production de Jo identiques a avant (auto-commit, nightly, backup, snapshot)' ($LASTEXITCODE -eq 0)

$code = Invoke-Logged 'nightly' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'lena-nightly.ps1') }
Get-Content (Join-Path $main 'scripts' 'lena-nightly.log') -ErrorAction SilentlyContinue | Set-Content (Join-Path $out 'nightly.script.log')
Add-Check 'CI de nuit apres le merge : pull + tests verts (code 0)' ($code -eq 0)

if ($IsWindows) {
    $code = Invoke-Logged 'backup-claude' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'backup-claude.ps1') }
    Add-Check 'sauvegarde des conversations (code 0, fichier copie)' (($code -eq 0) -and (Test-Path 'D:\Backups\claude\projects\essai\session.jsonl'))
    $code = Invoke-Logged 'install-tasks-apres' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'install-tasks.ps1') }
    $tasksAfter = @(Get-TaskDefs)
    $tasksAfter | Set-Content (Join-Path $out 'taches-apres.txt')
    Add-Check 'install-tasks.ps1 de la PR, depuis le checkout principal (code 0)' ($code -eq 0)
    Add-Check 'taches planifiees identiques a avant (commande, arguments, declencheurs, niveau)' (-not (Compare-Object $tasksBefore $tasksAfter))
}

$bash = if ($IsWindows) { Join-Path $env:ProgramFiles 'Git\bin\bash.exe' } else { 'bash' }
$code = Invoke-Logged 'sync-agents' { & $bash scripts/sync-agents.sh } $main
Add-Check 'sync-agents.sh sous Git Bash sur le checkout Windows (parite OK, rien de modifie)' (($code -eq 0) -and ((Get-LogText 'sync-agents') -match 'parity OK') -and -not (Get-Status $main)) (Get-Status $main)

# Tirage simple (la commande exacte des deux taches), sans rien en attente.
$code = Invoke-Logged 'pull-simple' { git -C $nuit pull --rebase --autostash origin main }
Add-Check 'tirage simple « git pull --rebase --autostash origin main » (code 0, propre)' (
    ($code -eq 0) -and (Test-Path (Join-Path $nuit 'scripts' 'install-twin.ps1')) -and -not (Get-Status $nuit))

# Pire cas : un fichier non suivi traine sur un chemin que la PR ajoute. Attendu : le tirage refuse,
# rien n'est perdu ni a moitie applique ; une fois le fichier deplace, le tirage passe.
$stray = Join-Path $pire 'scripts' 'install-twin.ps1'
'brouillon local' | Set-Content $stray
$pireHead = Get-Sha $pire 'HEAD'
$code = Invoke-Logged 'pull-pire-cas' { git -C $pire pull --rebase --autostash origin main }
$rebasing = (Test-Path (Join-Path $pire '.git' 'rebase-merge')) -or (Test-Path (Join-Path $pire '.git' 'rebase-apply'))
Add-Check 'pire cas (fichier non suivi sur un chemin de la PR) : tirage refuse net, rien de perdu' (
    ($code -ne 0) -and ((Get-Sha $pire 'HEAD') -eq $pireHead) -and ((Get-Content -Raw $stray) -match 'brouillon local') -and -not $rebasing) ((Get-LogText 'pull-pire-cas') -split '\r?\n' | Where-Object { $_ -match 'untracked|overwritten|error' } | Select-Object -First 1)
Move-Item $stray (Join-Path $tmp 'install-twin.brouillon.ps1')
$code = Invoke-Logged 'pull-pire-cas-repare' { git -C $pire pull --rebase --autostash origin main }
Add-Check 'pire cas : fichier deplace -> le tirage passe' (($code -eq 0) -and -not (Get-Status $pire))

# --- 4. Les jumeaux des estimateurs, a cote du checkout de Jo ---------------------------------------
Write-Host "`n== 4. Jumeaux des estimateurs sur le PC de Jo =="
# Faux « claude » (le PC de Jo a deja Claude Code) : il montre ce que le lanceur lui passe.
$stub = Join-Path $tmp 'faux-claude'
New-Item -ItemType Directory -Force -Path $stub | Out-Null
if ($IsWindows) {
    "@echo off`r`necho CFG=[%CLAUDE_CONFIG_DIR%]`r`necho CWD=[%CD%]`r`necho ARGS=[%*]`r`necho AUTOUPD=[%DISABLE_AUTOUPDATER%]`r`necho KEY=[%ANTHROPIC_API_KEY%]`r`nexit /b 0`r`n" | Set-Content (Join-Path $stub 'claude.cmd') -NoNewline
} else {
    "#!/bin/sh`necho faux claude`n" | Set-Content (Join-Path $stub 'claude') -NoNewline
    chmod +x (Join-Path $stub 'claude')
}
$env:Path = $stub + [IO.Path]::PathSeparator + $env:Path

$profBefore = Get-TreeHash $claudeDir
$mainHead = Get-Sha $main 'HEAD'
$code = Invoke-Logged 'install-twin' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'install-twin.ps1') -Branch 'Estimateur-2,estimateur-junior' -Remote $origin -NoInstall }
Add-Check 'install-twin.ps1 -Branch Estimateur-2,estimateur-junior (code 0, tests compris)' ($code -eq 0) ((Get-LogText 'install-twin') -split '\r?\n' | Where-Object { $_ -match '^Taux de succes' } | Select-Object -Last 1)
$twinLog = Get-LogText 'install-twin'
Add-Check 'tests des jumeaux verts (pytest plan-tools + code-rag, 2 jumeaux)' (@([regex]::Matches($twinLog, '(?m)^\[OK  \] \S+ : pytest ')).Count -eq 4) "$(@([regex]::Matches($twinLog, '(?m)^\[OK  \] \S+ : pytest ')).Count)/4"
foreach ($b in 'Estimateur-2', 'estimateur-junior') {
    $twin = Join-Path $dev "lena-$b"
    Add-Check "jumeau $b : sur sa branche, a la tete de la PR" ((Test-Path $twin) -and ((Get-Sha $twin 'HEAD') -eq $head) -and ((git -C $twin rev-parse --abbrev-ref HEAD | Out-String).Trim() -eq $b))
    Add-Check "jumeau $b : CLAUDE.local.md importe LENA.md, lanceur ecrit" (
        (Test-Path "$twin/CLAUDE.local.md") -and ((Get-Content -Raw "$twin/CLAUDE.local.md") -match '@docs/LENA.md') -and (Test-Path (Join-Path $dev "lena-$b.cmd")))
    Add-Check "jumeau $b : propre (CLAUDE.local.md ignore par git)" (-not (Get-Status $twin)) (Get-Status $twin)
}
$cfg = Join-Path $env:USERPROFILE '.claude-routeur'
$seedOk = $false
try {
    $s = Get-Content -Raw (Join-Path $cfg 'settings.json') | ConvertFrom-Json
    $seedOk = (-not $s.PSObject.Properties['statusLine']) -and (-not $s.PSObject.Properties['enabledPlugins']) -and ($s.env.DISABLE_AUTOUPDATER -eq '1')
} catch { }
Add-Check 'dossier de config du compte estimateur : settings.json seme (sans statusLine / enabledPlugins, auto-update coupe)' $seedOk $cfg
Add-Check 'compte principal de Jo (%USERPROFILE%\.claude) : pas un octet de change' ((Get-TreeHash $claudeDir) -eq $profBefore)
Add-Check 'checkout principal de Jo : meme commit, toujours propre' (((Get-Sha $main 'HEAD') -eq $mainHead) -and -not (Get-Status $main)) (Get-Status $main)

$code = Invoke-Logged 'install-tasks-depuis-jumeau' { pwsh -NoProfile -File (Join-Path $dev 'lena-Estimateur-2' 'scripts' 'install-tasks.ps1') }
Add-Check 'install-tasks.ps1 lance depuis un jumeau : refuse (code 1)' (($code -eq 1) -and ((Get-LogText 'install-tasks-depuis-jumeau') -match 'Refus'))
if ($IsWindows) {
    Add-Check 'taches planifiees toujours identiques apres les jumeaux' (-not (Compare-Object $tasksBefore @(Get-TaskDefs)))

    # Lanceur : bon dossier de config, bon dossier de travail, arguments passes, jeton API de l'environnement coupe.
    $launcher = Join-Path $dev 'lena-Estimateur-2.cmd'
    $env:ANTHROPIC_API_KEY = 'essai'
    $code = Invoke-Logged 'lanceur' { & $launcher --version }
    Remove-Item Env:ANTHROPIC_API_KEY
    $l = Get-LogText 'lanceur'
    Add-Check 'lanceur : CLAUDE_CONFIG_DIR = dossier du compte estimateur' ($l -match [regex]::Escape("CFG=[$cfg]")) (($l -split '\r?\n' | Where-Object { $_ -match '^CFG=' }) -join '')
    Add-Check 'lanceur : demarre dans le jumeau, passe les arguments' (($l -match [regex]::Escape("CWD=[$(Join-Path $dev 'lena-Estimateur-2')]")) -and ($l -match 'ARGS=\[--version\]') -and ($code -eq 0))
    Add-Check 'lanceur : auto-update coupe, jeton API de l''environnement efface' (($l -match 'AUTOUPD=\[1\]') -and ($l -match 'KEY=\[\]'))
    $env:CLAUDECODE = '1'
    $code = Invoke-Logged 'lanceur-heberge' { & $launcher --version }
    Remove-Item Env:CLAUDECODE
    Add-Check 'lanceur : refuse de partir depuis une session Claude (code 1, claude pas lance)' (($code -eq 1) -and ((Get-LogText 'lanceur-heberge') -notmatch 'CFG='))
}

# Relance (mise a jour d'un jumeau deja installe) : rien n'est reecrit, rien ne casse.
$localBefore = Get-TreeHash $cfg
$mdBefore = (Get-FileHash (Join-Path $dev 'lena-Estimateur-2' 'CLAUDE.local.md')).Hash
$code = Invoke-Logged 'install-twin-2' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'install-twin.ps1') -Branch 'Estimateur-2,estimateur-junior' -Remote $origin -NoInstall -SkipTests }
Add-Check 'install-twin.ps1 relance : code 0, CLAUDE.local.md et settings.json conserves' (
    ($code -eq 0) -and ((Get-TreeHash $cfg) -eq $localBefore) -and ((Get-FileHash (Join-Path $dev 'lena-Estimateur-2' 'CLAUDE.local.md')).Hash -eq $mdBefore))

# --- 5. Le lendemain : les taches de Jo tournent encore, jumeaux installes --------------------------
Write-Host "`n== 5. Apres l'installation des jumeaux =="
$code = Invoke-Logged 'auto-commit-final' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'auto-commit.ps1') }
Add-Check 'auto-commit fonctionne encore (code 0), PC a jour avec origin, checkout propre' (
    ($code -eq 0) -and ((Get-Sha $main 'HEAD') -eq (Get-Sha $origin 'main')) -and -not (Get-Status $main)) (Get-Status $main)

Write-Bilan
