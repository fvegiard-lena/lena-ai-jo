#Requires -Version 7.2
# Installe (ou met a jour) un jumeau de Lena sur ce PC : un checkout du repo par branche,
# a cote de lena-ai-jo, avec les outils et les dependances verifies, un dossier de config
# Claude Code par compte et un lanceur par jumeau.
#   francis-dev        -> <Root>\lena-francis-dev        (Francis : compte fvegiard@gmail.com, config .claude-francis)
#   Estimateur-2       -> <Root>\lena-Estimateur-2       (estimateur 2 : compte lena.ai.dr.routeur@gmail.com, config .claude-routeur)
#   estimateur-junior  -> <Root>\lena-estimateur-junior  (les autres estimateurs : meme compte que l'estimateur 2 pour le moment)
# <Root> = %USERPROFILE%\dev par defaut (-Root pour le changer, ex. -Root D:\github sur le PC de Francis).
# Chaque jumeau recoit un CLAUDE.local.md (ignore par git, jamais reecrit s'il existe) qui importe
# docs\LENA.md : Claude Code lance dans ce dossier suit les regles de Lena et trouve les skills.
# Chaque compte recoit son dossier de config Claude Code (%USERPROFILE%\.claude-<cle>, login separe du
# compte principal du PC) ; le lanceur <Root>\lena-<branche>.cmd pose CLAUDE_CONFIG_DIR, va dans le
# jumeau et lance claude. Premiere fois : /login avec le compte du jumeau. -SharedLogin : pas de
# dossier separe, le jumeau roule sous le compte deja connecte sur ce PC (ancien comportement).
# Le lanceur refuse de partir depuis un terminal ouvert dans Claude Desktop / Claude Code (l'identite du
# compte principal y est dans l'environnement et serait semee dans le jumeau), coupe l'auto-mise-a-jour
# (binaire claude partage par tous les comptes) et les jetons API de l'environnement. Un dossier de config
# jamais connecte qui porte l'identite d'un autre compte est nettoye (.claude.json retire).
# Usage : pwsh -File scripts\install-twin.ps1 [-Branch francis-dev,Estimateur-2,estimateur-junior]
#         [-Root "$env:USERPROFILE\dev"] [-SkipTests] [-NoInstall] [-SharedLogin] [-WhatIf]
# Pas besoin d'admin. Idempotent : relancer met a jour (git pull --ff-only), ne refait pas le clone,
# ne reecrit ni CLAUDE.local.md ni le settings.json du dossier de config ; le lanceur est regenere.
# Outil manquant -> installe (winget / mise / installateur Claude Code), sauf avec -NoInstall.
# Ne touche jamais au checkout principal (lena-ai-jo), ni a %USERPROFILE%\.claude, ni aux taches planifiees.
# -WhatIf : montre tout, n'ecrit rien (ni clone, ni config git, ni fichier, ni installation).
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Branch = @('francis-dev', 'Estimateur-2', 'estimateur-junior'),
    [string]$Root = (Join-Path $env:USERPROFILE 'dev'),
    [string]$Remote = 'https://github.com/fvegiard-lena/lena-ai-jo.git',
    [switch]$SkipTests,
    [switch]$NoInstall,
    [switch]$SharedLogin
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:GIT_TERMINAL_PROMPT = '0'

# « pwsh -File ... -Branch a,b » passe la chaine « a,b » telle quelle : on la decoupe nous-memes.
$Branch = @($Branch | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# Chemin absolu : [IO.File] ne suit pas le dossier courant de PowerShell.
$Root = [IO.Path]::GetFullPath($Root, $PWD.ProviderPath)

# Compte Claude de chaque jumeau (decision de Francis, 2026-10-09) et cle du dossier de config
# %USERPROFILE%\.claude-<cle>. Deux branches avec la meme cle partagent le meme login.
$script:comptes = @{
    'francis-dev'       = @{ Compte = 'fvegiard@gmail.com';           Cle = 'francis' }
    'Estimateur-2'      = @{ Compte = 'lena.ai.dr.routeur@gmail.com'; Cle = 'routeur' }
    'estimateur-junior' = @{ Compte = 'lena.ai.dr.routeur@gmail.com'; Cle = 'routeur' }
}
function Get-Compte([string]$b) {
    if ($script:comptes.ContainsKey($b)) { return $script:comptes[$b] }
    return @{ Compte = '[A CONFIRMER - Francis]'; Cle = ($b.ToLowerInvariant() -replace '[^a-z0-9]', '-') }
}

$script:checks = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [bool]$Ok, [string]$Detail = '', [bool]$Required = $true) {
    $script:checks.Add([pscustomobject]@{ Check = $Name; OK = $Ok; Required = $Required; Detail = $Detail })
    $mark = if ($Ok) { 'OK  ' } elseif ($Required) { 'FAIL' } else { 'WARN' }
    Write-Host ("[{0}] {1}{2}" -f $mark, $Name, ($(if ($Detail) { " - $Detail" } else { '' })))
}

# Lance une commande native, capture la sortie, retourne $true si le code de sortie est 0.
# Sous -WhatIf : rien n'est lance, l'etape est comptee OK.
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

function Get-GitHead([string]$Dir) {
    Push-Location $Dir
    try { return (git rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim() } finally { Pop-Location }
}

# --- 1. Outils ----------------------------------------------------------------
Write-Host "`n== Outils =="
function Test-Tool([string]$Name, [bool]$Required, [string]$Hint) {
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    Add-Check "outil $Name" ([bool]$cmd) ($(if ($cmd) { $cmd.Source } else { $Hint })) $Required
    return [bool]$cmd
}

# Un outil installe pendant ce script n'est pas encore sur le PATH du process : on le recharge
# (Machine + User + shims mise), puis on reteste.
function Update-Path {
    if (-not $IsWindows) { return }
    $parts = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User'),
        (Join-Path $env:LOCALAPPDATA 'mise\shims'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd'),
        (Join-Path $env:ProgramFiles 'Git\cmd'),
        (Join-Path $env:USERPROFILE '.local\bin')
    ) | Where-Object { $_ }
    $env:Path = ($parts -join ';')
}

# Regle Lena : outil manquant -> on l'installe, on ne demande pas (sauf -NoInstall).
$install = (-not $NoInstall) -and $IsWindows
$hasWinget = [bool](Get-Command winget -CommandType Application -ErrorAction SilentlyContinue)

$hasGit = Test-Tool 'git' $true 'winget install --id Git.Git -e'
if (-not $hasGit -and $install -and $hasWinget) {
    if (Invoke-Native 'winget install Git.Git' 'winget' @('install', '--id', 'Git.Git', '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Required $false) {
        Update-Path; $hasGit = Test-Tool 'git' $true 'installe mais introuvable : rouvrir un terminal et relancer'
    }
}
$hasMise = Test-Tool 'mise' $false 'winget install --id jdx.mise -e (RUNBOOK section 5)'
if (-not $hasMise -and $install -and $hasWinget) {
    if (Invoke-Native 'winget install jdx.mise' 'winget' @('install', '--id', 'jdx.mise', '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Required $false) {
        Update-Path; $hasMise = Test-Tool 'mise' $false 'installe mais introuvable : rouvrir un terminal et relancer'
    }
}
$hasUv = Test-Tool 'uv' $false 'mise use -g uv@latest'
if (-not $hasUv -and $install -and $hasMise) {
    if (Invoke-Native 'mise use -g uv@latest' 'mise' @('use', '-g', 'uv@latest') -Required $false) {
        Invoke-Native 'mise reshim' 'mise' @('reshim') -Required $false | Out-Null
        Update-Path; $hasUv = Test-Tool 'uv' $false 'mise use -g uv@latest a echoue'
    }
}
$hasNode = Test-Tool 'node' $false 'mise use -g node@lts'
if (-not $hasNode -and $install -and $hasMise) {
    if (Invoke-Native 'mise use -g node@lts' 'mise' @('use', '-g', 'node@lts') -Required $false) {
        Invoke-Native 'mise reshim' 'mise' @('reshim') -Required $false | Out-Null
        Update-Path; $hasNode = Test-Tool 'node' $false 'mise use -g node@lts a echoue'
    }
}
# Les shims mise (node, uv...) doivent etre sur le PATH utilisateur, sinon les sessions lancees par le lanceur
# ne les voient pas (RUNBOOK section 5). Ajoute une fois, idempotent.
$shims = Join-Path $env:LOCALAPPDATA 'mise\shims'
if ($IsWindows -and (Test-Path $shims)) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $present = @(($userPath -split ';') | Where-Object { $_ }) -contains $shims
    if (-not $present -and $PSCmdlet.ShouldProcess('PATH utilisateur', "ajouter $shims")) {
        [Environment]::SetEnvironmentVariable('Path', ((@($userPath, $shims) | Where-Object { $_ }) -join ';'), 'User')
        Update-Path
        $present = $true
    }
    Add-Check 'PATH utilisateur : shims mise' ($present -or $WhatIfPreference) $shims $false
}

$hasClaude = Test-Tool 'claude' $false 'installateur natif : irm https://claude.ai/install.ps1 | iex'
if (-not $hasClaude -and $install) {
    # Installateur officiel Claude Code (Windows) : https://code.claude.com/docs/en/setup
    if ($PSCmdlet.ShouldProcess('claude.ai/install.ps1', 'installer Claude Code')) {
        try {
            Invoke-Expression (Invoke-RestMethod 'https://claude.ai/install.ps1') | Out-Null
            Update-Path; $hasClaude = Test-Tool 'claude' $false 'installe mais introuvable : rouvrir un terminal et relancer'
        } catch {
            Add-Check 'installer Claude Code' $false "$_" $false
        }
    } else {
        Add-Check 'installer Claude Code' $true 'WhatIf' $false
    }
}
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
    $gitDir = Join-Path $dir '.git'

    if (Test-Path $gitDir) {
        # Deja clone. Le remote doit etre le bon : sinon on ne tire rien de la.
        Push-Location $dir
        try { $url = (git remote get-url origin 2>$null | Out-String).Trim() } finally { Pop-Location }
        $sameRemote = (($url -replace '\.git$', '').TrimEnd('/')) -ieq (($Remote -replace '\.git$', '').TrimEnd('/'))
        Add-Check "$b : remote origin" $sameRemote ($(if ($sameRemote) { $url } else { "origin = '$url' (attendu : $Remote) - corriger : git -C `"$dir`" remote set-url origin $Remote" }))
        if (-not $sameRemote) { continue }

        # Mise a jour en avance rapide seulement : jamais de reset, jamais de perte de travail local.
        # Jumeau parque sur une autre branche (travail en cours) : on fetch, on ne bascule pas.
        $head = Get-GitHead $dir
        $parked = ($head -ne $b)
        $ok = Invoke-Native "$b : git fetch" 'git' @('fetch', '--quiet', 'origin', $b) $dir
        if ($ok -and -not $parked) {
            $ok = Invoke-Native "$b : git pull --ff-only" 'git' @('pull', '--quiet', '--ff-only', 'origin', $b) $dir
        } elseif ($ok) {
            Add-Check "$b : branche courante" $false "HEAD = '$head' (travail en cours) : fetch seulement, pas de checkout. Pour revenir : git -C `"$dir`" checkout $b" $false
        }
    } elseif (Test-Path $dir) {
        Add-Check "$b : dossier $dir" $false 'existe mais n''est pas un depot git - le deplacer ou le supprimer, puis relancer'
        continue
    } else {
        $parked = $false
        $cloneArgs = @('clone', '--quiet', '--branch', $b)
        if (Test-Path (Join-Path $mainRepo '.git')) {
            # Reutilise les objets du checkout principal pour le clone, puis s'en detache (jumeau autonome)
            $cloneArgs += @('--reference-if-able', $mainRepo, '--dissociate')
        }
        $cloneArgs += @($Remote, $dir)
        $ok = Invoke-Native "$b : git clone" 'git' $cloneArgs
    }
    # Clone rate : rien a faire. Fetch/pull rate sur un jumeau existant : deja signale, on continue quand meme
    # (CLAUDE.local.md, dossier de config, lanceur restent utiles hors ligne).
    if (-not $ok -and -not (Test-Path $gitDir)) { continue }
    $twins += [pscustomobject]@{ Branch = $b; Dir = $dir }

    # Sous -WhatIf, un clone n'a pas eu lieu : les etapes qui lisent le depot sont sautees.
    $inPlace = Test-Path $gitDir
    if ($inPlace -and -not $WhatIfPreference -and -not $parked) {
        $head = Get-GitHead $dir
        Add-Check "$b : branche courante" ($head -eq $b) ($(if ($head -eq $b) { "$head @ $dir" } else { "HEAD = '$head' (attendu : $b)" }))
    }

    # CLAUDE.local.md : Claude Code lit ce fichier a la racine du projet (ignore par git) et
    # importe docs\LENA.md. Les skills de .claude\skills sont decouvertes toutes seules.
    # Fichier present = reglages perso de la personne : on n'y touche pas.
    $local = Join-Path $dir 'CLAUDE.local.md'
    if (Test-Path $local) {
        Add-Check "$b : CLAUDE.local.md" $true "$local (existant, conserve)"
    } else {
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
    }

    # Dossier de config Claude Code du compte du jumeau (login separe de %USERPROFILE%\.claude)
    # et lanceur <Root>\lena-<branche>.cmd qui pose CLAUDE_CONFIG_DIR puis lance claude dans le jumeau.
    $compte = Get-Compte $b
    $safe = ($b -replace '[^A-Za-z0-9._-]', '-')
    $launcher = Join-Path $Root ("lena-" + $safe + '.cmd')
    $remCompte = if ($SharedLogin) { 'compte Claude deja connecte sur ce PC (-SharedLogin)' } else { 'compte Claude : ' + $compte.Compte }
    $lines = @(
        '@echo off',
        ('rem Jumeau Lena ' + $b + ' - ' + $remCompte + ' (genere par install-twin.ps1, regenere a chaque passage)'),
        'set "DISABLE_AUTOUPDATER=1"',
        'where claude >nul 2>&1 || (echo [jumeau] Claude Code introuvable : irm https://claude.ai/install.ps1 ^| iex, puis rouvrir le terminal. & pause & exit /b 1)'
    )
    if (-not $SharedLogin) {
        $cfgName = '.claude-' + $compte.Cle
        $cfg = Join-Path $env:USERPROFILE $cfgName
        if (-not (Test-Path $cfg)) {
            if ($PSCmdlet.ShouldProcess($cfg, 'creer le dossier de config Claude Code')) {
                New-Item -ItemType Directory -Path $cfg -Force | Out-Null
            }
        }
        Add-Check "$b : dossier de config" ((Test-Path $cfg) -or $WhatIfPreference) "$cfg (compte $($compte.Compte))"
        # Dossier jamais connecte (pas de .credentials.json) dont .claude.json porte l'identite d'un AUTRE compte :
        # semee par un claude lance depuis une session Claude hebergee (Desktop/Code). On le retire, sinon le
        # jumeau resterait etiquete avec le mauvais compte apres /login.
        $cj = Join-Path $cfg '.claude.json'
        if ((Test-Path $cj) -and -not (Test-Path (Join-Path $cfg '.credentials.json'))) {
            try { $mail = (Get-Content -Raw -Path $cj | ConvertFrom-Json).oauthAccount.emailAddress } catch { $mail = $null }
            if ($mail -and ($mail -ne $compte.Compte)) {
                if ($PSCmdlet.ShouldProcess($cj, "retirer l'identite parasite $mail (dossier jamais connecte)")) {
                    Remove-Item -Force -Path $cj
                }
                Add-Check "$b : identite parasite retiree" $true "$cj portait $mail (dossier jamais connecte)" $false
            }
        }
        # settings.json : meme source pour tous les jumeaux (config\claude\settings.json du repo), sans ce qui
        # est propre a un PC (statusLine, enabledPlugins), plus DISABLE_AUTOUPDATER (binaire claude partage).
        # Jamais reecrit s'il existe : reglages de la personne.
        $seed = Join-Path $dir 'config' 'claude' 'settings.json'
        $dst = Join-Path $cfg 'settings.json'
        if (Test-Path $dst) {
            Add-Check "$b : settings.json" $true "$dst (existant, conserve)" $false
        } elseif (Test-Path $seed) {
            try {
                $obj = Get-Content -Raw -Path $seed | ConvertFrom-Json
                foreach ($k in @('statusLine', 'enabledPlugins')) {
                    if ($obj.PSObject.Properties[$k]) { $obj.PSObject.Properties.Remove($k) }
                }
                if (-not $obj.PSObject.Properties['env']) { $obj | Add-Member -NotePropertyName 'env' -NotePropertyValue ([pscustomobject]@{}) }
                if (-not $obj.env.PSObject.Properties['DISABLE_AUTOUPDATER']) { $obj.env | Add-Member -NotePropertyName 'DISABLE_AUTOUPDATER' -NotePropertyValue '1' }
                if ($PSCmdlet.ShouldProcess($dst, 'ecrire settings.json (depuis config\claude\settings.json du repo)')) {
                    [IO.File]::WriteAllText($dst, ($obj | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
                }
                Add-Check "$b : settings.json" ((Test-Path $dst) -or $WhatIfPreference) $dst $false
            } catch {
                Add-Check "$b : settings.json" $false "$_" $false
            }
        } elseif ($WhatIfPreference) {
            Add-Check "$b : settings.json" $true 'WhatIf' $false
        } else {
            Add-Check "$b : settings.json" $false 'pas de config\claude\settings.json dans le jumeau' $false
        }
        $lines += @(
            'rem Jamais depuis un terminal ouvert dans Claude Desktop / Claude Code : l''identite du compte principal',
            'rem (CLAUDE_CODE_ACCOUNT_UUID, CLAUDE_CODE_USER_EMAIL...) y est dans l''environnement et serait semee ici.',
            'if defined CLAUDE_CODE_ACCOUNT_UUID goto :heberge',
            'if defined CLAUDECODE goto :heberge',
            'set "CLAUDE_CODE_OAUTH_TOKEN="',
            'set "ANTHROPIC_API_KEY="',
            'set "ANTHROPIC_AUTH_TOKEN="',
            ('set "CLAUDE_CONFIG_DIR=%USERPROFILE%\' + $cfgName + '"')
        )
    } else {
        $lines += 'rem -SharedLogin : compte Claude deja connecte sur ce PC (pas de CLAUDE_CONFIG_DIR)'
    }
    # Le jumeau est a cote du lanceur (%~dp0 = dossier du lanceur) : le lanceur reste valable si <Root> est deplace
    # et ne depend pas de l'encodage du chemin (nom du jumeau ASCII par construction).
    $lines += @(
        ('cd /d "%~dp0lena-' + $safe + '" || (echo [jumeau] Dossier lena-' + $safe + ' introuvable a cote du lanceur : relancer install-twin.ps1. & pause & exit /b 1)'),
        'claude %*',
        'rem Double-clic (sans argument) : laisser lire le message avant que la fenetre se ferme. Jamais en usage scripte.',
        'if errorlevel 1 if "%~1"=="" pause',
        'exit /b %ERRORLEVEL%'
    )
    if (-not $SharedLogin) {
        $lines += @(
            ':heberge',
            'echo [jumeau] Ouvre ce lanceur depuis un terminal Windows normal (menu Demarrer, Windows Terminal), pas depuis une session Claude : le compte principal serait reutilise.',
            'exit /b 1'
        )
    }
    if ($PSCmdlet.ShouldProcess($launcher, 'ecrire le lanceur')) {
        [IO.File]::WriteAllText($launcher, (($lines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($false))
    }
    Add-Check "$b : lanceur" ((Test-Path $launcher) -or $WhatIfPreference) $launcher

    # Identite git locale au jumeau si aucune n'est configuree (pour commiter sans question).
    # Adresse noreply du compte GitHub proprietaire du repo (fvegiard-lena, id 197432373).
    if ($inPlace -and $PSCmdlet.ShouldProcess($dir, 'git config user.name / user.email (seulement si absents)')) {
        Push-Location $dir
        try {
            if (-not (git config user.name))  { git config user.name "L$([char]0xE9)na ($b)" }
            if (-not (git config user.email)) { git config user.email '197432373+fvegiard-lena@users.noreply.github.com' }
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
    $c = Get-Compte $t.Branch
    $l = Join-Path $Root ("lena-" + ($t.Branch -replace '[^A-Za-z0-9._-]', '-') + '.cmd')
    Write-Host ("Jumeau {0} : {1}" -f $t.Branch, $t.Dir)
    if ($SharedLogin) {
        Write-Host ("   lancer : {0}   (compte Claude deja connecte sur ce PC)" -f $l)
    } else {
        Write-Host ("   lancer : {0}   compte {1}, config %USERPROFILE%\.claude-{2} - 1re fois : /login" -f $l, $c.Compte, $c.Cle)
    }
}
if ($failedRequired) {
    Write-Host "$failedRequired verification(s) obligatoire(s) en echec : voir ci-dessus."
    exit 1
}
exit 0
