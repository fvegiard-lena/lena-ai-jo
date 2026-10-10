#Requires -Version 7
# Simulateur du PC de Jo (workflow .github/workflows/jo-pc-sim.yml, runner Windows jetable).
# Recree le PC de Jo sur une machine neuve, puis lance les VRAIS scripts du repo et verifie
# leurs effets. Ne touche jamais GitHub : "origin" est un depot nu local ; le PC de Jo n'est jamais
# contacte. Il efface %USERPROFILE%\dev : il refuse donc de tourner ailleurs que sur un runner GitHub
# ou dans Windows Sandbox (compte WDAGUtilityAccount), jamais sur un vrai PC.
#   Profil   : %USERPROFILE%\dev\lena-ai-jo (main = commit teste), .claude, OneDrive « Mes projets »
#              avec des .qpl de test, D:\Backups (subst si pas de D:), outils mise aux versions
#              de config/VERSIONS.md.
#   Verifie  : install-twin, install-tasks (vraies taches planifiees), backup-claude, auto-commit
#              (snapshot masque + push vers origin local), lena-nightly (DryRun, vert, rouge force),
#              boucle autonome sous Git Bash, plan-tools inventaire / bordereau / trace.
# Sortie : tableau OK / FAIL ; code 1 si une verification echoue. Journaux dans $env:SIM_OUT.
[CmdletBinding()]
param(
    [string]$Source = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:GIT_TERMINAL_PROMPT = '0'
if (-not $IsWindows) { throw 'Simulateur Windows seulement.' }
if (-not $env:GITHUB_ACTIONS -and $env:USERNAME -ne 'WDAGUtilityAccount') { throw 'Refus : simulateur pour runner GitHub ou Windows Sandbox seulement (il efface %USERPROFILE%\dev).' }

$out = if ($env:SIM_OUT) { $env:SIM_OUT } else { Join-Path $env:RUNNER_TEMP 'sim-out' }
New-Item -ItemType Directory -Force -Path $out | Out-Null
$script:checks = [Collections.Generic.List[object]]::new()

function Add-Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:checks.Add([pscustomobject]@{ Check = $Name; OK = $Ok; Detail = $Detail })
    Write-Host ("[{0}] {1}{2}" -f $(if ($Ok) { 'OK  ' } else { 'FAIL' }), $Name, $(if ($Detail) { " - $Detail" } else { '' }))
}

# Lance un script/commande, garde toute la sortie dans un journal, renvoie le code de sortie.
function Invoke-Logged([string]$LogName, [scriptblock]$Block) {
    $log = Join-Path $out "$LogName.log"
    $global:LASTEXITCODE = 0
    & $Block *>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log | Out-Null
    $code = $LASTEXITCODE
    Write-Host "  ($LogName : code $code, journal $log)"
    $code
}

function Get-Ver([string]$Tool) {
    $line = Get-Content (Join-Path $Source 'config\VERSIONS.md') | Where-Object { $_ -match "^\| ``$Tool --version``" } | Select-Object -First 1
    if ($line -match '\| ([0-9][0-9.]*)') { $Matches[1] } else { $null }
}

# Comme une nouvelle session chez Jo : PATH relu du registre (winget y ajoute mise), shims mise devant.
function Update-Path {
    $env:Path = @(
        (Join-Path $env:LOCALAPPDATA 'mise\shims'),
        [Environment]::GetEnvironmentVariable('Path', 'User'),
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        $env:Path
    ) -join ';'
}

# --- 1. Profil de Jo ---------------------------------------------------------------
Write-Host "`n== Profil de Jo =="
$dev  = Join-Path $env:USERPROFILE 'dev'
$main = Join-Path $dev 'lena-ai-jo'
$origin = Join-Path $env:RUNNER_TEMP 'origin.git'
$sha = (git -C $Source rev-parse HEAD).Trim()

if (Test-Path $origin) { Remove-Item -Recurse -Force $origin }
if (Test-Path $dev) { Remove-Item -Recurse -Force $dev }
git init -q --bare -b main $origin
git -C $Source push -q $origin "${sha}:refs/heads/main" "${sha}:refs/heads/francis-dev"
New-Item -ItemType Directory -Force -Path $dev | Out-Null
git clone -q --branch main $origin $main
git -C $main config user.name 'Jo (simulateur)'
git -C $main config user.email 'jo-sim@example.invalid'
Add-Check 'checkout principal main = commit teste' ((git -C $main rev-parse HEAD).Trim() -eq $sha) $sha

$claudeDir = Join-Path $env:USERPROFILE '.claude'
New-Item -ItemType Directory -Force -Path (Join-Path $claudeDir 'projects\sim') | Out-Null
Copy-Item (Join-Path $Source 'config\claude\settings.json') $claudeDir -Force
Copy-Item (Join-Path $Source 'config\claude\CLAUDE.md') $claudeDir -Force
'{"type":"user","message":"conversation de test"}' | Set-Content (Join-Path $claudeDir 'projects\sim\session.jsonl')

$projects = Join-Path $env:USERPROFILE 'OneDrive - GROUPE DR ELECTRIQUE INC\DANIEL-FRANCIS-JO\Mes projets'
foreach ($p in @(@{ Dir = 'S-0001 (Simulateur inventaire)'; Qpl = 'mini.qpl' }, @{ Dir = 'S-0002 Simulateur trace'; Qpl = 'route.qpl' })) {
    $d = Join-Path $projects $p.Dir
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Copy-Item (Join-Path $Source "plan-tools\tests\fixtures\$($p.Qpl)") $d
}
Add-Check 'OneDrive « Mes projets » (2 projets de test)' ((Get-ChildItem $projects -Directory).Count -eq 2) $projects

if (-not (Test-Path 'D:\')) {
    $dRoot = Join-Path $env:RUNNER_TEMP 'drive-d'
    New-Item -ItemType Directory -Force -Path $dRoot | Out-Null
    subst D: $dRoot
}
Add-Check 'lecteur D: (sauvegardes)' (Test-Path 'D:\')

# --- 2. Outils aux versions de Jo -----------------------------------------------------
Write-Host "`n== Outils (versions de config/VERSIONS.md) =="
Update-Path
Add-Check 'mise sur le PATH (installe par winget)' ([bool](Get-Command mise -ErrorAction SilentlyContinue))
$miseCfgDir = Join-Path $env:USERPROFILE '.config\mise'
New-Item -ItemType Directory -Force -Path $miseCfgDir | Out-Null
$miseCfg = Get-Content -Raw (Join-Path $Source 'config\mise\config.toml')
foreach ($t in 'uv', 'opa') {
    $v = Get-Ver $t
    if ($v) { $miseCfg = $miseCfg -replace "(?m)^$t = `"latest`"", "$t = `"$v`"" }
}
$miseCfg = $miseCfg -replace '(?m)^node = "lts"', 'node = "24.21.0"'
$miseCfg = $miseCfg -replace '(\[tools\."npm:@wonderwhy-er/desktop-commander"\]\r?\nversion = )"latest"', '$1"0.2.52"'
Set-Content -Path (Join-Path $miseCfgDir 'config.toml') -Value $miseCfg
$code = Invoke-Logged 'mise-install' { mise install --yes }
Update-Path
Add-Check 'mise install (config de Jo)' ($code -eq 0)
foreach ($t in 'uv', 'node', 'opa', 'git', 'claude') {
    $cmd = Get-Command $t -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    Add-Check "outil $t" ([bool]$cmd) $(if ($cmd) { $cmd.Source } else { 'introuvable' })
}
$uvWant = Get-Ver 'uv'
$uvHave = "$(uv --version)"
Add-Check "uv = $uvWant (comme Jo)" ($uvHave -match [regex]::Escape("uv $uvWant")) $uvHave

# --- 3. install-twin (jumeau francis-dev) ---------------------------------------------
Write-Host "`n== install-twin.ps1 =="
$code = Invoke-Logged 'install-twin' { pwsh -NoProfile -File (Join-Path $main 'scripts\install-twin.ps1') -Branch francis-dev -Remote $origin -NoInstall }
Add-Check 'install-twin.ps1 (code 0)' ($code -eq 0)
$twin = Join-Path $dev 'lena-francis-dev'
Add-Check 'jumeau : checkout francis-dev' ((Test-Path $twin) -and ((git -C $twin rev-parse --abbrev-ref HEAD).Trim() -eq 'francis-dev'))
Add-Check 'jumeau : CLAUDE.local.md importe LENA.md' ((Test-Path "$twin\CLAUDE.local.md") -and ((Get-Content -Raw "$twin\CLAUDE.local.md") -match '@docs/LENA.md'))
Add-Check 'jumeau : lanceur .cmd' (Test-Path (Join-Path $dev 'lena-francis-dev.cmd'))
Add-Check 'checkout principal intact' (-not (git -C $main status --porcelain))

# --- 4. install-tasks (vraies taches planifiees) ----------------------------------------
Write-Host "`n== install-tasks.ps1 =="
$code = Invoke-Logged 'install-tasks' { pwsh -NoProfile -File (Join-Path $main 'scripts\install-tasks.ps1') }
Add-Check 'install-tasks.ps1 (code 0)' ($code -eq 0)
foreach ($n in 'lena-claude-backup', 'lena-auto-commit', 'lena-nightly-ci', 'Desktop Commander Remote') {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    Add-Check "tache $n" ([bool]$t) $(if ($t) { "$($t.Principal.RunLevel), $(@($t.Triggers).Count) declencheur(s)" } else { 'absente' })
}
$nightly = Get-ScheduledTask -TaskName 'lena-nightly-ci' -ErrorAction SilentlyContinue
Add-Check 'lena-nightly-ci pointe sur le checkout principal' ($nightly -and $nightly.Actions[0].Arguments -match [regex]::Escape("$main\scripts\lena-nightly.ps1"))
Add-Check 'taches en RunLevel Limited' (@(Get-ScheduledTask -TaskName 'lena-*' | Where-Object { $_.Principal.RunLevel -ne 'Limited' }).Count -eq 0)
Push-Location $twin
$code = Invoke-Logged 'install-tasks-from-twin' { pwsh -NoProfile -File (Join-Path $twin 'scripts\install-tasks.ps1') }
Pop-Location
Add-Check 'install-tasks refuse un jumeau' ($code -ne 0)

# --- 5. backup-claude ------------------------------------------------------------------
Write-Host "`n== backup-claude.ps1 =="
$code = Invoke-Logged 'backup-claude' { pwsh -NoProfile -File (Join-Path $main 'scripts\backup-claude.ps1') }
Add-Check 'backup-claude.ps1 (code 0)' ($code -eq 0)
Add-Check 'conversation copiee dans D:\Backups\claude' (Test-Path 'D:\Backups\claude\projects\sim\session.jsonl')

# --- 6. auto-commit (snapshot + push vers origin local) --------------------------------
Write-Host "`n== auto-commit.ps1 =="
$before = (git -C $origin rev-parse main).Trim()
$code = Invoke-Logged 'auto-commit' { pwsh -NoProfile -File (Join-Path $main 'scripts\auto-commit.ps1') }
Get-Content (Join-Path $main 'scripts\auto-commit.log') -ErrorAction SilentlyContinue | Set-Content (Join-Path $out 'auto-commit.script.log')
Add-Check 'auto-commit.ps1 (code 0)' ($code -eq 0)
$after = (git -C $origin rev-parse main).Trim()
if ($after -ne $before) {
    $files = @(git -C $origin diff --name-only $before $after)
    $outside = @($files | Where-Object { $_ -notmatch '^config/' -and $_ -ne 'docs/INVENTAIRE.md' })
    Add-Check 'snapshot pousse : seulement config/ et docs/INVENTAIRE.md' ($outside.Count -eq 0) "$($files.Count) fichier(s)$(if ($outside) { ' ; hors zone : ' + ($outside -join ', ') })"
} else {
    Add-Check 'snapshot pousse (ou rien a commiter)' ($code -eq 0) 'origin inchange'
}
$leak = @(git -C $main grep -l -i -e $env:USERNAME -e ([regex]::Escape($env:USERPROFILE)) -- config 2>$null)
Add-Check "aucun nom de compte ni chemin de profil dans config/" ($leak.Count -eq 0) ($leak -join ', ')

# --- 7. lena-nightly : DryRun, vert, rouge force ------------------------------------------
Write-Host "`n== lena-nightly.ps1 =="
$code = Invoke-Logged 'nightly-dryrun' { pwsh -NoProfile -File (Join-Path $main 'scripts\lena-nightly.ps1') -DryRun }
Add-Check 'nightly -DryRun (code 0)' ($code -eq 0)
$code = Invoke-Logged 'nightly-green' { pwsh -NoProfile -File (Join-Path $main 'scripts\lena-nightly.ps1') }
Add-Check 'nightly vert (code 0)' ($code -eq 0)

$red = Join-Path $main 'plan-tools\tests\test_sim_red.py'
"def test_sim_red():`n    assert 1 + 1 == 3`n" | Set-Content -Path $red -NoNewline
git -C $main add -- $red
git -C $main commit -q -m 'test: simulated red test (simulator only, never pushed)'
$redHead = (git -C $main rev-parse HEAD).Trim()
$originBefore = (git -C $origin rev-parse main).Trim()
$code = Invoke-Logged 'nightly-red' { pwsh -NoProfile -File (Join-Path $main 'scripts\lena-nightly.ps1') }
$nlog = Get-Content -Raw (Join-Path $main 'scripts\lena-nightly.log') -ErrorAction SilentlyContinue
Set-Content -Path (Join-Path $out 'nightly.script.log') -Value $nlog
if ($env:ANTHROPIC_API_KEY) {
    Add-Check 'nightly rouge : Claude corrige, commit, push vers origin local' (($code -eq 0) -and ((git -C $origin rev-parse main).Trim() -ne $originBefore))
} else {
    Add-Check 'nightly rouge sans compte Claude : echec franc (code 1)' ($code -eq 1)
    Add-Check 'nightly rouge : « intervention humaine » au journal' ($nlog -match 'intervention humaine')
    Add-Check 'nightly rouge : rien commite ni pousse' (((git -C $main rev-parse HEAD).Trim() -eq $redHead) -and ((git -C $origin rev-parse main).Trim() -eq $originBefore))
}
git -C $main reset -q --hard $originBefore

# --- 8. Boucle autonome sous Git Bash -------------------------------------------------------
Write-Host "`n== Boucle autonome (Git Bash) =="
$bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
Add-Check 'Git Bash present' (Test-Path $bash) $bash
Push-Location $main
$code = Invoke-Logged 'loop-selftest' { & $bash scripts/test-lena-loop.sh }
Add-Check 'test-lena-loop.sh sous Git Bash' ($code -eq 0)
$code = Invoke-Logged 'lena-check' { & $bash scripts/lena-check.sh HEAD }
git reset -q
Add-Check 'lena-check.sh sur le commit teste (vert)' ($code -eq 0)
Pop-Location

# --- 9. plan-tools sur le faux OneDrive ------------------------------------------------------
Write-Host "`n== plan-tools (OneDrive simule) =="
Push-Location $main
$code = Invoke-Logged 'plan-inventory' { uv run --project plan-tools plan-tools inventory S-0001 }
Add-Check 'inventaire S-0001' ($code -eq 0)
$code = Invoke-Logged 'plan-bom' { uv run --project plan-tools plan-tools bom S-0001 }
Add-Check 'bordereau S-0001' ($code -eq 0)
$code = Invoke-Logged 'plan-route' { uv run --project plan-tools plan-tools route S-0002 }
Add-Check 'trace des conduits S-0002' ($code -eq 0)
$code = Invoke-Logged 'plan-missing' { uv run --project plan-tools plan-tools inventory S-9999 }
Add-Check 'projet absent : erreur claire, pas de plantage' (($code -ne 0) -and ((Get-Content -Raw (Join-Path $out 'plan-missing.log')) -match 'Aucun dossier'))
Pop-Location
$outDir = Join-Path $env:LOCALAPPDATA 'plan-tools\out'
Add-Check 'bordereau CSV produit' ([bool](Get-ChildItem $outDir -Recurse -Filter '*.bom.csv' -ErrorAction SilentlyContinue))
Add-Check 'copie « - IA.qpl » produite, .qpl d''origine intact' (
    [bool](Get-ChildItem $outDir -Recurse -Filter '* - IA.qpl' -ErrorAction SilentlyContinue) -and
    ((Get-FileHash (Join-Path $projects 'S-0002 Simulateur trace\route.qpl')).Hash -eq (Get-FileHash (Join-Path $Source 'plan-tools\tests\fixtures\route.qpl')).Hash))

# --- Bilan ------------------------------------------------------------------------------------
$failed = @($script:checks | Where-Object { -not $_.OK })
$script:checks | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Tee-Object -FilePath (Join-Path $out 'bilan.txt') | Write-Host
Write-Host ("Bilan : {0}/{1} verifications OK" -f ($script:checks.Count - $failed.Count), $script:checks.Count)
if ($env:GITHUB_STEP_SUMMARY) {
    $md = @('| Verification | Resultat | Detail |', '|---|---|---|') + ($script:checks | ForEach-Object { "| $($_.Check) | $(if ($_.OK) { 'OK' } else { '**FAIL**' }) | $($_.Detail -replace '\|', '/') |" })
    $md += '', ("**{0}/{1} verifications OK**" -f ($script:checks.Count - $failed.Count), $script:checks.Count)
    $md | Add-Content -Path $env:GITHUB_STEP_SUMMARY
}
exit $(if ($failed) { 1 } else { 0 })
