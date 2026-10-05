#Requires -Version 7
# Snapshot de la config + commit + push automatique du repo lena-ai-jo.
# Tache planifiee : lena-auto-commit (12:00 + ouverture de session).
# Ne commite QUE les artefacts du snapshot (config/ + docs/INVENTAIRE.md) : le travail
# en cours ailleurs dans le repo n'est jamais balaye dans main.
# gitleaks local sur le diff indexe s'il est installe (sinon : CI GitHub seulement).
# Avant le push : pull --rebase --autostash. Conflit -> rebase annule, log, exit 1.
# Jamais de force-push. Echec du push -> log + exit 1.

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false
$repo = Split-Path -Parent $PSScriptRoot
$log  = Join-Path $PSScriptRoot 'auto-commit.log'

# Seuls chemins que ce script a le droit de commiter
$snapshotPaths = @('config', 'docs/INVENTAIRE.md')

# Rotation simple du log (repart a zero au-dela de 5 Mo)
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 5MB)) {
    Remove-Item $log -Force
}

function Write-Log([string]$Msg) {
    Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg)
}

# Tache cachee : aucune invite de mot de passe ne doit bloquer git
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'never'

Set-Location $repo
Write-Log 'Debut auto-commit'

$branch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -ne 'main') {
    Write-Log "ECHEC : branche courante '$branch' (attendu : main) - rien fait"
    exit 1
}

& (Join-Path $PSScriptRoot 'snapshot-config.ps1') *>&1 | ForEach-Object { Write-Log "$_" }

# Identite git locale au repo si aucune n'est configuree
if (-not (git config user.name))  { git config user.name "L$([char]0xE9)na (Jo)" }
if (-not (git config user.email)) { git config user.email 'lena@users.noreply.github.com' }

$paths = @($snapshotPaths | Where-Object { Test-Path (Join-Path $repo $_) })
if (-not $paths) {
    Write-Log 'ECHEC : ni config/ ni docs/INVENTAIRE.md - rien a commiter'
    exit 1
}
git add -- @paths 2>&1 | ForEach-Object { Write-Log "$_" }
git diff --cached --quiet -- @paths
if ($LASTEXITCODE -eq 0) {
    # Rien de neuf, mais un push rate la derniere fois ? On le reessaie.
    $ahead = [int](git rev-list --count origin/main..main 2>$null)
    if ($ahead -eq 0) {
        Write-Log 'Rien a commiter - fin'
        exit 0
    }
    Write-Log "Rien a commiter, mais $ahead commit(s) pas encore pousse(s)"
} else {
    # Secrets : gitleaks local sur ce qui est indexe, s'il est installe.
    $gitleaks = Get-Command gitleaks -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gitleaks) {
        # gitleaks >= 8.19 : « git --pre-commit --staged » (protect est deprecie) ; avant : « protect --staged ».
        $raw = "$(& $gitleaks.Source version 2>$null)".Trim()
        $ver = $null
        $glArgs = @('git', '--pre-commit', '--staged')
        if ([version]::TryParse(($raw -replace '^v', '' -replace '[^0-9.].*$', ''), [ref]$ver) -and $ver -lt [version]'8.19.0') {
            $glArgs = @('protect', '--staged')
        }
        & $gitleaks.Source @glArgs --redact --no-banner --config (Join-Path $repo '.gitleaks.toml') 2>&1 |
            ForEach-Object { Write-Log "gitleaks : $_" }
        if ($LASTEXITCODE -ne 0) {
            git reset -q -- @paths 2>&1 | ForEach-Object { Write-Log "$_" }
            Write-Log "ECHEC gitleaks $raw (code $LASTEXITCODE) - secret possible dans le snapshot, rien commite"
            exit 1
        }
        Write-Log "gitleaks $raw : aucun secret dans le diff indexe"
    } else {
        Write-Log 'gitleaks absent — vérification CI seulement'
    }

    $subject = 'chore(snapshot): config {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')
    # « -- chemins » : seuls ces chemins entrent dans le commit, meme si autre chose est indexe.
    git commit -q -m $subject -- @paths 2>&1 | ForEach-Object { Write-Log "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ECHEC commit (code $LASTEXITCODE)"
        exit 1
    }
    Write-Log "Commit : $subject"
}

# Se remettre a jour avant de pousser (le travail local non commite est mis de cote puis remis).
git pull --rebase --autostash origin main 2>&1 | ForEach-Object { Write-Log "$_" }
if ($LASTEXITCODE -ne 0) {
    $code = $LASTEXITCODE
    $rebasing = (Test-Path (git rev-parse --git-path rebase-merge)) -or (Test-Path (git rev-parse --git-path rebase-apply))
    if ($rebasing) { git rebase --abort 2>&1 | ForEach-Object { Write-Log "$_" } }
    Write-Log "ECHEC pull --rebase (code $code) - rebase annule, commit garde en local, rien pousse"
    exit 1
}

git push origin main 2>&1 | ForEach-Object { Write-Log "$_" }
if ($LASTEXITCODE -ne 0) {
    Write-Log "ECHEC push (code $LASTEXITCODE) - le commit reste local, pas de force-push"
    exit 1
}

Write-Log 'Fin auto-commit - OK (push fait)'
exit 0
