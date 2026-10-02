param([Parameter(Mandatory=$true)][string]$PackageRoot,
      [Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$manifestPath = Join-Path $PackageRoot 'h10-update-files.txt'
if (!(Test-Path -LiteralPath $manifestPath)) { throw 'Update file manifest missing.' }
$files = @(Get-Content -LiteralPath $manifestPath | Where-Object { $_.Trim() })
foreach ($relative in $files) {
    if ($relative.Contains('..') -or [IO.Path]::IsPathRooted($relative)) { throw 'Invalid update path.' }
    if (!(Test-Path -LiteralPath (Join-Path $PackageRoot $relative) -PathType Leaf)) {
        throw "Missing update file: $relative"
    }
}
$app = Join-Path $RepositoryRoot 'mobile\desired_state_app'
if (!(Test-Path -LiteralPath (Join-Path $app 'pubspec.yaml'))) { throw 'Wrong repository location.' }
$backup = Join-Path (Split-Path $RepositoryRoot -Parent) ('desired-state-source-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $backup | Out-Null
foreach ($relative in $files) {
    $destination = Join-Path $RepositoryRoot $relative
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $saved = Join-Path $backup $relative
        New-Item -ItemType Directory -Path (Split-Path $saved -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $destination -Destination $saved
    }
}
foreach ($relative in $files) {
    $destination = Join-Path $RepositoryRoot $relative
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot $relative) -Destination $destination -Force
}
Write-Host "Source update applied. Backup: $backup"
Write-Host 'Phone recording storage was not changed. Run validation before launching.'
