# Installs or updates the server's mod patches on this PC. Normally started by Install-or-Update.bat,
# which downloads the newest copy of this repo first. Safe to run again at any time.
#
#   install.ps1            apply everything
#   install.ps1 -DryRun    only report what would change
param(
    [string]$Source = $PSScriptRoot,
    [string]$WorkshopDir,
    [string]$ZomboidDir = (Join-Path $env:USERPROFILE 'Zomboid'),
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

$bundle  = Join-Path $Source 'friend-bundle'
$modsDir = Join-Path $ZomboidDir 'mods'
$problems = 0

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Get-Sha([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }

function Find-Workshop {
    $roots = @()
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        $p = Get-ItemProperty $key -ErrorAction SilentlyContinue
        if ($p) { $roots += @($p.SteamPath, $p.InstallPath) }
    }
    $roots += 'C:\Program Files (x86)\Steam'
    $libs = @()
    foreach ($r in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
        $libs += $r
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($line in Get-Content -LiteralPath $vdf) {
                if ($line -match '^\s*"path"\s+"(.+)"\s*$') { $libs += ($Matches[1] -replace '\\\\', '\') }
            }
        }
    }
    foreach ($l in $libs) {
        $w = Join-Path $l 'steamapps\workshop\content\108600'
        if (Test-Path -LiteralPath $w) { return $w }
    }
    return $null
}

Say ''
Say '=== Project Zomboid server pack ===' 'Cyan'
if ($DryRun) { Say 'Dry run: nothing will be changed.' 'Yellow' }

# --- 0. Checks -------------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath (Join-Path $bundle 'manifest.json'))) { throw "No friend-bundle found in $Source" }

$running = @(Get-Process -Name 'ProjectZomboid64', 'ProjectZomboid32' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    if ($DryRun) { Say 'Project Zomboid is running (ignored in a dry run).' 'Yellow' }
    else { Say 'Project Zomboid is running. Close the game, then run this again.' 'Red'; exit 1 }
}

if (-not $WorkshopDir) { $WorkshopDir = Find-Workshop }
if (-not $WorkshopDir -or -not (Test-Path -LiteralPath $WorkshopDir)) {
    Say 'Could not find the Project Zomboid Workshop folder (steamapps\workshop\content\108600).' 'Red'
    Say 'Is the game installed through Steam, with at least one Workshop mod subscribed?' 'Red'
    exit 1
}
if (-not (Test-Path -LiteralPath $ZomboidDir)) {
    Say "Could not find $ZomboidDir. Start the game once so it creates the folder, then run this again." 'Red'
    exit 1
}
Say "Workshop folder: $WorkshopDir"
Say "Zomboid folder:  $ZomboidDir"

# --- 1. Patched Workshop files ---------------------------------------------------------------------
Say ''
Say 'Patched Workshop files' 'Cyan'
$manifest = Get-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
$done = 0; $already = 0; $missing = @(); $mismatch = @()
foreach ($e in $manifest) {
    $src = Join-Path (Join-Path $bundle 'workshop') $e.path
    $dst = Join-Path $WorkshopDir $e.path
    $id  = ($e.path -split '\\')[0]
    $leaf = Split-Path $e.path -Leaf
    if (-not (Test-Path -LiteralPath $dst)) { $missing += $e; continue }

    $suffix = '.pre-pzfix'
    if ($e.kind -eq 'mod.info') { $suffix = '.pre-unpin' }
    $backup = $dst + $suffix
    $have = Get-Sha $dst

    if ($have -eq $e.patched_sha256) { $already++; continue }

    $isOriginal = ($have -eq $e.original_sha256)
    # An older patch of ours: the untouched original is still sitting beside it as the backup.
    $isOldPatch = (-not $isOriginal) -and (Test-Path -LiteralPath $backup) -and ((Get-Sha $backup) -eq $e.original_sha256)
    if (-not ($isOriginal -or $isOldPatch)) { $mismatch += $e; continue }

    if ($DryRun) { Say "  would patch $id  $leaf"; $done++; continue }
    if ($isOriginal) { Copy-Item -LiteralPath $dst -Destination $backup -Force }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    if ((Get-Sha $dst) -ne $e.patched_sha256) { Say "  FAILED to patch $id  $leaf" 'Red'; $problems++; continue }
    Say "  patched $id  $leaf" 'Green'
    $done++
}
Say ("  {0} patched now, {1} already patched, {2} not downloaded, {3} different version" -f $done, $already, $missing.Count, $mismatch.Count)
foreach ($e in $missing) {
    $id = ($e.path -split '\\')[0]
    Say "  NOT DOWNLOADED: $(Split-Path $e.path -Leaf)  ->  https://steamcommunity.com/sharedfiles/filedetails/?id=$id" 'Yellow'
}
foreach ($e in $mismatch) {
    $id = ($e.path -split '\\')[0]
    Say "  DIFFERENT VERSION (left alone): $(Split-Path $e.path -Leaf), Workshop $id" 'Yellow'
}
if ($missing.Count -gt 0) {
    Say '  Subscribe to the mods above (or join the server once so the game downloads them), then run this again.' 'Yellow'
    $problems++
}
if ($mismatch.Count -gt 0) {
    Say '  A mod above was updated by its author, or Steam is still downloading. Let Steam finish and run this again;' 'Yellow'
    Say '  if it still shows up, tell the server host.' 'Yellow'
    $problems++
}

# --- 2. The host's own mods ------------------------------------------------------------------------
Say ''
Say "The host's own mods" 'Cyan'
if (-not (Test-Path -LiteralPath $modsDir) -and -not $DryRun) { New-Item -ItemType Directory -Path $modsDir | Out-Null }
$linked = @()
foreach ($m in Get-ChildItem -LiteralPath (Join-Path $bundle 'local-mods') -Directory) {
    $dst = Join-Path $modsDir $m.Name
    $existing = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
    if ($existing -and ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        # A link to a development copy (the host's own PC). Never mirror into it.
        $linked += $m.Name; Say "  $($m.Name): linked folder, left alone"; continue
    }
    if ($DryRun) { Say "  would copy $($m.Name)"; continue }
    robocopy $m.FullName $dst /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { Say "  FAILED to copy $($m.Name) (robocopy exit $LASTEXITCODE)" 'Red'; $problems++ }
    else { Say "  $($m.Name): up to date" 'Green' }
}
$bad = 0
foreach ($e in (Get-Content -LiteralPath (Join-Path $bundle 'local-mods-manifest.json') -Raw | ConvertFrom-Json)) {
    $name = ($e.path -split '\\')[0]
    if ($DryRun -and $linked -notcontains $name) {
        # In a dry run nothing was copied; only say whether a copy is needed.
        $p = Join-Path $modsDir $e.path
        if (-not (Test-Path -LiteralPath $p) -or (Get-Sha $p) -ne $e.sha256) { $bad++ }
        continue
    }
    $p = Join-Path $modsDir $e.path
    if (-not (Test-Path -LiteralPath $p) -or (Get-Sha $p) -ne $e.sha256) {
        $bad++
        if ($linked -contains $name) { Say "  differs from the pack: $($e.path)" 'Yellow' }
        else { Say "  FAILED check: $($e.path)" 'Red' }
    }
}
if ($DryRun) { Say "  $bad file(s) would be added or updated" }
elseif ($bad -gt 0) { Say "  $bad file(s) do not match the pack" 'Red'; $problems++ }
else { Say '  all files verified' }

# --- 3. Mod list -----------------------------------------------------------------------------------
Say ''
Say 'Mod list' 'Cyan'
$listSrc = Join-Path $bundle 'default.txt'
$listDst = Join-Path $modsDir 'default.txt'
if ($linked.Count -gt 0) {
    Say "  left alone (this looks like the host's own PC)"
} elseif ((Test-Path -LiteralPath $listDst) -and ((Get-Sha $listDst) -eq (Get-Sha $listSrc))) {
    Say '  already matches the server'
} elseif ($DryRun) {
    Say '  would replace default.txt (old one kept as a backup)'
} else {
    if (Test-Path -LiteralPath $listDst) {
        $keep = "$listDst.before-server-pack-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $listDst -Destination $keep
        Say "  your old list is kept as $(Split-Path $keep -Leaf)"
    }
    Copy-Item -LiteralPath $listSrc -Destination $listDst -Force
    Say '  replaced with the server list' 'Green'
}

# --- 4. Workshop subscriptions ---------------------------------------------------------------------
$idsFile = Join-Path $bundle 'workshop-items.txt'
if (Test-Path -LiteralPath $idsFile) {
    Say ''
    Say 'Workshop mods' 'Cyan'
    $ids = @(Get-Content -LiteralPath $idsFile | Where-Object { $_ -match '^\d+$' })
    $absent = @($ids | Where-Object { -not (Test-Path -LiteralPath (Join-Path $WorkshopDir $_)) })
    Say ("  {0} of {1} server mods are downloaded" -f ($ids.Count - $absent.Count), $ids.Count)
    if ($absent.Count -gt 0) {
        Say "  $($absent.Count) missing. The game downloads them when you join the server:" 'Yellow'
        foreach ($id in ($absent | Select-Object -First 10)) { Say "    https://steamcommunity.com/sharedfiles/filedetails/?id=$id" 'Yellow' }
        if ($absent.Count -gt 10) { Say "    ... and $($absent.Count - 10) more" 'Yellow' }
    }
}

# --- Summary ---------------------------------------------------------------------------------------
Say ''
if ($problems -gt 0) {
    Say 'Finished, but something above needs attention (yellow or red lines).' 'Yellow'
    exit 2
}
Say 'All done. You are in step with the server.' 'Green'
Say 'When the game starts it may ask you to approve changed mod jars: approve them.'
Say 'Do not use Steam "Verify integrity of game files"; it undoes the patches. If you did, run this again.'
exit 0
