param(
    [string]$RepositoryRoot = 'F:\1dev\desired-state',
    [string]$FlutterBin = 'F:\1dev\flutter\bin',
    [string]$PackageRoot = (Split-Path $PSScriptRoot),
    [switch]$InstallPhone,
    [switch]$CommitChanges,
    [switch]$ResumeChecks
)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $RepositoryRoot
$RepositoryRoot = (Get-Location).Path
$env:Path = "$FlutterBin;$env:Path"
if (Get-Process desired_state_app -ErrorAction SilentlyContinue) {
    throw 'Stop uploads/recordings and close Windows Desired State first. Stop the phone recording before upgrading.'
}
$mergePath = git rev-parse --git-path MERGE_HEAD
if ($LASTEXITCODE -ne 0) { throw 'Not a Git repository.' }
if (@(git diff --name-only --diff-filter=U).Count -or (Test-Path -LiteralPath $mergePath)) {
    throw 'Complete the existing Git merge first.'
}
function Get-SourceTokens([string]$Source) {
    # Keep string contents; tolerate formatting/comments and single-return lint fixes.
    $pattern = @'
(?s)//[^\r\n]*|/\*.*?\*/|r?(?:\x27\x27\x27.*?\x27\x27\x27|""".*?"""|'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*")|\s+|.
'@
    $parts = foreach ($match in [regex]::Matches($Source, $pattern)) {
        $value = $match.Value
        if ($value -match '^(//|/\*|\s+$)') { continue }
        if ($value -match '^r?[\x27\x22]') {
            '__LITERAL_' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value)) + '__'
        } else { $value }
    }
    $tokens = [regex]::Replace(($parts -join ''), ',(?=[)\]}])', '')
    return [regex]::Replace($tokens, '\{(continue;|break;|return[^{};]*;)\}', '$1')
}
$manifest = Join-Path $PackageRoot 'paths.json'
if (!(Test-Path -LiteralPath $manifest)) { throw 'Package manifest missing. Select the EEG powerbands/optics ZIP.' }
$rows = @(Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })
$prepared = @{}
foreach ($row in $rows) {
    if (($row.path -notmatch '^(mobile/desired_state_app|tools)/[A-Za-z0-9_./-]+$' -and $row.path -notin @('help/git-updates.md', 'AGENTS.md')) -or
        $row.path -match '(^|/)\.\.(/|$)' -or $row.path -match ':') { throw 'Unsafe package path.' }
    $payload = Join-Path (Join-Path $PackageRoot 'payload') $row.path
    if ((Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash -ne $row.sha256) {
        throw "Package hash mismatch: $($row.path)"
    }
    # Local repository guidance is append-only, never replaced by the bundle.
    if ($row.path -eq 'AGENTS.md') { continue }
    if ($ResumeChecks) { continue }
    $target = Join-Path $RepositoryRoot $row.path
    $after = [IO.File]::ReadAllText($payload)
    if (Test-Path -LiteralPath $target) {
        $current = [IO.File]::ReadAllText($target)
        if ((Get-SourceTokens $current) -eq (Get-SourceTokens $after)) { continue }
        if (!$row.existing) { throw "New source already differs: $($row.path). No files applied." }
        $before = [IO.File]::ReadAllText((Join-Path (Join-Path $PackageRoot 'before') $row.path))
        if ((Get-SourceTokens $current) -ne (Get-SourceTokens $before)) {
            throw "Unexpected source: $($row.path). Preserved; no files applied. Send git status and this file's diff."
        }
    } elseif ($row.existing) { throw "Expected source missing: $($row.path). No files applied." }
    $prepared[$target] = $after
}
$notes = @(Get-Content (Join-Path $PackageRoot 'notes.json') -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })
$guide = [IO.File]::ReadAllText((Join-Path $PackageRoot 'payload/AGENTS.md'))
$heading = '## Copyable Git messages'
$offset = $guide.IndexOf($heading)
if ($offset -lt 0) { throw 'Git guidance section missing. No files applied.' }
$notes += [pscustomobject]@{ path = 'AGENTS.md'; text = $guide.Substring($offset).Trim() }
foreach ($note in $notes) {
    if ($note.path -notin @('help/current-state.md', 'help/roadmap.md', 'help/project-log.md', 'AGENTS.md')) { throw 'Unexpected documentation path. No files applied.' }
    if (!(Test-Path -LiteralPath (Join-Path $RepositoryRoot $note.path))) { throw "Documentation missing: $($note.path). No files applied." }
}
if (!$ResumeChecks) {
    $backup = "$RepositoryRoot-eeg-optics-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    foreach ($target in $prepared.Keys) {
        if (Test-Path -LiteralPath $target) {
            $saved = Join-Path $backup ($target.Substring($RepositoryRoot.Length + 1))
            New-Item -ItemType Directory -Path (Split-Path $saved) -Force | Out-Null
            Copy-Item -LiteralPath $target -Destination $saved
        }
    }
    foreach ($target in $prepared.Keys) {
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        [IO.File]::WriteAllText($target, $prepared[$target], [Text.UTF8Encoding]::new($false))
    }
    foreach ($note in $notes) {
        if ($note.path -notin @('help/current-state.md', 'help/roadmap.md', 'help/project-log.md', 'AGENTS.md')) { throw 'Unexpected documentation path.' }
        $doc = Join-Path $RepositoryRoot $note.path
        if (![IO.File]::ReadAllText($doc).Contains($note.text)) {
            $saved = Join-Path $backup $note.path
            New-Item -ItemType Directory -Path (Split-Path $saved) -Force | Out-Null
            Copy-Item -LiteralPath $doc -Destination $saved
            Add-Content -LiteralPath $doc -Encoding UTF8 -Value ("`n" + $note.text)
        }
    }
    Write-Host "Source applied. Backup: $backup"
}
function Invoke-Flutter([string[]]$Arguments) {
    & flutter @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter failed: $($Arguments -join ' '). Source preserved. Fix and rerun this same installer with -ResumeChecks."
    }
}
Push-Location 'mobile\desired_state_app'
try {
    Invoke-Flutter -Arguments @('pub', 'get')
    $dartPaths = @($rows | Where-Object { $_.path -like '*.dart' } | ForEach-Object { $_.path.Substring('mobile/desired_state_app/'.Length) })
    & dart format @dartPaths
    if ($LASTEXITCODE -ne 0) { throw 'Formatting failed.' }
    Invoke-Flutter -Arguments @('analyze', '--no-pub')
    Invoke-Flutter -Arguments @('test', '--no-pub')
    Invoke-Flutter -Arguments @('build', 'windows', '--release', '--no-pub', '--target', 'lib/main_windows.dart')
    if ($InstallPhone) {
        $gradle = [IO.File]::ReadAllText((Join-Path $PWD 'android\app\build.gradle.kts'))
        if ($gradle -notmatch 'applicationId\s*=\s*"com\.example\.desired_state_app"') {
            throw 'Android is not configured for the shared app ID. Preserved; no phone installed.'
        }
        Invoke-Flutter -Arguments @('build', 'apk', '--debug', '--no-pub')
        $adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
        $ready = @(& $adb devices | Where-Object { $_ -match '^\S+\s+device$' })
        if ($LASTEXITCODE -ne 0 -or $ready.Count -ne 1) { throw 'Connect one authorized phone. Builds complete; no phone installed.' }
        $device = ($ready[0] -split '\s+')[0]
        & $adb -s $device install -r 'build\app\outputs\flutter-apk\app-debug.apk'
        if ($LASTEXITCODE -ne 0) { throw 'Shared app upgrade failed. Do not uninstall it.' }
        & $adb -s $device shell am start -n 'com.example.desired_state_app/com.example.desired_state_app.MainActivity'
        if ($LASTEXITCODE -ne 0) { throw 'Phone launch failed.' }
    }
} finally { Pop-Location }
$validation = if ($InstallPhone) { 'Flutter analysis, full tests, Windows release and Android debug builds passed; shared phone upgraded in place.' } else { 'Flutter analysis, full tests and Windows release build passed. Android build/install not requested.' }
Add-Content -LiteralPath 'help/project-log.md' -Encoding UTF8 -Value "`nEEG/optical PC validation: $validation Physical optical acquisition, viewport and comparison acceptance remain pending."
$docs = @('help/current-state.md', 'help/roadmap.md', 'help/project-log.md', 'AGENTS.md')
foreach ($doc in $docs) {
    [IO.File]::WriteAllText((Join-Path $RepositoryRoot $doc), [IO.File]::ReadAllText((Join-Path $RepositoryRoot $doc)).TrimEnd() + "`n", [Text.UTF8Encoding]::new($false))
}
Add-Content -LiteralPath 'help/git-updates.md' -Encoding UTF8 -Value "`nPC validation: $validation Physical optical acquisition and viewport acceptance remain pending."
$commitPaths = @($rows | ForEach-Object { $_.path }) + $docs
if ($CommitChanges) {
& git add -- @commitPaths
if ($LASTEXITCODE -ne 0) { throw 'Staging failed.' }
& git diff --cached --check -- @commitPaths
if ($LASTEXITCODE -ne 0) { throw 'Whitespace check failed; commit pending.' }
& git commit --only -m 'Add unscreened EEG powerbands, optional artifact comparison and Athena optical capture' -m "Reuse comparison tools across Session details and Analyze; add Gamma, explicit dB units, persistent screening choice, concise RR tools and raw optical logging. Validation: $validation Hardware acceptance pending." -- @commitPaths
if ($LASTEXITCODE -ne 0) { throw 'Commit failed; upgrades complete, review git status.' }
}
$release = Join-Path $RepositoryRoot 'mobile\desired_state_app\build\windows\x64\runner\Release'
Start-Process -FilePath (Join-Path $release 'desired_state_app.exe') -WorkingDirectory $release
Write-Host 'Windows launched. Commit title/body and actual checks are in help/git-updates.md. No push performed.'
if (!$CommitChanges) { Write-Host 'Source preserved as working changes for your review and commit.' }
