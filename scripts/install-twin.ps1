#Requires -Version 7
# Installe (ou met a jour) un jumeau de Lena sur ce PC : un checkout du repo par branche,
# a cote de lena-ai-jo, avec les outils et les dependances verifies.
#   francis-dev        -> %USERPROFILE%\dev\lena-francis-dev
#   estimateur-junior  -> %USERPROFILE%\dev\lena-estimateur-junior
# Chaque jumeau recoit un CLAUDE.local.md (ignore par git) qui importe docs\LENA.md :
# Claude Code lance dans ce dossier suit les regles de Lena et trouve les skills (.claude\skills).
# Usage : pwsh -File scripts\install-twin.ps1 [-Branch francis-dev,estimateur-junior]
#                                             [-Root "$env:USERPROFILE\dev"] [-SkipTests] [-WhatIf]
# Pas besoin d'admin. Idempotent : relancer met a jour (git pull --ff-only), ne refait pas le clone.
# Ne touche jamais au checkout principal (lena-ai-jo) ni aux taches planifiees.
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Branch = @('francis-dev', 'estimateur-junior'),
    [string]$Root = (Join-Path $env:USERPROFILE 'dev'),
    [string]$Remote = 'https://github.com/fvegiard-lena/lena-ai-jo.git',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:GIT_TERMINAL_PROMPT = '0'

$script:checks = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [bool]$Ok, [string]$Detail = '', [bool]$Required = $true) {
    $script:checks.Add([pscustomobject]@{ Check = $Name; OK = $Ok; Required = $Required; Detail = $Detail })
    $mark = if ($Ok) { 'OK  ' } elseif ($Required) { 'FAIL' } else { 'WARN' }
    Write-Host ("[{0}] {1}{2}" -f $mark, $Name, ($(if ($Detail) { " - $Detail" } else { '' })))
}

# Lance une commande native, capture la sortie, retourne $true si le code de sortie est 0.
function Invoke-Native([string]$Name, [string]$Exe, [string[]]$Arguments, [string]$WorkDir = $null, [bool]$Required = $true) {
    if (-not $PSCmdlet.ShouldProcess(($(if ($WorkDir) { $WorkDir } else { $PWD })), "$Exe $($Arguments -join ' ')")) {
        Add-Check $Name $true 'WhatIf' $Required
        return $true
    }
    $out = $null
    try {
        if ($WorkDir) { Push-Location $WorkDir }
        $out = & $Exe @Arguments 2>&1
        $code = $LASTEXITCODE
    } catch {
        $out = "$_"
        $code = 1
    } finally {
        if ($WorkDir) { Pop-Location }
    }
    $tail = (@($out) | Select-Object -Last 3 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' | '
    if ($tail.Length -gt 200) { $tail = $tail.Substring(0, 200) + '...' }
    Add-Check $Name ($code -eq 0) ($(if ($code -eq 0) { '' } else { "code $code : $tail" })) $Required
    return ($code -eq 0)
}

# --- 1. Outils ----------------------------------------------------------------
Write-Host "`n== Outils =="
function Test-Tool([string]$Name, [bool]$Required, [string]$Hint) {
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    Add-Check "outil $Name" ([bool]$cmd) ($(if ($cmd) { $cmd.Source } else { $Hint })) $Required
    return [bool]$cmd
}

$hasGit  = Test-Tool 'git'  $true  'installer Git for Windows (winget install Git.Git)'
$hasMise = Test-Tool 'mise' $false 'winget install jdx.mise (voir RUNBOOK section 5)'
$hasUv   = Test-Tool 'uv'   $false 'mise use -g uv@latest'
if (-not $hasUv -and $hasMise) {
    # Regle Lena : lib / outil manquant -> on l'installe, on ne demande pas.
    if (Invoke-Native 'mise use -g uv@latest' 'mise' @('use', '-g', 'uv@latest') -Required $false) {
        Invoke-Native 'mise reshim' 'mise' @('reshim') -Required $false | Out-Null
        $hasUv = Test-Tool 'uv' $false 'mise use -g uv@latest a echoue'
    }
}
$null = Test-Tool 'node'   $false 'mise use -g node@lts'
$null = Test-Tool 'claude' $false 'installateur natif Claude Code (https://code.claude.com/docs/en/setup)'
if (-not $hasGit) {
    Write-Host "`ngit est obligatoire : rien d'autre ne peut etre fait."
    exit 1
}

# --- 2. Un checkout par branche ----------------------------------------------
$mainRepo = Join-Path $Root 'lena-ai-jo'
if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }

$twins = @()
foreach ($b in $Branch) {
    Write-Host "`n== Jumeau $b =="
    $dir = Join-Path $Root ("lena-" + ($b -replace '[^A-Za-z0-9._-]', '-'))
    $twins += [pscustomobject]@{ Branch = $b; Dir = $dir }

    if (Test-Path (Join-Path $dir '.git')) {
        # Deja clone : mise a jour en avance rapide seulement (jamais de reset, jamais de perte de travail local)
        $ok = Invoke-Native "$b : git fetch" 'git' @('fetch', '--quiet', 'origin', $b) $dir
        if ($ok) { $ok = Invoke-Native "$b : git checkout $b" 'git' @('checkout', '--quiet', $b) $dir }
        if ($ok) { $ok = Invoke-Native "$b : git pull --ff-only" 'git' @('pull', '--quiet', '--ff-only', 'origin', $b) $dir }
    } elseif (Test-Path $dir) {
        Add-Check "$b : dossier $dir" $false 'existe mais n''est pas un depot git - le deplacer ou le supprimer, puis relancer'
        continue
    } else {
        $cloneArgs = @('clone', '--quiet', '--branch', $b)
        if (Test-Path (Join-Path $mainRepo '.git')) {
            # Reutilise les objets du checkout principal pour le clone, puis s'en detache (jumeau autonome)
            $cloneArgs += @('--reference-if-able', $mainRepo, '--dissociate')
        }
        $cloneArgs += @($Remote, $dir)
        $ok = Invoke-Native "$b : git clone" 'git' $cloneArgs
    }
    if (-not $ok) { continue }

    # Branche effectivement en place ? (pas de clone en -WhatIf : on saute)
    $inPlace = Test-Path (Join-Path $dir '.git')
    if ($inPlace) {
        Push-Location $dir
        try { $head = (git rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim() } finally { Pop-Location }
        Add-Check "$b : branche courante" ($head -eq $b) ($(if ($head -eq $b) { "$head @ $dir" } else { "HEAD = '$head' (attendu : $b)" }))
    }

    # CLAUDE.local.md : Claude Code lit ce fichier a la racine du projet (ignore par git) et
    # importe docs\LENA.md. Les skills de .claude\skills sont decouvertes toutes seules.
    $local = Join-Path $dir 'CLAUDE.local.md'
    $content = @(
        '# Lena - jumeau sur la branche ' + $b
        ''
        'Tu es Lena. Tes regles completes, a appliquer telles quelles :'
        ''
        '@docs/LENA.md'
        ''
        'Branche de travail de ce checkout : `' + $b + '`. Jamais de push direct sur `main` : PR vers `main`.'
        ''
    ) -join "`n"
    if ($PSCmdlet.ShouldProcess($local, 'ecrire CLAUDE.local.md')) {
        [IO.File]::WriteAllText($local, $content, [Text.UTF8Encoding]::new($false))
    }
    Add-Check "$b : CLAUDE.local.md" ((Test-Path $local) -or $WhatIfPreference) $local

    # Identite git locale au jumeau si aucune n'est configuree (pour commiter sans question)
    if ($inPlace) {
        Push-Location $dir
        try {
            if (-not (git config user.name))  { git config user.name "L$([char]0xE9)na ($b)" }
            if (-not (git config user.email)) { git config user.email 'lena@users.noreply.github.com' }
        } finally { Pop-Location }
    }

    # Dependances Python des outils (meme commande que la CI : --locked)
    foreach ($proj in @('plan-tools', 'code-rag')) {
        if (-not (Test-Path (Join-Path $dir $proj 'pyproject.toml'))) { continue }
        if (-not $hasUv) { Add-Check "$b : uv sync $proj" $false 'uv absent' $false; continue }
        Invoke-Native "$b : uv sync $proj" 'uv' @('sync', '--locked', '--project', $proj) $dir -Required $false | Out-Null
    }
}

# --- 3. Verification (tests, comme la CI) -------------------------------------
if (-not $SkipTests -and $hasUv) {
    Write-Host "`n== Tests =="
    foreach ($t in $twins) {
        if (-not (Test-Path (Join-Path $t.Dir '.git'))) { continue }
        if (Test-Path (Join-Path $t.Dir 'plan-tools' 'pyproject.toml')) {
            Invoke-Native "$($t.Branch) : pytest plan-tools" 'uv' @('run', '--project', 'plan-tools', 'pytest', '-q', 'plan-tools') $t.Dir -Required $false | Out-Null
        }
        if (Test-Path (Join-Path $t.Dir 'code-rag' 'pyproject.toml')) {
            Invoke-Native "$($t.Branch) : pytest code-rag (unitaires)" 'uv' @('run', '--project', 'code-rag', 'pytest', '-q', '-m', 'not integration', 'code-rag') $t.Dir -Required $false | Out-Null
        }
    }
}

# --- 4. Bilan -----------------------------------------------------------------
Write-Host "`n== Bilan =="
$script:checks | Format-Table -AutoSize Check, OK, Required, Detail | Out-String -Width 200 | Write-Host
$total = $script:checks.Count
$okCount = @($script:checks | Where-Object OK).Count
$failedRequired = @($script:checks | Where-Object { -not $_.OK -and $_.Required }).Count
$rate = if ($total) { [math]::Round(100.0 * $okCount / $total, 1) } else { 0 }
Write-Host ("Taux de succes : {0}/{1} ({2} %)" -f $okCount, $total, $rate)
foreach ($t in $twins) {
    Write-Host ("Jumeau {0} : {1}  ->  cd `"{1}`" ; claude" -f $t.Branch, $t.Dir)
}
if ($failedRequired) {
    Write-Host "$failedRequired verification(s) obligatoire(s) en echec : voir ci-dessus."
    exit 1
}
exit 0
