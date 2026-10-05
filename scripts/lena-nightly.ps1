#Requires -Version 7
# CI locale de nuit du repo lena-ai-jo (tache planifiee lena-nightly-ci, 02:00, RunLevel Limited).
#   1. git pull --rebase --autostash (conflit -> rebase annule, log, exit 1)
#   2. tests : plan-tools + code-rag (unitaires) ; sorties dans %TEMP%\lena-nightly-*.log
#   3. si rouge : Claude Code headless corrige (plafond 2 $, 5 tours, outils Read/Edit/uv run)
#   4. retest : vert + changements -> commit « test(nightly): auto-fix <date> » + push ;
#      encore rouge -> rien commite, « ÉCHEC — intervention humaine », exit 1
# Jamais --dangerously-skip-permissions. Doc : docs/CI-CD.md
# Essai sans risque : pwsh -NoProfile -File scripts\lena-nightly.ps1 -DryRun   (ou -WhatIf)
#   -> pas de pull, tests lances, arret AVANT l'etape 3 (pas de Claude, pas de commit).
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repo = Split-Path -Parent $PSScriptRoot
$log  = Join-Path $PSScriptRoot 'lena-nightly.log'
$dry  = $DryRun -or $WhatIfPreference
# -WhatIf = -DryRun : le script saute lui-meme ses effets (pull, Claude, commit) ; le log et
# les sorties de tests, eux, doivent s'ecrire.
$WhatIfPreference = $false
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Chemins que la correction automatique a le droit de toucher / commiter
$fixPaths = @('plan-tools', 'code-rag' | Where-Object { Test-Path (Join-Path $repo $_) })

# Rotation simple du log (repart a zero au-dela de 5 Mo)
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 5MB)) {
    Remove-Item $log -Force
}

function Write-Log([string]$Msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    Add-Content -Path $log -Value $line
    Write-Host $line
}

trap {
    Write-Log "ECHEC inattendu : $_"
    exit 1
}

# Tache cachee : aucune invite ne doit bloquer git ; sorties Python en UTF-8
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'never'
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }

Set-Location $repo
Write-Log ('Debut nightly' + $(if ($dry) { ' (DRY-RUN : pas de pull, arret avant la correction)' } else { '' }))

$uv = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $uv) {
    Write-Log 'ECHEC : uv introuvable sur le PATH (mise reshim ?)'
    exit 1
}

# --- 1. Mise a jour ------------------------------------------------------------
$branch = "$(git rev-parse --abbrev-ref HEAD)".Trim()
if ($branch -ne 'main') {
    Write-Log "ECHEC : branche courante '$branch' (attendu : main) - rien fait"
    exit 1
}
if ($dry) {
    Write-Log 'DRY-RUN : git pull --rebase --autostash origin main saute'
} else {
    git pull --rebase --autostash origin main 2>&1 | ForEach-Object { Write-Log "git : $_" }
    if ($LASTEXITCODE -ne 0) {
        $code = $LASTEXITCODE
        $rebasing = (Test-Path (git rev-parse --git-path rebase-merge)) -or (Test-Path (git rev-parse --git-path rebase-apply))
        if ($rebasing) { git rebase --abort 2>&1 | ForEach-Object { Write-Log "git : $_" } }
        Write-Log "ECHEC pull --rebase (code $code) - rebase annule, rien d'autre fait"
        exit 1
    }
}

# --- 2. Tests ------------------------------------------------------------------
$suites = @(
    @{ Name = 'plan-tools'; Args = @('run', '--project', 'plan-tools', 'pytest', '-q', 'plan-tools') }
    @{ Name = 'code-rag'; Args = @('run', '--project', 'code-rag', 'pytest', '-q', '-m', 'not integration', 'code-rag') }
)

# Lance les suites presentes ; renvoie les noms en echec. Sortie complete dans $OutFile.
function Invoke-Tests([string]$OutFile) {
    $failed = @()
    foreach ($s in $suites) {
        if (-not (Test-Path (Join-Path $repo "$($s.Name)\pyproject.toml"))) {
            Write-Log "tests $($s.Name) : absent - saute"
            continue
        }
        Add-Content -Path $OutFile -Value ("===== uv {0}" -f ($s.Args -join ' '))
        & $uv.Source @($s.Args) *>&1 | ForEach-Object { "$_" } | Add-Content -Path $OutFile
        $code = $LASTEXITCODE
        Add-Content -Path $OutFile -Value ("===== code de sortie : {0}`n" -f $code)
        if ($code -ne 0) { $failed += $s.Name }
        Write-Log ("tests {0} : {1}" -f $s.Name, $(if ($code -eq 0) { 'OK' } else { "ROUGE (code $code)" }))
    }
    , $failed
}

$out1 = Join-Path $env:TEMP "lena-nightly-$stamp-tests.log"
$failed = Invoke-Tests $out1
Write-Log "Sortie des tests : $out1"

if (-not $failed) {
    Write-Log 'Fin nightly - OK (tout est vert)'
    exit 0
}

if ($dry) {
    Write-Log ("DRY-RUN : en echec : {0} - arret avant l'etape 3 (pas de Claude, pas de commit)" -f ($failed -join ', '))
    exit 0
}

# Du travail non commite dans plan-tools/ ou code-rag/ ? On ne le melange pas a une
# correction automatique (il finirait commite sans relecture) : humain d'abord.
$dirty = @(git status --porcelain -- @fixPaths)
if ($dirty) {
    Write-Log ("ÉCHEC — intervention humaine : tests rouges ({0}) et {1} fichier(s) non commite(s) dans plan-tools/ ou code-rag/ - pas de correction automatique" -f ($failed -join ', '), $dirty.Count)
    exit 1
}

# --- 3. Correction par Claude Code headless -------------------------------------
$claude = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $claude) {
    Write-Log 'claude introuvable sur le PATH - etape 3 sautee'
} else {
    # --bare : ni hooks, ni plugins, ni MCP, ni CLAUDE.md, mais n'utilise QUE ANTHROPIC_API_KEY
    # (jamais la connexion d'abonnement). Sans cle API : --safe-mode, meme isolation, garde la
    # connexion Claude du PC. Doc : https://code.claude.com/docs/en/headless#start-faster-with-bare-mode
    $mode = if ($env:ANTHROPIC_API_KEY) { '--bare' } else { '--safe-mode' }
    if ($mode -eq '--safe-mode') { Write-Log 'ANTHROPIC_API_KEY absente : --safe-mode au lieu de --bare (connexion Claude du PC)' }

    $system = "Tu corriges UNIQUEMENT les tests qui échouent dans plan-tools/ et code-rag/. Pas de refactor. Réponds en français."
    $prompt = ("Les tests suivants échouent : {0}. Leur sortie complète est sur l'entrée standard. " +
        "Corrige le code (ou le test s'il est clairement faux) dans plan-tools/ et code-rag/ seulement, " +
        "puis relance : uv run --project plan-tools pytest -q plan-tools ; " +
        "uv run --project code-rag pytest -q -m 'not integration' code-rag. Termine par un résumé de 3 lignes.") -f ($failed -join ', ')
    $claudeArgs = @('-p', $mode, '--output-format', 'json', '--permission-mode', 'dontAsk', '--max-turns', '5',
        '--max-budget-usd', '2.00', '--allowedTools', 'Read,Edit,Bash(uv run *)', '--append-system-prompt', $system, $prompt)

    # stdin : sortie des tests, plafonnee a 10 Mo (limite de claude -p) -> on garde la fin
    $bytes = [IO.File]::ReadAllBytes($out1)
    $cap = [Math]::Min($bytes.Length, 10MB - 64KB)
    $stdin = [Text.Encoding]::UTF8.GetString($bytes, $bytes.Length - $cap, $cap)

    $errFile = Join-Path $env:TEMP "lena-nightly-$stamp-claude.err.log"
    Write-Log ("claude {0} : debut (plafond 2.00 USD, 5 tours)" -f $mode)
    $raw = @($stdin | & $claude.Source @claudeArgs 2> $errFile)
    $claudeCode = $LASTEXITCODE

    $res = $null
    try { $res = ($raw -join "`n") | ConvertFrom-Json } catch {
        $last = $raw | Where-Object { "$_".TrimStart().StartsWith('{') } | Select-Object -Last 1
        if ($last) { try { $res = $last | ConvertFrom-Json } catch { } }
    }
    if ($res) {
        $text = "$($res.result)"
        if ($text.Length -gt 4000) { $text = $text.Substring(0, 4000) + ' [...]' }
        Write-Log ([string]::Format([cultureinfo]::InvariantCulture, 'claude : code {0}, subtype {1}, tours {2}, cout {3} USD, session {4}',
                $claudeCode, $res.subtype, $res.num_turns, $res.total_cost_usd, $res.session_id))
        Write-Log "claude .result : $text"
    } else {
        Write-Log "claude : code $claudeCode, reponse JSON illisible (stderr : $errFile)"
    }
}

# --- 4. Retest, commit si vert -----------------------------------------------------
$out2 = Join-Path $env:TEMP "lena-nightly-$stamp-retest.log"
$failed2 = Invoke-Tests $out2
Write-Log "Sortie du retest : $out2"

if ($failed2) {
    # On ne laisse pas de correction a moitie faite dans l'arbre : elle reste visible dans git diff
    # pour Francis, mais rien n'est commite ni pousse.
    Write-Log ("ÉCHEC — intervention humaine : encore rouge apres correction ({0}). Rien commite. Voir git diff, $out2" -f ($failed2 -join ', '))
    exit 1
}

$changes = @(git status --porcelain -- @fixPaths)
if (-not $changes) {
    Write-Log 'Retest vert sans changement de fichiers (test instable ?) - rien a commiter'
    Write-Log 'Fin nightly - OK'
    exit 0
}

if (-not (git config user.name))  { git config user.name "L$([char]0xE9)na (Jo)" }
if (-not (git config user.email)) { git config user.email 'lena@users.noreply.github.com' }

$subject = 'test(nightly): auto-fix {0}' -f (Get-Date -Format 'yyyy-MM-dd')
git add -- @fixPaths 2>&1 | ForEach-Object { Write-Log "git : $_" }
git commit -q -m $subject -- @fixPaths 2>&1 | ForEach-Object { Write-Log "git : $_" }
if ($LASTEXITCODE -ne 0) {
    Write-Log "ECHEC commit (code $LASTEXITCODE)"
    exit 1
}
Write-Log ("Commit : {0} ({1} fichier(s))" -f $subject, $changes.Count)

git push origin main 2>&1 | ForEach-Object { Write-Log "git : $_" }
if ($LASTEXITCODE -ne 0) {
    Write-Log "ECHEC push (code $LASTEXITCODE) - le commit reste local, pas de force-push"
    exit 1
}

Write-Log 'Fin nightly - OK (correction commitee et poussee)'
exit 0
