# Rebuilds the friend bundle from the mod sources: local-mods copies, their manifest, and the zip.
# Only writes inside pz-compat. Reads the server ini and bundle docs to warn about anything left to do by hand.
#
#   .\sync-bundle.ps1                 re-sync every local mod already in the bundle
#   .\sync-bundle.ps1 -Add MyNewMod   also start shipping c:\01 Development\modding\MyNewMod
param([string[]]$Add = @())
$ErrorActionPreference = 'Stop'

$here   = $PSScriptRoot
$src    = Split-Path $here -Parent
$bundle = Join-Path $here 'friend-bundle'
$local  = Join-Path $bundle 'local-mods'
$zip    = Join-Path $here 'pz-42.22.2-patches.zip'
$ini    = Join-Path $env:USERPROFILE 'Zomboid\Server\Viewpoint.ini'

$mods = @(@(Get-ChildItem $local -Directory | ForEach-Object { $_.Name }) + $Add | Sort-Object -Unique)

# 1. Mirror each mod source into the bundle, without dev-only files.
foreach ($m in $mods) {
    $from = Join-Path $src $m
    if (-not (Test-Path (Join-Path $from '42\mod.info'))) { throw "No mod source at $from (expected 42\mod.info)" }
    robocopy $from (Join-Path $local $m) /MIR /XF CLAUDE.md PLAN.md TESTING.md /XD (Join-Path $from 'tools') (Join-Path $from '.git') /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $m (exit $LASTEXITCODE)" }
}

# 2. Manifest: sha256 of every file under local-mods.
$prefix  = $local.TrimEnd('\') + '\'
$entries = @(Get-ChildItem $local -Recurse -File | Sort-Object FullName | ForEach-Object {
    [pscustomobject]@{
        path   = $_.FullName.Substring($prefix.Length)
        sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
    }
})
$json = ConvertTo-Json $entries
[IO.File]::WriteAllText((Join-Path $bundle 'local-mods-manifest.json'), $json + "`r`n", (New-Object Text.UTF8Encoding($false)))

# 3. Things this script does not edit: warn if they are out of step.
$todo = 0
$serverMods  = @()
if (Test-Path $ini) {
    $serverMods = ((Get-Content $ini | Where-Object { $_ -like 'Mods=*' }) -replace '^Mods=', '') -split ';'
} else {
    Write-Warning "Server ini not found: $ini"; $todo++
}
# Workshop ids the server uses, for the installer's "what is not downloaded yet" check.
if (Test-Path $ini) {
    $ids = @(((Get-Content $ini | Where-Object { $_ -like 'WorkshopItems=*' }) -replace '^WorkshopItems=', '') -split ';' | Where-Object { $_ -match '^\d+$' })
    [IO.File]::WriteAllText((Join-Path $bundle 'workshop-items.txt'), ($ids -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($false)))
}
$bundleList   = Get-Content (Join-Path $bundle 'default.txt')
$instructions = Get-Content (Join-Path $bundle 'INSTRUCTIONS.md') -Raw
foreach ($m in $mods) {
    $id = ((Get-Content (Join-Path $local "$m\42\mod.info") | Where-Object { $_ -like 'id=*' }) -replace '^id=', '').Trim()
    if (-not (Test-Path (Join-Path $local "$m\common"))) { Write-Warning "$m has no common\ folder (Build 42 expects one, even if it only holds .keep)"; $todo++ }
    if ($serverMods -notcontains $id) { Write-Warning "$id is not in Mods= of $ini"; $todo++ }
    if (-not ($bundleList -match ('^\s*mod = ' + [regex]::Escape($id) + ',\s*$'))) { Write-Warning "$id is not in friend-bundle\default.txt"; $todo++ }
    if ($instructions -notmatch [regex]::Escape("local-mods\$m")) { Write-Warning "$m is not mentioned in friend-bundle\INSTRUCTIONS.md"; $todo++ }
}

# 4. Zip.
if (Test-Path $zip) { Remove-Item $zip -Confirm:$false }
Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zip

Write-Output ("Synced {0} local mods ({1}), {2} files in manifest, zip {3:N0} KB, {4} warning(s)." -f $mods.Count, ($mods -join ', '), $entries.Count, ((Get-Item $zip).Length / 1KB), $todo)
