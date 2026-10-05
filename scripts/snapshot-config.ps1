#Requires -Version 7
# Copie la config vivante de Jo dans config/ avec les secrets et l'identite masques
# (SID, compte Windows, courriels, chemin du profil -> %USERPROFILE%, taux interne,
# identifiants de comptes Claude dans config/desktop/).
# Idempotent : relancer sans changement ne modifie rien dans git.
# Ne copie JAMAIS ~/.claude.json ni ~/.claude/.credentials.json.
# Appele par auto-commit.ps1 (tache planifiee lena-auto-commit).

$ErrorActionPreference = 'Stop'
$repo   = Split-Path -Parent $PSScriptRoot
$cfg    = Join-Path $repo 'config'
$claude = Join-Path $env:USERPROFILE '.claude'
$utf8   = [Text.UTF8Encoding]::new($false)
$script:copied = 0

# --- Masquage des secrets -----------------------------------------------------
# Nom de cle secret : le mot-cle doit etre le DERNIER segment du nom (debut, apres _ . -
# ou une majuscule camelCase) -> api_key, GITHUB_TOKEN, accessToken, client_secret, db_pwd,
# secretKey... mais PAS max_tokens, tokenizer, token_count, apiKeyHelper.
$kwAlt  = 'api[_-]?key|token|secret|passw(?:or)?d|pwd|private[_-]?key|access[_-]?key|authorization|bearer'
$keyEnd = '(?:(?:^|(?<=[\W_])|(?<=(?-i:[a-z0-9]))(?=(?-i:[A-Z])))(?:' + $kwAlt + ')|_key|(?<=(?-i:[a-z0-9]))(?-i:Key))'
# JSON : "cle": "valeur"
$jsonRx = [regex]::new('("[^"\r\n]*?' + $keyEnd + '"\s*:\s*)"(?:[^"\\\r\n]|\\.)*"', 'IgnoreCase')
# TOML / YAML / MD : cle = valeur | cle: valeur (en debut de ligne, commentee ou non, item de liste
# YAML ou non). Un bloc YAML « cle: | » est traite a part (Protect-YamlBlocks).
$lineRx = [regex]::new('^([ \t]*(?:#[ \t]*)?(?:-[ \t]+)?["'']?[\w.-]*?' + $keyEnd + '["'']?[ \t]*[=:][ \t]*)' +
    '(?![|>][-+0-9]*[ \t]*(?:#[^\r\n]*)?\r?$)(?=\S)[^\r\n]+', 'IgnoreCase, Multiline')
# YAML : « cle: | » / « cle: >- » -> les lignes plus indentees qui suivent sont masquees aussi
$yamlBlockRx = [regex]::new('^([ \t]*)(?:-[ \t]+)?["'']?[\w.-]*?' + $keyEnd + '["'']?[ \t]*:[ \t]*[|>][-+0-9]*[ \t]*(?:#.*)?$', 'IgnoreCase')
# Jetons reconnaissables, peu importe la cle (prefixes sensibles a la casse)
$tokRx  = [regex]::new('\b(?:sk-ant-[\w-]{20,}|sk-[\w-]{20,}|hf_\w{30,}|AKIA[0-9A-Z]{16}|xox[abpr]-[^\s"''`,;<>]+|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_\w{20,})')
# Cle privee PEM : tout le bloc, pas seulement l'en-tete
$pemRx  = [regex]::new('-----BEGIN ([A-Z ]*)PRIVATE KEY-----[\s\S]*?(?:-----END \1PRIVATE KEY-----|\z)')
# URL : valeur des parametres ?token= &api_key= &client_secret= &password= ...
$urlRx  = [regex]::new('([?&](?:[\w.-]*[_.-])?(?:token|key|secret|password|api[_-]?key)=)[^&#\s"''<>]+', 'IgnoreCase')
$bearRx = [regex]::new('\b(Bearer)[ \t]+[\w.~+/=-]{8,}', 'IgnoreCase')

# --- Masquage de l'identite (le repo est PUBLIC) ------------------------------
# Compte Windows (SID, <UserId>, <Author>), courriels, chemin du profil, taux interne.
$sidRx  = [regex]::new('S-1-5-21-[\d-]+')
$userRx = [regex]::new('<(UserId|Author)>[^<]*</\1>')
# Le dernier label doit commencer par une lettre : « pkg@1.2.3 » n'est pas un courriel.
$mailRx = [regex]::new('[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z][\w-]*')
$rateRx = [regex]::new('\b124 ?\$ ?/ ?h\b')
# Identifiants de comptes / appareils Claude : seulement dans config/desktop/*.json
# (ailleurs un UUID est souvent un simple nom de fichier). Numerotes par ordre d'apparition.
$uuidRx = [regex]::new('[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', 'IgnoreCase')
$deskDir = (Join-Path $cfg 'desktop') + [IO.Path]::DirectorySeparatorChar
# Profil de QUI lance le script (jamais un nom en dur) : C:\Users\X, C:\\Users\\X (JSON),
# C:/Users/X, /c/Users/X -> %USERPROFILE%. Les copies dans config/ ne sont donc pas
# directement reutilisables : remettre le vrai chemin avant de restaurer un fichier.
$homeRx = $null
if ($env:USERPROFILE -match '^([A-Za-z]):\\(.+?)\\?$') {
    $sep    = '(?:\\{1,2}|/)'
    $tail   = ($Matches[2] -split '\\' | ForEach-Object { [regex]::Escape($_) }) -join $sep
    $homeRx = [regex]::new('(?:' + $Matches[1] + ':' + $sep + '|/' + $Matches[1] + '/)' + $tail + '(?![\w-])', 'IgnoreCase')
}

# Bloc YAML « cle_secrete: | » : les lignes de contenu (plus indentees que la cle) sont
# remplacees par une seule ligne « *** ». Idempotent : « *** » redonne « *** ».
function Protect-YamlBlocks([string]$Text) {
    $lines = $Text -split '\n'
    $out = [Collections.Generic.List[string]]::new()
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]; $i++
        $out.Add($line)
        $m = $yamlBlockRx.Match($line.TrimEnd("`r"))
        if (-not $m.Success) { continue }
        $keyIndent = $m.Groups[1].Value.Length
        $first = $null
        while ($i -lt $lines.Count) {
            $l = $lines[$i].TrimEnd("`r")
            if (-not $l.Trim()) {
                # Ligne vide : dans le bloc seulement si une ligne plus indentee suit
                $j = $i + 1
                while ($j -lt $lines.Count -and -not $lines[$j].Trim()) { $j++ }
                if ($j -ge $lines.Count) { break }
                $next = $lines[$j].TrimEnd("`r")
                if (($next.Length - $next.TrimStart().Length) -le $keyIndent) { break }
                $i++; continue
            }
            $lead = $l.Length - $l.TrimStart().Length
            if ($lead -le $keyIndent) { break }
            if ($null -eq $first) { $first = $lines[$i] -replace '^([ \t]*).*?(\r?)$', '$1***$2' }
            $i++
        }
        if ($null -ne $first) { $out.Add($first) }
    }
    $out -join "`n"
}

# Applique a chaque fichier texte copie. Les regles par cle (JSON / ligne) restent
# limitees aux formats de config ; les regles par motif s'appliquent partout.
function Protect-Secrets([string]$Path) {
    $ext  = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $orig = [IO.File]::ReadAllText($Path)
    if ($orig.IndexOf([char]0) -ge 0) { return }  # binaire
    $text = $orig
    if ($ext -in '.yaml', '.yml') { $text = Protect-YamlBlocks $text }
    if ($ext -in '.json', '.toml', '.yaml', '.yml', '.md') {
        $text = $jsonRx.Replace($text, '$1"***"')
        if ($ext -ne '.json') { $text = $lineRx.Replace($text, '$1"***"') }
    }
    $text = $pemRx.Replace($text, '-----BEGIN ${1}PRIVATE KEY-----***-----END ${1}PRIVATE KEY-----')
    $text = $tokRx.Replace($text, '***')
    $text = $urlRx.Replace($text, '${1}***')
    $text = $bearRx.Replace($text, '$1 ***')
    $text = $userRx.Replace($text, '<$1>***</$1>')
    $text = $sidRx.Replace($text, 'S-1-5-21-***')
    if ($homeRx) { $text = $homeRx.Replace($text, '%USERPROFILE%') }
    $text = $mailRx.Replace($text, '***@***')
    $text = $rateRx.Replace($text, '[taux interne]')
    if ($ext -eq '.json' -and $Path.StartsWith($deskDir, [StringComparison]::OrdinalIgnoreCase)) {
        $ids = @{}
        $text = $uuidRx.Replace($text, [Text.RegularExpressions.MatchEvaluator] {
                param($m)
                $k = $m.Value.ToLowerInvariant()
                if (-not $ids.ContainsKey($k)) { $ids[$k] = '<uuid-{0}>' -f ($ids.Count + 1) }
                $ids[$k]
            })
    }
    if ($text -cne $orig) { [IO.File]::WriteAllText($Path, $text, $utf8) }
}

function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $utf8)
    Protect-Secrets $Path
    $script:copied++
}

# Copie un fichier ; si la source n'existe plus, retire la copie perimee.
function Copy-Config([string]$Src, [string]$Dst) {
    if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) {
        if (Test-Path -LiteralPath $Dst) { Remove-Item -LiteralPath $Dst -Force }
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $Dst) | Out-Null
    Copy-Item -LiteralPath $Src -Destination $Dst -Force
    Protect-Secrets $Dst
    $script:copied++
}

# Lance un outil avec timeout (stdin ferme : un serveur MCP ne bloque pas).
function Get-ToolVersion([string]$Exe, [string[]]$ArgList) {
    try {
        $cmd = Get-Command $Exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $psi = [Diagnostics.ProcessStartInfo]::new($cmd.Source)
        foreach ($a in $ArgList) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $utf8
        $psi.StandardErrorEncoding = $utf8
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(30000)) { $p.Kill($true); return 'n/a' }
        $text = $out.Result.Trim()
        if (-not $text) { $text = $err.Result.Trim() }
        if ($p.ExitCode -ne 0 -or -not $text) { return 'n/a' }
        return $text
    } catch { return 'n/a' }
}

# desktop-commander n'a PAS d'option --version (il demarre le serveur stdio) : on lit son
# package.json (dossier node de mise, ou backend npm: de mise -> ...\node_modules\.bin).
function Get-DesktopCommanderVersion {
    try {
        $dir = Split-Path (& mise which desktop-commander 2>$null | Select-Object -First 1)
        $pkg = foreach ($d in $dir, (Split-Path $dir), (Split-Path (Split-Path $dir))) {
            Join-Path $d 'node_modules\@wonderwhy-er\desktop-commander\package.json'
        }
        $pkg = $pkg | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        return (Get-Content -Raw -LiteralPath $pkg | ConvertFrom-Json).version
    } catch { return 'n/a' }
}

# --- 1. Claude Code -----------------------------------------------------------
try {
    foreach ($f in 'settings.json', 'settings.local.json', 'CLAUDE.md', 'mcp.json', '.omc-config.json', 'launch.json', 'keybindings.json') {
        Copy-Config (Join-Path $claude $f) (Join-Path $cfg "claude\$f")
    }

    # HUD (sans *.log ni dossiers cache) + menage des fichiers disparus
    $hudSrc = Join-Path $claude 'hud'
    $hudDst = Join-Path $cfg 'claude\hud'
    $keep = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path $hudSrc) {
        foreach ($file in Get-ChildItem $hudSrc -Recurse -File) {
            $rel = [IO.Path]::GetRelativePath($hudSrc, $file.FullName)
            $dirs = @(($rel -split '[\\/]') | Select-Object -SkipLast 1)
            if ($file.Extension -in '.log', '.cache' -or ($dirs -contains 'cache') -or ($dirs -contains '.cache')) { continue }
            $dst = Join-Path $hudDst $rel
            Copy-Config $file.FullName $dst
            [void]$keep.Add($dst)
        }
    }
    if (Test-Path $hudDst) {
        Get-ChildItem $hudDst -Recurse -File | Where-Object { -not $keep.Contains($_.FullName) } | Remove-Item -Force
    }
} catch { Write-Warning "claude : $_" }

# --- 2. mise, Qdrant ----------------------------------------------------------
try {
    Copy-Config (Join-Path $env:USERPROFILE '.config\mise\config.toml') (Join-Path $cfg 'mise\config.toml')
    Copy-Config (Join-Path $env:USERPROFILE 'qdrant\config.yaml') (Join-Path $cfg 'qdrant\config.yaml')
} catch { Write-Warning "mise/qdrant : $_" }

# --- 3. Claude Desktop : preferences + NOMS des serveurs MCP seulement ---------
try {
    $desk = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
    if (Test-Path $desk) {
        $j = Get-Content -Raw -LiteralPath $desk | ConvertFrom-Json -AsHashtable
        $names = @(if ($j.mcpServers) { $j.mcpServers.Keys | Sort-Object })
        $out = [ordered]@{ mcpServerNames = $names; preferences = $j.preferences }
        Write-Text (Join-Path $cfg 'desktop\claude_desktop_config.preferences.json') ($out | ConvertTo-Json -Depth 50)
    }
} catch { Write-Warning "desktop : $_" }

# --- 4. Taches planifiees -----------------------------------------------------
$taskCount = 0
foreach ($name in 'lena-claude-backup', 'lena-auto-commit', 'lena-nightly-ci', 'Desktop Commander Remote', 'Qdrant Vector DB') {
    try {
        $slug = ($name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
        $dst  = Join-Path $cfg "tasks\$slug.xml"
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $task) {
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
            continue
        }
        $xml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
        # Fichier en UTF-8 : on aligne la declaration pour que l'XML reste valide.
        $xml = $xml -replace '^(<\?xml[^>]*encoding=")UTF-16(")', '${1}UTF-8${2}'
        Write-Text $dst $xml
        $taskCount++
    } catch { Write-Warning "tache $name : $_" }
}

# --- 5. Versions des outils ---------------------------------------------------
# 3e champ : lignes gardees (all / first / last) pour une sortie stable et lisible
$tools = @(
    @('claude', '--version', 'all'), @('mise', '--version', 'all'), @('mise', 'ls', 'all'),
    @('desktop-commander', '(package.json)', 'all'), @('promptfoo', '--version', 'last'), @('opa', 'version', 'first'),
    @('gh', '--version', 'first'), @('git', '--version', 'all'), @('uv', '--version', 'all')
)
# Lignes qui changent d'un jour a l'autre sans vrai changement (anciennes versions en attente
# de menage dans « mise ls ») : retirees pour ne pas creer un commit par jour.
$volatileRx = [regex]::new('\(pruned in [^)]*\)')
$rows = foreach ($t in $tools) {
    $v = if ($t[0] -eq 'desktop-commander') { Get-DesktopCommanderVersion } else { Get-ToolVersion $t[0] @($t[1]) }
    $lines = @($v -split '\r?\n' | Where-Object { $_.Trim() -and -not $volatileRx.IsMatch($_) })
    if ($t[2] -eq 'first') { $lines = @($lines | Select-Object -First 1) } elseif ($t[2] -eq 'last') { $lines = @($lines | Select-Object -Last 1) }
    $cell = (($lines | ForEach-Object { ($_.Trim() -replace '\s{2,}', ' ') }) | Where-Object { $_ }) -join '<br>'
    if (-not $cell) { $cell = 'n/a' }
    '| `{0} {1}` | {2} |' -f $t[0], $t[1], ($cell -replace '\|', '\|')
}
$md = @('# Versions des outils', '', 'Genere par `scripts/snapshot-config.ps1` (date : voir l''historique git).', '',
    '| Commande | Sortie |', '|---|---|') + $rows
Write-Text (Join-Path $cfg 'VERSIONS.md') (($md -join "`n") + "`n")
$okVer = @($rows | Where-Object { $_ -notmatch '\| n/a \|$' }).Count

Write-Host ("snapshot-config : {0} fichiers -> config/ (taches : {1}, versions : {2}/{3})" -f $script:copied, $taskCount, $okVer, $tools.Count)
exit 0
