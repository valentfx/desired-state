$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$servicePath = Join-Path $repoRoot 'mobile\desired_state_app\lib\o2_ring_service.dart'
$screenPath = Join-Path $repoRoot 'mobile\desired_state_app\lib\o2_ring_diagnostics_screen.dart'

if (-not (Test-Path -LiteralPath $servicePath)) {
    throw "Flutter source not found: $servicePath"
}
if (-not (Test-Path -LiteralPath $screenPath)) {
    throw "Diagnostics screen not found: $screenPath"
}

$service = Get-Content -LiteralPath $servicePath -Raw
$screen = Get-Content -LiteralPath $screenPath -Raw
$requiredServiceMarkers = @(
    'O2RING-RECORDING-20261001',
    'e8fb0001-a14b-98f9-831b-4e2941d01248',
    'buildOxyIiLiveSamplesRequest',
    'readSensorsCommand',
    'decodeLegacySensorFrame',
    'ViatomFrameAssembler'
)
foreach ($marker in $requiredServiceMarkers) {
    if (-not $service.Contains($marker)) {
        throw "Expected O2Ring driver marker is missing: $marker`nSource: $servicePath"
    }
}
if (-not $screen.Contains('O2RingService.diagnosticsBuildId')) {
    throw "The diagnostics screen does not display the O2Ring driver build ID: $screenPath"
}

Write-Host "Verified recording O2Ring source at: $repoRoot" -ForegroundColor Green
Write-Host 'Expected legacy + OxyII commands and visible driver build ID are present.'
