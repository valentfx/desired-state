param([Parameter(Mandatory=$true)][string]$PackageRoot,
      [Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$manifest = Join-Path $PackageRoot 'layout-update-files.txt'
if (!(Test-Path -LiteralPath $manifest -PathType Leaf)) { throw 'Layout update manifest missing.' }
$app = Join-Path $RepositoryRoot 'mobile\desired_state_app'
if (!(Test-Path -LiteralPath (Join-Path $app 'pubspec.yaml')) -or
    !(Test-Path -LiteralPath (Join-Path $app 'lib\h10_accelerometer.dart'))) {
    throw 'Wrong checkout or H10 ACC baseline missing. No files changed.'
}
$files = @(Get-Content -LiteralPath $manifest | Where-Object { $_.Trim() })
if ($files.Count -eq 0) { throw 'Empty update manifest.' }
foreach ($relative in $files) {
    if ($relative.Contains('..') -or [IO.Path]::IsPathRooted($relative) -or
        $relative -notmatch '^(AGENTS\.md|help/[A-Za-z0-9_-]+\.md|mobile/desired_state_app/(lib|test)/[A-Za-z0-9_]+\.dart|tools/[A-Za-z0-9_]+\.ps1)$') {
        throw "Unexpected update path: $relative"
    }
    if (!(Test-Path -LiteralPath (Join-Path $PackageRoot $relative) -PathType Leaf)) {
        throw "Missing update file: $relative"
    }
}
$backup = Join-Path (Split-Path $RepositoryRoot -Parent) ('desired-state-layout-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
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
Write-Host "Layout source update applied. Backup: $backup"

