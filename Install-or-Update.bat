@echo off
rem Double-click to install or update. Downloads the newest pack from GitHub, then applies it.
title Project Zomboid server pack
set "PACK_REPO=tannerdio/pz-server-pack"
set "PACK_BRANCH=main"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; try { $d=Join-Path $env:LOCALAPPDATA 'PZServerPack'; New-Item -ItemType Directory -Force $d | Out-Null; $z=Join-Path $d 'pack.zip'; Write-Host 'Downloading the newest pack...'; Invoke-WebRequest -UseBasicParsing ('https://github.com/' + $env:PACK_REPO + '/archive/refs/heads/' + $env:PACK_BRANCH + '.zip') -OutFile $z; $x=Join-Path $d 'pack'; if (Test-Path $x) { Remove-Item $x -Recurse -Force }; Expand-Archive $z $x; $r=(Get-ChildItem $x -Directory | Select-Object -First 1).FullName; & (Join-Path $r 'install.ps1'); exit $LASTEXITCODE } catch { Write-Host ('Failed: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }"
echo.
pause
