# Sauvegarde automatique des conversations Claude (Cowork + Claude Code)
# Copie additive : ne supprime JAMAIS rien dans la destination.
# Une conversation effacee a la source reste donc recuperable ici.
# Tache planifiee : lena-claude-backup (voir Task Scheduler)

$src   = Join-Path $env:USERPROFILE '.claude\projects'
$dest  = 'D:\Backups\claude'
$log   = Join-Path $dest 'backup.log'

New-Item -ItemType Directory -Force -Path (Join-Path $dest 'projects') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dest 'config') | Out-Null

# Rotation simple du log (repart a zero au-dela de 5 Mo)
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 5MB)) {
    Remove-Item $log -Force
}

Add-Content -Path $log -Value ("[{0}] Debut sauvegarde" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# /E : sous-dossiers inclus ; pas de /MIR ni /PURGE -> jamais de suppression cote backup
$roboOut = robocopy $src (Join-Path $dest 'projects') /E /Z /R:2 /W:5 /NP /NDL /NFL
$rc = $LASTEXITCODE
$roboOut | Where-Object { $_ -match '\S' } | Add-Content -Path $log

# Config Claude (ecrasee a chaque passage : seule la derniere version compte)
foreach ($f in @('.claude.json', '.claude\CLAUDE.md', '.claude\settings.json', '.claude\keybindings.json')) {
    $p = Join-Path $env:USERPROFILE $f
    if (Test-Path $p) { Copy-Item $p (Join-Path $dest 'config') -Force }
}

# Codes robocopy 0 a 7 = succes ; 8+ = echec
$status = if ($rc -lt 8) { 'OK' } else { 'ECHEC' }
Add-Content -Path $log -Value ("[{0}] Fin sauvegarde - {1} (code robocopy {2})" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $status, $rc)

exit $(if ($rc -lt 8) { 0 } else { 1 })
