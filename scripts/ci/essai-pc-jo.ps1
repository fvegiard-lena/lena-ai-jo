#Requires -Version 7.2
# Essai de la mise a jour du PC de Jo AVANT un merge dans main (workflow .github/workflows/essai-pc-jo.yml).
# Sur un runner Windows jetable, avec les VRAIS scripts du repo :
#   pc-jo   : le PC part de main tel qu'il est avant la PR (checkout CRLF, taches planifiees reelles, snapshot
#             pousse, Claude Code et shims mise en place) ; la PR est fusionnee sur un origin local (merge commit,
#             comme le bouton GitHub) ; un PC la recoit par auto-commit, un autre par la CI de nuit ; les jumeaux
#             des estimateurs sont installes a cote. Verifie que rien de ce qui roule deja chez Jo ne change :
#             scripts de production, taches planifiees, checkout complet, %USERPROFILE%\.claude et .claude.json,
#             config git globale ; au profil, seuls s'ajoutent le dossier de config du compte estimateur et, au
#             PATH utilisateur, les shims mise (une fois). Rejoue avec la vraie tache de nuit les trois cas ou le
#             tirage bloque (RUNBOOK section 11), et leur reparation.
#   pc-neuf : PC d'un estimateur sans mise ni Claude Code ; install-twin.ps1 installe ce qui manque.
# Rien ne sort du runner : « origin » est un depot nu local ; ni GitHub ni le PC de Jo ne sont contactes.
# Garde-fous : sous Windows, runner GitHub heberge seulement ; refus si %USERPROFILE%\dev\lena-ai-jo,
# %USERPROFILE%\.claude ou %USERPROFILE%\.claude.json existent deja (le script n'efface jamais rien qu'il n'a pas
# cree). Jamais sur un vrai PC. Hors Windows : seulement avec LENA_ESSAI_LOCAL=1 et un USERPROFILE jetable (mise au
# point du script lui-meme ; les parties propres a Windows y sont sautees).
# Sortie : tableau OK / FAIL / WARN + taux de succes ; code 1 si une verification obligatoire echoue.
[CmdletBinding()]
param(
    [string]$Source = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [ValidateSet('pc-jo', 'pc-neuf')][string]$Scenario = 'pc-jo'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:GIT_TERMINAL_PROMPT = '0'

$dev        = Join-Path $env:USERPROFILE 'dev'
$main       = Join-Path $dev 'lena-ai-jo'
$claudeDir  = Join-Path $env:USERPROFILE '.claude'
$claudeJson = Join-Path $env:USERPROFILE '.claude.json'
$hosted = ($IsWindows -and $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted')
$local  = (-not $IsWindows -and $env:LENA_ESSAI_LOCAL -eq '1')   # essai du script lui-meme, hors Windows
if (-not ($hosted -or $local)) { throw 'Refus : essai pour runner GitHub heberge seulement (il cree un faux PC de Jo dans %USERPROFILE%).' }
foreach ($p in $main, $claudeDir, $claudeJson) {
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
# La vraie tache de nuit du checkout $Repo (son script a lui : celui d'avant la PR tant qu'il n'a rien recu).
function Invoke-Nightly([string]$LogName, [string]$Repo) {
    $code = Invoke-Logged $LogName { pwsh -NoProfile -File (Join-Path $Repo 'scripts' 'lena-nightly.ps1') }
    Get-Content -LiteralPath (Join-Path $Repo 'scripts' 'lena-nightly.log') -ErrorAction SilentlyContinue | Set-Content (Join-Path $out "$LogName.script.log")
    $code
}

function Get-Sha([string]$Dir, [string]$Rev) { (git -C $Dir rev-parse -q --verify $Rev 2>$null | Out-String).Trim() }
function Get-Status([string]$Dir) { (git -C $Dir status --porcelain --untracked-files=all | Out-String).Trim() }
function Get-LogText([string]$LogName) { Get-Content -Raw (Join-Path $out "$LogName.log") -ErrorAction SilentlyContinue }
# Egalite stricte de deux listes de lignes (ordinale : casse, accents et caracteres invisibles comptent).
function Test-SameLines($A, $B) { [Linq.Enumerable]::SequenceEqual([string[]]@($A), [string[]]@($B)) }
function Get-FirstDiff($A, $B) { (Compare-Object @($A) @($B) -CaseSensitive | Select-Object -First 3 | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join ' // ' }

# Empreinte d'un dossier : contenu de chaque fichier, chemins, et dossiers (meme vides). Pour prouver qu'il n'a pas bouge.
function Get-TreeHash([string]$Dir, [string]$Skip = $null) {
    if (-not (Test-Path -LiteralPath $Dir)) { return '(absent)' }
    $lines = [string[]]@(Get-ChildItem -LiteralPath $Dir -Recurse -Force | ForEach-Object {
            $rel = [IO.Path]::GetRelativePath($Dir, $_.FullName)
            if ($Skip -and $rel -match $Skip) { return }
            if ($_.PSIsContainer) { "dossier $rel" } else { '{0} {1}' -f (Get-FileHash -LiteralPath $_.FullName).Hash, $rel }
        })
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    $lines -join "`n"
}
# Compte principal du PC : tout %USERPROFILE%\.claude, plus %USERPROFILE%\.claude.json.
function Get-ProfilePrint {
    (Get-TreeHash $claudeDir) + "`n.claude.json " + $(if (Test-Path $claudeJson) { (Get-FileHash $claudeJson).Hash } else { '(absent)' })
}
# Checkout complet : tous les fichiers et dossiers, ceux que git ignore compris (CLAUDE.local.md, .venv, journaux),
# et tout .git (config, hooks, refs, info/exclude, worktrees...) sauf ce que la simple lecture fait bouger (objets,
# journaux des refs, index, *_HEAD) ; plus les drapeaux de l'index et le stash. « git status » ne voit pas tout ca.
function Get-RepoPrint([string]$Dir) {
    @(
        Get-TreeHash $Dir '^\.git[\\/](objects|logs)([\\/]|$)|^\.git[\\/](index|[A-Z_]*_HEAD)$'
        git -C $Dir ls-files -v
        'stash ' + (git -C $Dir stash list | Out-String)
    ) -join "`n"
}
# Ce qu'il y a a la racine du profil (noms seulement, sans les fichiers du registre de Windows).
function Get-ProfileRoot { @(Get-ChildItem -LiteralPath $env:USERPROFILE -Force | ForEach-Object Name | Where-Object { $_ -notmatch '^ntuser\.' }) }
function Get-GitGlobal { (git config --global --list 2>$null | Out-String) }

# Definition complete des taches planifiees (actions, declencheurs, reglages, compte, description), a plat, et la
# liste des taches qui tournent sous ce compte (une tache en plus se voit).
# Hors comparaison : ce qui change tout seul (date d'enregistrement, etat Ready / Running) et le jour du declencheur.
$taskNames = 'lena-claude-backup', 'lena-auto-commit', 'lena-nightly-ci', 'Desktop Commander Remote'
function Format-Cim($Obj, [string]$Prefix, [bool]$Top = $false) {
    "$Prefix(classe)=$($Obj.CimClass.CimClassName)"
    foreach ($p in @($Obj.CimInstanceProperties | Sort-Object Name)) {
        if ($Top -and $p.Name -in 'Date', 'State') { continue }
        $i = 0
        foreach ($v in @($p.Value)) {
            if ($v -is [Microsoft.Management.Infrastructure.CimInstance]) { Format-Cim $v "$Prefix$($p.Name)[$i]." }
            elseif ($p.Name -in 'StartBoundary', 'EndBoundary') { "$Prefix$($p.Name)=$("$v" -replace '^\d{4}-\d\d-\d\d', '')" }
            else { "$Prefix$($p.Name)[$i]=$v" }
            $i++
        }
    }
}
function Get-TaskDefs {
    foreach ($n in $taskNames) {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $t) { "$n | absente"; continue }
        Format-Cim $t "$n | " $true
    }
    $mine = @(Get-ScheduledTask | Where-Object { "$($_.Principal.UserId)" -match "(^|\\)$([regex]::Escape($env:USERNAME))$" } | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" } | Sort-Object)
    "taches de ce compte : $($mine -join ' ; ')"
}
# Le runner n'est pas le PC de Jo : quand l'essai lance lui-meme les scripts des taches, elles sont desactivees pour
# qu'aucune ne parte toute seule (02:00, 03:00, 12:00) au meme moment. Elles sont actives, comme chez Jo, quand
# install-tasks.ps1 passe et pendant toute l'installation des jumeaux (une tache desactivee par la PR se voit).
function Set-TasksEnabled([bool]$On) {
    foreach ($n in $taskNames) {
        if ($On) { Enable-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue | Out-Null }
        else { Disable-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue | Out-Null }
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
git -C $Source merge-base --is-ancestor $head $base
if ($LASTEXITCODE -eq 0) {
    throw "Rien a essayer : la tete ($head) est deja dans main. Lancement a la main : choisir la branche de la PR sous « Use workflow from », pas main."
}

# Origin local : main = avant la PR ; « pr » = tete de la PR. Branches des jumeaux : celle de la PR est a la tete
# de la PR ; l'autre est prise la ou elle est vraiment sur GitHub (origin/<branche>), sinon a la tete de la PR.
# francis-dev n'est ici qu'un nom de branche pour l'essai d'un 2e compte, pas la vraie branche de Francis.
$prBranch = if ($env:GITHUB_HEAD_REF) { $env:GITHUB_HEAD_REF } elseif ($env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME } else { (git -C $Source rev-parse --abbrev-ref HEAD | Out-String).Trim() }
$tips = @{}; $absent = @{}
foreach ($b in 'Estimateur-2', 'estimateur-junior') {
    $real = Get-Sha $Source "origin/$b"
    $absent[$b] = ($b -ne $prBranch -and -not $real)
    $tips[$b] = if ($b -ne $prBranch -and $real) { $real } else { $head }
}
git init -q --bare -b main $origin
git -C $Source push -q $origin "${base}:refs/heads/main" "${head}:refs/heads/pr" "$($tips['Estimateur-2']):refs/heads/Estimateur-2" "$($tips['estimateur-junior']):refs/heads/estimateur-junior" "${head}:refs/heads/francis-dev"
if ($LASTEXITCODE) { throw 'push vers origin local impossible' }
function Add-TwinTipChecks([string[]]$Branches) {
    foreach ($b in $Branches) {
        $detail = if ($absent[$b]) { 'branche absente de GitHub : jumeau essaye a la tete de la PR' }
        elseif ($tips[$b] -ne $head) { "jumeau installe depuis $($tips[$b].Substring(0, 7)), la PR est a $($head.Substring(0, 7)) : aligner la branche" } else { '' }
        Add-Check "branche $b sur GitHub = tete de la PR (copie conforme)" (-not $detail) $detail $false
    }
}

$inSnapshotZone = { $_ -match '^config/' -or $_ -eq 'docs/INVENTAIRE.md' }
# Fusion de la PR dans main, par merge commit (« Create a merge commit »).
function Merge-PrIntoMain {
    $id = @('-c', 'user.name=GitHub (essai)', '-c', 'user.email=essai@example.invalid')
    # 1. Comme GitHub : la PR fusionne-t-elle dans main tel qu'il est avant elle ?
    $gh = Join-Path $tmp 'merge-github'
    git clone -q $origin $gh
    git -C $gh checkout -q --detach $base
    $code = Invoke-Logged 'merge-pr' { git -C $gh @id merge --no-ff -m "Merge pull request (essai) : $head" origin/pr }
    Add-Check 'PR fusionnee dans main par merge commit, sans conflit' ($code -eq 0)
    if ($code -ne 0) { Write-Bilan }
    # 2. Le meme merge sur l'origin de l'essai, ou main porte en plus le snapshot que le faux PC vient de pousser.
    #    Ce snapshot ne ressemble pas a celui de Jo (autre machine) : s'il se heurte a un fichier de config/ que la
    #    PR change, ce n'est pas un conflit de la PR ; la version de la PR est prise.
    $work = Join-Path $tmp 'merge-work'
    git clone -q --branch main $origin $work
    $code = Invoke-Logged 'merge-pr-essai' { git -C $work @id merge --no-ff -m "Merge pull request (essai) : $head" origin/pr }
    $note = ''
    if ($code -ne 0) {
        $unmerged = @(git -C $work -c core.quotepath=false diff --name-only --diff-filter=U)
        if ($unmerged.Count -gt 0 -and @($unmerged | Where-Object { -not (& $inSnapshotZone) }).Count -eq 0) {
            foreach ($u in $unmerged) {
                git -C $work cat-file -e "origin/pr:$u" 2>$null
                if ($LASTEXITCODE -eq 0) { git -C $work checkout -q origin/pr -- $u } else { git -C $work rm -q -f -- $u }
            }
            git -C $work @id commit -q --no-edit
            $code = $LASTEXITCODE
            $note = "snapshot du faux PC ecarte pour : $($unmerged -join ', ')"
        }
    }
    if ($code -eq 0) { git -C $work push -q origin main; $code = $LASTEXITCODE }
    $parents = @((git -C $origin rev-list --parents -n 1 main | Out-String).Trim() -split ' ').Count - 1
    Add-Check 'merge rejoue sur l''origin de l''essai (merge commit a 2 parents)' (($code -eq 0) -and ($parents -eq 2)) "$(Get-Sha $origin 'main') $note".Trim()
    if (($code -ne 0) -or ($parents -ne 2)) { Write-Bilan }
}

# =================================================================================================
if ($Scenario -eq 'pc-neuf') {
    Write-Host "`n== PC neuf d'un estimateur (apres le merge) =="
    Merge-PrIntoMain
    git clone -q -c core.autocrlf=true --branch main $origin $main
    $code = Invoke-Logged 'install-twin' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'install-twin.ps1') -Branch Estimateur-2 -Remote $origin }
    Add-Check 'install-twin.ps1 sur PC neuf (code 0)' ($code -eq 0)
    $twin = Join-Path $dev 'lena-Estimateur-2'
    Add-Check 'jumeau Estimateur-2 sur sa branche' ((Test-Path $twin) -and ((Get-Sha $twin 'HEAD') -eq $tips['Estimateur-2']))
    Add-TwinTipChecks 'Estimateur-2'
    Add-Check 'CLAUDE.local.md importe LENA.md' ((Test-Path "$twin/CLAUDE.local.md") -and ((Get-Content -Raw "$twin/CLAUDE.local.md") -match '@docs/LENA.md'))
    $launcher = Join-Path $dev 'lena-Estimateur-2.cmd'
    Add-Check 'lanceur ecrit' (Test-Path $launcher) $launcher
    Add-Check 'dossier de config du compte estimateur + settings.json' (Test-Path (Join-Path $env:USERPROFILE '.claude-routeur' 'settings.json'))
    # Outils installes par le script : nouvelle session = PATH relu du registre.
    if ($IsWindows) {
        $env:Path = @((Join-Path $env:LOCALAPPDATA 'mise\shims'), (Join-Path $env:USERPROFILE '.local\bin'),
            [Environment]::GetEnvironmentVariable('Path', 'User'), [Environment]::GetEnvironmentVariable('Path', 'Machine'), $env:Path) -join ';'
    }
    foreach ($t in 'mise', 'uv', 'node', 'claude') {
        $cmd = Get-Command $t -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        Add-Check "outil $t present apres le script" ([bool]$cmd) $(if ($cmd) { $cmd.Source } else { 'pas installe sur ce runner (reseau / winget) : voir install-twin.log' }) $false
    }
    # Sur un PC sans Claude Code, l'installateur officiel (lance par le script) cree lui-meme %USERPROFILE%\.claude.
    # Pour memoire, ce qu'il y laisse (noms de fichiers et cles de settings.json seulement) :
    $mainFiles = @(if (Test-Path $claudeDir) { Get-ChildItem $claudeDir -Recurse -File -Force | ForEach-Object { [IO.Path]::GetRelativePath($claudeDir, $_.FullName) } })
    $keys = try { ((Get-Content -Raw (Join-Path $claudeDir 'settings.json') | ConvertFrom-Json).PSObject.Properties.Name) -join ', ' } catch { '(pas de settings.json)' }
    "Apres l'installateur officiel de Claude Code, %USERPROFILE%\.claude contient $($mainFiles.Count) fichier(s) : $(($mainFiles | Select-Object -First 8) -join ', ') ; cles de settings.json : $keys ; %USERPROFILE%\.claude.json : $(if (Test-Path $claudeJson) { 'present' } else { 'absent' })" |
        Tee-Object -FilePath (Join-Path $out 'compte-principal.txt') | Write-Host
    Add-Check 'aucun login seme dans le compte principal (.credentials.json absent)' (-not (Test-Path (Join-Path $claudeDir '.credentials.json')))
    # La preuve que NOTRE script n'ecrit rien dans le compte principal : on le relance, Claude Code deja installe,
    # pour un autre compte (nouveau dossier de config, donc semis de settings.json rejoue) ; rien ne doit bouger.
    $profBefore = Get-ProfilePrint
    $userPath = if ($IsWindows) { [Environment]::GetEnvironmentVariable('Path', 'User') } else { '' }
    $code = Invoke-Logged 'install-twin-2e-compte' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'install-twin.ps1') -Branch francis-dev -Remote $origin -NoInstall -SkipTests }
    Add-Check 'install-twin.ps1 pour un 2e compte (code 0, dossier de config seme a part)' (($code -eq 0) -and (Test-Path (Join-Path $env:USERPROFILE '.claude-francis' 'settings.json')))
    Add-Check 'compte principal du PC (%USERPROFILE%\.claude et .claude.json) : pas un octet ecrit par install-twin.ps1' ((Get-ProfilePrint) -ceq $profBefore)
    if ($IsWindows) {
        $shims = Join-Path $env:LOCALAPPDATA 'mise\shims'
        $after = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (Test-Path $shims) {
            Add-Check 'PATH utilisateur : shims mise presents une seule fois, relance sans effet' ((@(($after -split ';') | Where-Object { $_ -eq $shims }).Count -eq 1) -and ($after -ceq $userPath))
        } else {
            Add-Check 'PATH utilisateur : inchange a la relance' ($after -ceq $userPath)
        }
    }
    if ($IsWindows -and (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue)) {
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
'{"essai":"faux etat du compte principal"}' | Set-Content $claudeJson
if ($IsWindows -and -not (Test-Path 'D:\')) {
    $dRoot = Join-Path $tmp 'drive-d'
    New-Item -ItemType Directory -Force -Path $dRoot | Out-Null
    subst D: $dRoot
}
# Comme chez Jo : Claude Code dans %USERPROFILE%\.local\bin (ici un faux « claude » qui montre ce que le lanceur lui
# passe : aucun vrai Claude ne peut partir pendant l'essai) et uv dans les shims de mise (ici une copie de uv).
# Les shims ne sont pas encore sur le PATH utilisateur : install-twin.ps1 doit les y ajouter, une seule fois.
$fakeBin = Join-Path $env:USERPROFILE '.local' 'bin'
New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
if ($IsWindows) {
    "@echo off`r`necho CFG=[%CLAUDE_CONFIG_DIR%]`r`necho CWD=[%CD%]`r`necho ARGS=[%*]`r`necho AUTOUPD=[%DISABLE_AUTOUPDATER%]`r`necho KEY=[%ANTHROPIC_API_KEY%]`r`nexit /b 0`r`n" | Set-Content (Join-Path $fakeBin 'claude.cmd') -NoNewline
} else {
    "#!/bin/sh`necho faux claude`n" | Set-Content (Join-Path $fakeBin 'claude') -NoNewline
    chmod +x (Join-Path $fakeBin 'claude')
}
$shims = $null
if ($IsWindows) {
    $shims = Join-Path $env:LOCALAPPDATA 'mise\shims'
    if (Test-Path $shims) { throw "Refus : $shims existe deja - ce n'est pas une machine jetable." }
    New-Item -ItemType Directory -Force -Path $shims | Out-Null
    Copy-Item (Get-Command uv -CommandType Application | Select-Object -First 1).Source $shims
}
$env:PATH = (@(@($fakeBin, $shims) | Where-Object { $_ }) + $env:PATH) -join [IO.Path]::PathSeparator   # « PATH » : nom exact hors Windows

$prod = 'scripts/auto-commit.ps1', 'scripts/lena-nightly.ps1', 'scripts/backup-claude.ps1', 'scripts/snapshot-config.ps1'
if ($IsWindows) {
    $code = Invoke-Logged 'install-tasks-avant' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'install-tasks.ps1') }
    Add-Check 'avant : taches planifiees creees par le script de main' ($code -eq 0)
    $tasksBefore = @(Get-TaskDefs)
    Set-TasksEnabled $false
    $tasksBefore | Set-Content (Join-Path $out 'taches-avant.txt')
    Add-Check 'avant : les 4 taches existent' (@($tasksBefore | Where-Object { $_ -match '\| absente$' }).Count -eq 0) "$($tasksBefore.Count) ligne(s) de definition comparees"
}
$code = Invoke-Logged 'auto-commit-avant' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'auto-commit.ps1') }
Add-Check 'avant : auto-commit (snapshot + push) fonctionne' ($code -eq 0)
Add-Check 'avant : PC a jour avec origin' ((Get-Sha $main 'HEAD') -eq (Get-Sha $origin 'main'))

# Quatre autres PC dans le meme etat « avant » : la CI de nuit comme premier receveur, et les trois cas qui bloquent.
$nuit    = Join-Path $tmp 'pc-nuit' 'lena-ai-jo'
$pire    = Join-Path $tmp 'pc-cas-1' 'lena-ai-jo'
$conflit = Join-Path $tmp 'pc-cas-2' 'lena-ai-jo'
$avance  = Join-Path $tmp 'pc-cas-3' 'lena-ai-jo'
foreach ($d in $nuit, $pire, $conflit, $avance) { git clone -q -c core.autocrlf=true --branch main $origin $d }

# --- 2. La PR entre dans main -----------------------------------------------------------------------
Write-Host "`n== 2. Merge de la PR dans main (origin) =="
$preMerge = Get-Sha $origin 'main'   # main avant la PR + le snapshot que le PC de Jo vient de pousser
Merge-PrIntoMain
$merged = Get-Sha $origin 'main'
# Ce que le merge apporte, lu dans le merge lui-meme (vaut pour n'importe quelle PR, pas seulement celle-ci).
# Fichiers des cas de blocage : hors fichiers de config git, hors zone du snapshot ; de preference hors
# plan-tools/ et code-rag/ (un brouillon la-dedans ferait aussi rougir les tests de la tache de nuit).
$usable = { $_ -and $_ -notmatch '^"' -and $_ -notmatch '(^|/)\.git[^/]*$' -and -not (& $inSnapshotZone) }
$prFiles = @(git -C $origin -c core.quotepath=false diff --name-only $preMerge $merged)
$prAdded = @(git -C $origin -c core.quotepath=false diff --diff-filter=A --name-only $preMerge $merged | Where-Object $usable)
$prModified = @(git -C $origin -c core.quotepath=false diff --diff-filter=M --numstat $preMerge $merged | ForEach-Object {
        $f = $_ -split "`t", 3
        if ($f.Count -eq 3 -and $f[0] -match '^\d+$' -and ([int]$f[0] + [int]$f[1]) -gt 0) { $f[2] } } | Where-Object $usable)
$prModified = @($prModified | Where-Object { $_ -notmatch '^(plan-tools|code-rag)/' }) + @($prModified | Where-Object { $_ -match '^(plan-tools|code-rag)/' })
Write-Host "le merge change $($prFiles.Count) fichier(s) : $($prAdded.Count) ajoute(s) et $($prModified.Count) fichier(s) texte modifie(s) utilisables pour les cas de blocage"
# Ce PC a-t-il recu le merge, et est-il au meme point qu'origin (le merge, plus le snapshot pousse par le PC de Jo) ?
function Test-AtOrigin([string]$Dir) {
    git -C $Dir merge-base --is-ancestor $merged HEAD
    ($LASTEXITCODE -eq 0) -and ((Get-Sha $Dir 'HEAD') -eq (Get-Sha $origin 'main'))
}
# Le chemin $Rel est-il libre dans le checkout $Root (rien a cet endroit, et un vrai dossier au-dessus) ?
function Test-FreePath([string]$Root, [string]$Rel) {
    $p = Join-Path $Root $Rel
    if (Test-Path -LiteralPath $p) { return $false }
    $d = [IO.Path]::GetDirectoryName($p)
    while ($d -and -not (Test-Path -LiteralPath $d)) { $d = [IO.Path]::GetDirectoryName($d) }
    [bool]($d -and (Test-Path -LiteralPath $d -PathType Container))
}

# --- 3. Le PC de Jo recoit la PR par ses taches planifiees ------------------------------------------
Write-Host "`n== 3. Le PC de Jo recoit la PR =="
# Un changement de config en attente (comme un jour normal) : auto-commit commite, tire main, pousse.
Add-Content -Path (Join-Path $claudeDir 'CLAUDE.md') -Value "`n<!-- essai : changement local en attente -->"
# A partir d'ici, du code de la PR tourne sous le compte de Jo (tests, sync-agents, install-tasks, jumeaux) :
# le compte principal ne doit plus bouger d'un octet jusqu'a la fin de l'essai.
$profBefore = Get-ProfilePrint
$code = Invoke-Logged 'auto-commit-apres' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'auto-commit.ps1') }
Get-Content (Join-Path $main 'scripts' 'auto-commit.log') -ErrorAction SilentlyContinue | Set-Content (Join-Path $out 'auto-commit.script.log')
Add-Check 'auto-commit apres le merge (code 0)' ($code -eq 0)
git -C $main merge-base --is-ancestor $merged HEAD
Add-Check 'main local contient le merge, et origin = local (snapshot pousse)' (($LASTEXITCODE -eq 0) -and ($prFiles.Count -gt 0) -and ((Get-Sha $main 'HEAD') -eq (Get-Sha $origin 'main'))) "$($prFiles.Count) fichier(s) apportes par la PR"
$snapFiles = @(git -C $main diff --name-only "$merged" HEAD)
$outside = @($snapFiles | Where-Object { -not (& $inSnapshotZone) })
Add-Check 'snapshot de Jo : seulement config/ et docs/INVENTAIRE.md (tout le reste = main apres le merge)' ($outside.Count -eq 0) "$($snapFiles.Count) fichier(s)$(if ($outside) { ' ; hors zone : ' + ($outside -join ', ') })"
Add-Check 'checkout principal propre (rien de modifie, rien en trop)' (-not (Get-Status $main)) (Get-Status $main)
git -C $main diff --quiet $base HEAD -- @prod
Add-Check 'scripts de production de Jo identiques a avant (auto-commit, nightly, backup, snapshot)' ($LASTEXITCODE -eq 0)

$code = Invoke-Nightly 'nightly' $main
Add-Check 'CI de nuit sur le PC deja a jour : tests verts (code 0)' ($code -eq 0)

if ($IsWindows) {
    $code = Invoke-Logged 'backup-claude' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'backup-claude.ps1') }
    Add-Check 'sauvegarde des conversations (code 0, fichier copie)' (($code -eq 0) -and (Test-Path 'D:\Backups\claude\projects\essai\session.jsonl'))
    Set-TasksEnabled $true   # comme chez Jo au moment ou le nouveau script passe
    $code = Invoke-Logged 'install-tasks-apres' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'install-tasks.ps1') }
    $tasksAfter = @(Get-TaskDefs)
    Set-TasksEnabled $false
    $tasksAfter | Set-Content (Join-Path $out 'taches-apres.txt')
    Add-Check 'install-tasks.ps1 de la PR, depuis le checkout principal (code 0)' ($code -eq 0)
    Add-Check 'taches planifiees identiques a avant (definition complete : actions, declencheurs, reglages, compte ; aucune tache en plus)' (Test-SameLines $tasksBefore $tasksAfter) (Get-FirstDiff $tasksBefore $tasksAfter)
}

$bash = if ($IsWindows) { Join-Path $env:ProgramFiles 'Git\bin\bash.exe' } else { 'bash' }
$code = Invoke-Logged 'sync-agents' { & $bash scripts/sync-agents.sh } $main
$dirty = Get-Status $main
if ($dirty) { git -C $main diff --stat *>&1 | Add-Content (Join-Path $out 'sync-agents.log'); git -C $main ls-files --eol AGENTS.md docs/LENA.md *>&1 | Add-Content (Join-Path $out 'sync-agents.log') }
Add-Check 'sync-agents.sh sous Git Bash sur le checkout Windows (parite OK, aucun fichier touche)' (($code -eq 0) -and ((Get-LogText 'sync-agents') -match 'parity OK') -and -not $dirty) $dirty
# Pour memoire (pas une verification) : le sed de Git Bash garde-t-il les retours chariot ?
$probe = Join-Path $tmp 'sonde-cr.txt'
[IO.File]::WriteAllBytes($probe, [byte[]](0x61, 0x0D, 0x0A))
Push-Location $tmp; try { $n = (& $bash -c 'sed -n p sonde-cr.txt | wc -c' 2>&1 | Out-String).Trim() } finally { Pop-Location }
"sed de ce bash : $n octet(s) en sortie pour « a CR LF » (3 = CR garde, 2 = CR retire)" | Tee-Object -FilePath (Join-Path $out 'sonde-sed.txt') | Write-Host

# Un 2e PC, rien en attente : c'est la CI de nuit qui recoit le merge en premier (elle tire chaque nuit).
$code = Invoke-Nightly 'nightly-premier' $nuit
Add-Check 'CI de nuit premiere a recevoir le merge (2e PC, rien en attente) : tirage + tests verts, checkout propre' (
    ($code -eq 0) -and (Test-AtOrigin $nuit) -and -not (Get-Status $nuit)) (Get-Status $nuit)

# RUNBOOK section 12 de bout en bout (sur ce 2e PC, pas chez Jo) : les sources Claude changent (docs/LENA.md et le
# premier skill present), on resynchronise sous Git Bash, on commite ; puis l'etape « Parite » de ci.yml, telle
# quelle, sur un clone LF de ce commit.
Add-Content -LiteralPath (Join-Path $nuit 'docs' 'LENA.md') -Value "Ligne d'essai (parite)."
$eolPaths = @('AGENTS.md', 'docs/LENA.md')
$skill = Get-ChildItem -LiteralPath (Join-Path $nuit '.claude' 'skills') -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } | Sort-Object Name | Select-Object -First 1
if ($skill) {
    Add-Content -LiteralPath (Join-Path $skill.FullName 'SKILL.md') -Value "Ligne d'essai (parite)."
    $eolPaths += ".agents/skills/$($skill.Name)/SKILL.md"
}
$code = Invoke-Logged 'sync-agents-derive' { & $bash scripts/sync-agents.sh } $nuit
git -C $nuit config user.name 'Essai'; git -C $nuit config user.email 'essai@example.invalid'
git -C $nuit add -A 2>$null; git -C $nuit commit -q -m 'essai : derive resynchronisee' 2>$null
$ciClone = Join-Path $tmp 'pc-nuit-vu-par-la-ci'
git clone -q -c core.autocrlf=false $nuit $ciClone
$parite = Join-Path $tmp 'parite-ci.sh'
[IO.File]::WriteAllText($parite, "set -euo pipefail`nsed -n '/^<!-- LENA:START -->`$/,/^<!-- LENA:END -->`$/p' AGENTS.md | sed '1d;`$d' | diff -u docs/LENA.md -`ndiff -r .claude/skills .agents/skills`ngrep -qx `"Ligne d'essai (parite).`" docs/LENA.md`n")
$ciCode = Invoke-Logged 'parite-ci' { & $bash ($parite -replace '\\', '/') } $ciClone
$eol = @(git -C $nuit ls-files --eol -- @eolPaths)
$lfOk = (@($eol | Where-Object { $_ -match '^i/lf\s' }).Count -eq $eolPaths.Count)
Add-Check 'RUNBOOK §12 : sources modifiees -> sync-agents.sh -> commit conforme a la CI (etape Parite de ci.yml, LF dans git)' (
    ($code -eq 0) -and ((Get-LogText 'sync-agents-derive') -match 'rewritten') -and ((Get-LogText 'sync-agents-derive') -match 'parity OK') -and
    ($ciCode -eq 0) -and $lfOk -and -not (Get-Status $nuit)) "sync=$code parite-ci=$ciCode lf=$lfOk$(if (-not $skill) { ' (aucun skill dans ce checkout)' })"

# Les trois cas ou le tirage des taches bloque (RUNBOOK section 11), sur trois autres PC restes « avant »,
# rejoues avec la vraie tache de nuit de ces PC (celle d'avant la PR).
# Cas 1 : un fichier non suivi traine sur un chemin que le merge ajoute. Attendu : la tache echoue net (« ECHEC
# pull --rebase »), rien n'est perdu ni a moitie applique ; une fois le fichier deplace, le tirage passe.
$strayRel = $prAdded | Where-Object { git -C $pire check-ignore -q -- $_; ($LASTEXITCODE -ne 0) -and (Test-FreePath $pire $_) } | Select-Object -First 1
if ($strayRel) {
    $stray = Join-Path $pire $strayRel
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($stray)) | Out-Null
    [IO.File]::WriteAllText($stray, "brouillon local`n")
    $pireHead = Get-Sha $pire 'HEAD'
    $code = Invoke-Nightly 'nightly-cas-1' $pire
    $rebasing = (Test-Path (Join-Path $pire '.git' 'rebase-merge')) -or (Test-Path (Join-Path $pire '.git' 'rebase-apply'))
    Add-Check "cas 1 (fichier non suivi sur un chemin que la PR ajoute : $strayRel) : la tache de nuit echoue net, rien de perdu" (
        ($code -ne 0) -and ((Get-LogText 'nightly-cas-1') -match 'ECHEC pull --rebase') -and ((Get-Sha $pire 'HEAD') -eq $pireHead) -and
        ([IO.File]::ReadAllText($stray) -match 'brouillon local') -and -not $rebasing) ((Get-LogText 'nightly-cas-1') -split '\r?\n' | Where-Object { $_ -match 'untracked|overwritten|error' } | Select-Object -First 1)
    [IO.File]::Move($stray, (Join-Path $tmp 'brouillon-deplace.txt'))
    $code = Invoke-Logged 'pull-cas-1-repare' { git -C $pire pull --rebase --autostash origin main }
    Add-Check 'cas 1 : fichier deplace -> le tirage passe' (($code -eq 0) -and (Test-AtOrigin $pire) -and -not (Get-Status $pire)) (Get-Status $pire)
} else {
    Write-Host 'cas 1 : sans objet (la PR n''ajoute aucun fichier utilisable pour ce cas)'
}
# Cas 2 : une modification non commitee dans un fichier que le merge change aussi. Le tirage avance, mais remettre
# la modification echoue : fichier en conflit, modification gardee dans le stash ; ce passage peut finir « OK », les
# suivants echouent. Reparation du RUNBOOK : remettre le fichier comme dans main.
# Cas 3 : la meme modification, mais commitee sur le PC et pas poussee. « git status » ne montre rien ; chaque
# passage echoue (conflit de rebase, annule). Reparation du RUNBOOK : mettre le commit de cote, revenir a main.
$editRel = $prModified | Where-Object { Test-Path -LiteralPath (Join-Path $conflit $_) -PathType Leaf } | Select-Object -First 1
if ($editRel) {
    $inTests = $editRel -match '^(plan-tools|code-rag)/'
    [IO.File]::WriteAllText((Join-Path $conflit $editRel), "brouillon local`n")
    $code1 = Invoke-Nightly 'nightly-cas-2' $conflit
    $unmerged = @(git -C $conflit -c core.quotepath=false diff --name-only --diff-filter=U)
    $stash = (git -C $conflit stash list | Out-String).Trim()
    $code2 = Invoke-Nightly 'nightly-cas-2-suivant' $conflit
    Add-Check "cas 2 (modification non commitee dans un fichier que la PR change : $editRel) : main recu, fichier en conflit, modification gardee dans le stash, passage suivant en echec" (
        (Test-AtOrigin $conflit) -and ($unmerged -contains $editRel) -and [bool]$stash -and ($inTests -or $code1 -eq 0) -and
        ($code2 -ne 0) -and ((Get-LogText 'nightly-cas-2-suivant') -match 'ECHEC pull --rebase')) "code de la tache de nuit : $code1 ; au passage suivant, sans reparation : $code2"
    git -C $conflit restore --staged --worktree --source=HEAD -- $editRel
    $code = Invoke-Nightly 'nightly-cas-2-repare' $conflit
    $kept = (git -C $conflit stash show -p 'stash@{0}' 2>&1 | Out-String) -match 'brouillon local'
    Add-Check 'cas 2 : reparation du RUNBOOK (git restore) -> la tache de nuit repart (code 0), checkout propre, modification toujours dans le stash' (
        ($code -eq 0) -and -not (Get-Status $conflit) -and $kept) (Get-Status $conflit)

    [IO.File]::WriteAllText((Join-Path $avance $editRel), "brouillon local`n")
    git -C $avance -c user.name=Essai -c user.email=essai@example.invalid commit -q -a -m 'note locale (essai)'
    $localSha = Get-Sha $avance 'HEAD'
    $ahead = (git -C $avance log --oneline origin/main..main | Out-String).Trim()
    $code = Invoke-Nightly 'nightly-cas-3' $avance
    $rebasing = (Test-Path (Join-Path $avance '.git' 'rebase-merge')) -or (Test-Path (Join-Path $avance '.git' 'rebase-apply'))
    Add-Check "cas 3 (la meme modification, commitee sur le PC et pas poussee) : rien dans « git status », vu par « git log origin/main..main » ; la tache de nuit echoue, rebase annule, commit garde" (
        (-not (Get-Status $avance)) -and [bool]$ahead -and ($code -ne 0) -and ((Get-LogText 'nightly-cas-3') -match 'ECHEC pull --rebase') -and
        ((Get-Sha $avance 'HEAD') -eq $localSha) -and -not $rebasing) $ahead
    git -C $avance branch garde-jo main
    git -C $avance fetch -q origin
    git -C $avance reset -q --hard origin/main
    $code = Invoke-Nightly 'nightly-cas-3-repare' $avance
    Add-Check 'cas 3 : reparation du RUNBOOK (commit mis de cote sur une branche, retour a origin/main) -> la tache de nuit repart, commit toujours la' (
        ($code -eq 0) -and (Test-AtOrigin $avance) -and -not (Get-Status $avance) -and ((Get-Sha $avance 'garde-jo') -eq $localSha)) (Get-Status $avance)
} else {
    Write-Host 'cas 2 et 3 : sans objet (la PR ne modifie aucun fichier texte utilisable pour ces cas)'
}

# --- 4. Les jumeaux des estimateurs, a cote du checkout de Jo ---------------------------------------
Write-Host "`n== 4. Jumeaux des estimateurs sur le PC de Jo =="
if ($IsWindows) { Set-TasksEnabled $true }   # comme chez Jo : taches actives pendant l'installation des jumeaux
$repoBefore = Get-RepoPrint $main
$rootBefore = Get-ProfileRoot
$gitGlobalBefore = Get-GitGlobal
$pathBefore = if ($IsWindows) { [Environment]::GetEnvironmentVariable('Path', 'User') } else { '' }
$code = Invoke-Logged 'install-twin' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'install-twin.ps1') -Branch 'Estimateur-2,estimateur-junior' -Remote $origin -NoInstall }
Add-Check 'install-twin.ps1 -Branch Estimateur-2,estimateur-junior (code 0, tests compris)' ($code -eq 0) ((Get-LogText 'install-twin') -split '\r?\n' | Where-Object { $_ -match '^Taux de succes' } | Select-Object -Last 1)
$twinLog = Get-LogText 'install-twin'
Add-Check 'tests des jumeaux verts (pytest plan-tools + code-rag, 2 jumeaux)' (@([regex]::Matches($twinLog, '(?m)^\[OK  \] \S+ : pytest ')).Count -eq 4) "$(@([regex]::Matches($twinLog, '(?m)^\[OK  \] \S+ : pytest ')).Count)/4"
foreach ($b in 'Estimateur-2', 'estimateur-junior') {
    $twin = Join-Path $dev "lena-$b"
    Add-Check "jumeau $b : sur sa branche, a la tete de cette branche" ((Test-Path $twin) -and ((Get-Sha $twin 'HEAD') -eq $tips[$b]) -and ((git -C $twin rev-parse --abbrev-ref HEAD | Out-String).Trim() -eq $b)) $tips[$b]
    Add-Check "jumeau $b : CLAUDE.local.md importe LENA.md, lanceur ecrit" (
        (Test-Path "$twin/CLAUDE.local.md") -and ((Get-Content -Raw "$twin/CLAUDE.local.md") -match '@docs/LENA.md') -and (Test-Path (Join-Path $dev "lena-$b.cmd")))
    Add-Check "jumeau $b : propre (CLAUDE.local.md ignore par git)" (-not (Get-Status $twin)) (Get-Status $twin)
}
Add-TwinTipChecks 'Estimateur-2', 'estimateur-junior'
$cfg = Join-Path $env:USERPROFILE '.claude-routeur'
$seedOk = $false
try {
    $s = Get-Content -Raw (Join-Path $cfg 'settings.json') | ConvertFrom-Json
    $seedOk = (-not $s.PSObject.Properties['statusLine']) -and (-not $s.PSObject.Properties['enabledPlugins']) -and ($s.env.DISABLE_AUTOUPDATER -eq '1')
} catch { }
Add-Check 'dossier de config du compte estimateur : settings.json seme (sans statusLine / enabledPlugins, auto-update coupe)' $seedOk $cfg
Add-Check 'compte principal de Jo (%USERPROFILE%\.claude et .claude.json) : pas un octet de change depuis l''arrivee de la PR' ((Get-ProfilePrint) -ceq $profBefore)
Add-Check 'checkout principal de Jo : pas un octet de change (fichiers ignores et tout .git compris, hors objets et index)' ((Get-RepoPrint $main) -ceq $repoBefore) (Get-Status $main)
$rootNew = @(Get-ProfileRoot | Where-Object { $_ -notin $rootBefore })
$rootGone = @($rootBefore | Where-Object { $_ -notin (Get-ProfileRoot) })
Add-Check 'profil de Jo : a sa racine, seul le dossier de config du compte estimateur s''ajoute ; config git globale inchangee' (
    (($rootNew -join ',') -eq '.claude-routeur') -and ($rootGone.Count -eq 0) -and ((Get-GitGlobal) -ceq $gitGlobalBefore)) "ajoute : $($rootNew -join ', ')$(if ($rootGone) { ' ; disparu : ' + ($rootGone -join ', ') })"
if ($IsWindows) {
    $pathAfter = [Environment]::GetEnvironmentVariable('Path', 'User')
    Add-Check 'PATH utilisateur de Jo : shims mise ajoutes une fois, a la fin, rien d''autre de change' ($pathAfter -ceq ((@($pathBefore, $shims) | Where-Object { $_ }) -join ';')) $shims
}

$code = Invoke-Logged 'install-tasks-depuis-jumeau' { pwsh -NoProfile -File (Join-Path $dev 'lena-Estimateur-2' 'scripts' 'install-tasks.ps1') }
Add-Check 'install-tasks.ps1 lance depuis un jumeau : refuse (code 1)' (($code -eq 1) -and ((Get-LogText 'install-tasks-depuis-jumeau') -match 'Refus'))
if ($IsWindows) {
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

# Relance (mise a jour d'un jumeau deja installe, le chemin de tous les passages suivants) : rien n'est reecrit.
$localBefore = Get-TreeHash $cfg
$mdBefore = (Get-FileHash (Join-Path $dev 'lena-Estimateur-2' 'CLAUDE.local.md')).Hash
$rootMid = Get-ProfileRoot
$code = Invoke-Logged 'install-twin-2' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'install-twin.ps1') -Branch 'Estimateur-2,estimateur-junior' -Remote $origin -NoInstall -SkipTests }
Add-Check 'install-twin.ps1 relance : code 0, CLAUDE.local.md et settings.json conserves' (
    ($code -eq 0) -and ((Get-TreeHash $cfg) -ceq $localBefore) -and ((Get-FileHash (Join-Path $dev 'lena-Estimateur-2' 'CLAUDE.local.md')).Hash -eq $mdBefore))
# Apres tout ca (installation, refus depuis un jumeau, lanceur, relance) : le cote de Jo est toujours intact.
Add-Check 'apres la relance : compte principal, checkout principal, racine du profil et config git globale de Jo toujours intacts' (
    ((Get-ProfilePrint) -ceq $profBefore) -and ((Get-RepoPrint $main) -ceq $repoBefore) -and (Test-SameLines $rootMid (Get-ProfileRoot)) -and ((Get-GitGlobal) -ceq $gitGlobalBefore))
if ($IsWindows) {
    Add-Check 'apres la relance : PATH utilisateur inchange (shims pas ajoutes deux fois)' ([Environment]::GetEnvironmentVariable('Path', 'User') -ceq $pathAfter)
    $tasksEnd = @(Get-TaskDefs)
    Set-TasksEnabled $false
    Add-Check 'taches planifiees apres les jumeaux : identiques a avant la PR, toujours actives (definition complete)' (Test-SameLines $tasksBefore $tasksEnd) (Get-FirstDiff $tasksBefore $tasksEnd)
}

# --- 5. Le lendemain : les taches de Jo tournent encore, jumeaux installes --------------------------
Write-Host "`n== 5. Apres l'installation des jumeaux =="
$code = Invoke-Logged 'auto-commit-final' { pwsh -NoProfile -File (Join-Path $main 'scripts' 'auto-commit.ps1') }
Add-Check 'auto-commit fonctionne encore (code 0), PC a jour avec origin, checkout propre' (
    ($code -eq 0) -and ((Get-Sha $main 'HEAD') -eq (Get-Sha $origin 'main')) -and -not (Get-Status $main)) (Get-Status $main)
Add-Check 'a la toute fin : compte principal de Jo intact depuis l''arrivee de la PR (tests, sync-agents, install-tasks, jumeaux et lanceur compris)' ((Get-ProfilePrint) -ceq $profBefore)

Write-Bilan
