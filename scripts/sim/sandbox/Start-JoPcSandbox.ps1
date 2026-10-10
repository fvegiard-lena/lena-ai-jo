#Requires -Version 7
# Lance le PC de Jo simule dans Windows Sandbox (Windows 11 jetable, efface a la fermeture).
# Sur l'hote : prepare %USERPROFILE%\lena-sim (scripts + journaux), ecrit JoPc.wsb, ouvre la Sandbox.
# Dans la Sandbox, Bootstrap.ps1 installe les outils comme chez Jo, clone francis-dev depuis GitHub,
# lance scripts\sim\Test-JoPc.ps1 puis les vraies taches planifiees. Journaux : %USERPROFILE%\lena-sim\out.
# Prerequis (une fois, admin + redemarrage) :
#   Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
# Usage : pwsh -File scripts\sim\sandbox\Start-JoPcSandbox.ps1 [-Branch francis-dev]
[CmdletBinding()]
param([string]$Branch = 'francis-dev')

$ErrorActionPreference = 'Stop'
$exe = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
if (-not (Test-Path $exe)) {
    throw 'Windows Sandbox absent : Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All (admin), puis redemarrer.'
}

$hostDir = Join-Path $env:USERPROFILE 'lena-sim'
New-Item -ItemType Directory -Force -Path (Join-Path $hostDir 'out') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'Bootstrap.ps1'), (Join-Path $PSScriptRoot 'Start-RealLoop.ps1') $hostDir -Force
Set-Content -Path (Join-Path $hostDir 'branch.txt') -Value $Branch -NoNewline

$wsb = Join-Path $hostDir 'JoPc.wsb'
@"
<Configuration>
  <MemoryInMB>8192</MemoryInMB>
  <Networking>Enable</Networking>
  <ClipboardRedirection>Enable</ClipboardRedirection>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$hostDir</HostFolder>
      <SandboxFolder>C:\sim\host</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File C:\sim\host\Bootstrap.ps1</Command>
  </LogonCommand>
</Configuration>
"@ | Set-Content -Path $wsb -Encoding utf8

Write-Host "Sandbox : $wsb (branche $Branch). Journaux : $hostDir\out"
Start-Process $exe -ArgumentList "`"$wsb`""
