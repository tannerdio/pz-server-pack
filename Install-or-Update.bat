@echo off
rem Double-click to install or update. Downloads the newest pack from GitHub, then applies it.
rem If the browser or Windows refuses this file (unknown publisher, invalid signature), use the
rem one-line command in the README instead: it does the same thing with nothing to download.
title Project Zomboid server pack
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; try { [Net.ServicePointManager]::SecurityProtocol='Tls12' } catch { }; try { Invoke-RestMethod 'https://raw.githubusercontent.com/tannerdio/pz-server-pack/main/get.ps1' | Invoke-Expression } catch { Write-Host ('Failed: ' + $_.Exception.Message) -ForegroundColor Red }"
echo.
pause
