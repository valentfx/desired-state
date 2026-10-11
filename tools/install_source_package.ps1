param([string]$RepositoryRoot = (Get-Location).Path, [string]$ZipPath, [switch]$SkipApk)
$ErrorActionPreference = 'Stop'
if (!$ZipPath) {
    Write-Host 'Opening source ZIP picker (check Alt+Tab if the dialog is hidden)...'
    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $picker.Title = 'Select the Desired State source update ZIP'
        $picker.Filter = 'ZIP packages (*.zip)|*.zip'
        $picker.InitialDirectory = Join-Path $env:USERPROFILE 'Downloads'
        if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $ZipPath = $picker.FileName
    } finally { $picker.Dispose() }
}
Write-Host "Selected ZIP: $ZipPath"
$repo = (& git -C $RepositoryRoot rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0) { throw 'Run inside the Desired State repository.' }
$repo = $repo.Trim()
$stage = Join-Path $env:LOCALAPPDATA ('Temp\desired-state-source-' + [guid]::NewGuid().ToString('N'))
Write-Host "Extracting source package to $stage"
Expand-Archive -LiteralPath $ZipPath -DestinationPath $stage
$manifests = @(Get-ChildItem -LiteralPath $stage -Filter 'source-package.json' -Recurse -File)
if ($manifests.Count -ne 1) { throw 'The ZIP must contain exactly one source-package.json.' }
$manifest = Get-Content -LiteralPath $manifests[0].FullName -Raw | ConvertFrom-Json
$relative = [string]$manifest.installer
if ($manifest.version -ne 1 -or !$relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains('..') -or [IO.Path]::GetExtension($relative) -ne '.ps1') { throw 'Invalid package installer path.' }
$installer = Join-Path $manifests[0].DirectoryName $relative
if (!(Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'Package installer is missing.' }
$arguments = @{ RepositoryRoot = $repo }
if ($SkipApk) { $arguments.SkipApk = $true }
Write-Host "Running installer: $installer"
& $installer @arguments
