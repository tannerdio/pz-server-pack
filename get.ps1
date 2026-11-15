# Downloads the newest pack from GitHub and applies it. Nothing to download by hand: paste this line into
# Windows PowerShell and press Enter.
#
#   irm https://raw.githubusercontent.com/tannerdio/pz-server-pack/main/get.ps1 | iex
#
# Install-or-Update.bat runs the same thing.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $repo = 'tannerdio/pz-server-pack'
    $branch = 'main'
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = 'Tls12' } catch { }
        $dir = Join-Path $env:LOCALAPPDATA 'PZServerPack'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $zip = Join-Path $dir 'pack.zip'
        Write-Host 'Downloading the newest pack...'
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$repo/archive/refs/heads/$branch.zip" -OutFile $zip
        $pack = Join-Path $dir 'pack'
        if (Test-Path -LiteralPath $pack) { Remove-Item -LiteralPath $pack -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $pack
        $root = (Get-ChildItem -LiteralPath $pack -Directory | Select-Object -First 1).FullName
        $extra = @()
        if ($env:PZPACK_DRYRUN) { $extra = @('-DryRun') }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1') @extra
    } catch {
        Write-Host ('Failed: ' + $_.Exception.Message) -ForegroundColor Red
    }
}
