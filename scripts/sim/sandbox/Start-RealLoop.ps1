#Requires -Version 7
# Dans Windows Sandbox, apres Bootstrap.ps1 et un /login dans claude : fait tourner la vraie boucle
# autonome (vraies sessions Claude) sur une tache sans risque, dans le jumeau francis-dev du simulateur.
# Son "origin" est le depot nu local du simulateur : rien ne part vers GitHub. Plafond : 1 $.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ($env:USERNAME -ne 'WDAGUtilityAccount') { throw 'Refus : Windows Sandbox seulement.' }

$twin = Join-Path $env:USERPROFILE 'dev\lena-francis-dev'
$out = 'C:\sim\host\out'
if (-not (Test-Path $twin)) { throw "Jumeau absent ($twin) : Bootstrap.ps1 d'abord." }
Push-Location $twin
git config user.name 'Lena (simulateur)'
git config user.email 'lena-sim@example.invalid'

$task = 'backlog\todo\20261010-sim-projects-spaces.md'
@'
# Tester find_project avec un code suivi d'espaces

Check: uv run --project plan-tools pytest -q plan-tools/tests/test_projects.py

Ajouter dans plan-tools/tests/test_projects.py un test qui prouve que find_project(" S-0723 ")
trouve le dossier « S-0723 (Projet) » (le code est nettoye de ses espaces). Ne rien changer d'autre.
'@ | Set-Content -Path $task -Encoding utf8
git add -- $task
git commit -q -m 'loop: seed simulator task'
$before = (git rev-parse HEAD).Trim()

$env:LENA_BUDGET_USD = '1'
$env:LENA_TASK_BUDGET_USD = '1'
$env:LENA_MAX_ITER = '3'
$env:LENA_PLAN = '0'
& (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') scripts/lena-loop.sh 2>&1 | Tee-Object -FilePath (Join-Path $out 'real-loop.log')
$code = $LASTEXITCODE
Copy-Item results.tsv (Join-Path $out 'real-loop-results.tsv') -ErrorAction SilentlyContinue
git log --oneline "$before..HEAD" | Tee-Object -FilePath (Join-Path $out 'real-loop-commits.txt')
$kept = Test-Path 'backlog\done\20261010-sim-projects-spaces.md'
"Boucle reelle : code $code ; tache gardee : $kept" | Tee-Object -FilePath (Join-Path $out 'real-loop-verdict.txt')
Pop-Location
