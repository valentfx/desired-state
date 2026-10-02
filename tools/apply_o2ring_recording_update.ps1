param([Parameter(Mandatory = $true)][string]$RepoRoot)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$package = Split-Path -Parent $PSScriptRoot
$backup = Join-Path $env:TEMP ("desired-state-o2ring-recording-backup-" + [guid]::NewGuid())
$paths = @(
    'mobile\desired_state_app\lib\device_models.dart',
    'mobile\desired_state_app\lib\o2_ring_protocol.dart',
    'mobile\desired_state_app\lib\o2_ring_service.dart',
    'mobile\desired_state_app\lib\o2_ring_diagnostics_screen.dart',
    'mobile\desired_state_app\lib\device_screen.dart',
    'mobile\desired_state_app\lib\session_controller.dart',
    'mobile\desired_state_app\lib\session_logger.dart',
    'mobile\desired_state_app\lib\session_archive.dart',
    'mobile\desired_state_app\lib\session_history.dart',
    'mobile\desired_state_app\lib\main.dart',
    'mobile\desired_state_app\test\o2_ring_service_test.dart',
    'mobile\desired_state_app\test\o2_ring_recording_test.dart',
    'mobile\desired_state_app\test\widget_test.dart',
    'mobile\desired_state_app\android\app\src\main\AndroidManifest.xml',
    'mobile\desired_state_app\android\app\src\main\kotlin\com\example\desired_state_app\RecordingService.kt',
    'help\current-state.md',
    'help\codex-handoff.md',
    'help\roadmap.md',
    'help\project-log.md',
    'help\app-development-plan.md',
    'tools\verify_o2ring_protocol_source.ps1'
)
foreach ($relative in $paths) {
    if (-not (Test-Path -LiteralPath (Join-Path $package $relative))) {
        throw "Incomplete package: $relative"
    }
}
foreach ($relative in $paths) {
    $target = Join-Path $repo $relative
    if (Test-Path -LiteralPath $target) {
        $saved = Join-Path $backup $relative
        New-Item -ItemType Directory -Path (Split-Path $saved) -Force | Out-Null
        Copy-Item -LiteralPath $target -Destination $saved -Force
    }
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $package $relative) -Destination $target -Force
}
& (Join-Path $repo 'tools\verify_o2ring_protocol_source.ps1')
Write-Host "Backups: $backup"
