# Rebuilds the bundle from the mod sources and pushes it to GitHub. Friends then run Install-or-Update.bat.
#
#   .\publish.ps1                          sync, commit, push
#   .\publish.ps1 -Message "GunSwap 1.1"   same, with a commit message
#   .\publish.ps1 -Add MyNewMod            also start shipping c:\01 Development\modding\MyNewMod
param([string]$Message = ("Update " + (Get-Date -Format 'yyyy-MM-dd HH:mm')), [string[]]$Add = @())
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'sync-bundle.ps1') -Add $Add

git -C $PSScriptRoot add -A
git -C $PSScriptRoot diff --cached --quiet
if ($LASTEXITCODE -eq 0) { Write-Output 'Nothing changed since the last publish.'; return }
git -C $PSScriptRoot commit -q -m $Message
if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
git -C $PSScriptRoot push -q
if ($LASTEXITCODE -ne 0) { throw 'git push failed' }
Write-Output "Published: $Message"
