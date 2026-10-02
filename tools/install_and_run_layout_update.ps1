param([Parameter(Mandatory=$true)][string]$PackageRoot,
      [Parameter(Mandatory=$true)][string]$RepositoryRoot,
      [string]$DeviceId = 'R5CX152HPPN')
$ErrorActionPreference = 'Stop'
if (!(Get-Command flutter -ErrorAction SilentlyContinue)) {
    foreach ($sdkBin in @('F:\1dev\flutter\bin', 'C:\1dev\flutter\bin')) {
        if (Test-Path -LiteralPath (Join-Path $sdkBin 'flutter.bat')) {
            $env:Path = "$sdkBin;$env:Path"
            break
        }
    }
}
Get-Command flutter -ErrorAction Stop | Out-Null
Get-Command dart -ErrorAction Stop | Out-Null
& (Join-Path $PackageRoot 'tools\apply_layout_update.ps1') -PackageRoot $PackageRoot -RepositoryRoot $RepositoryRoot
Set-Location (Join-Path $RepositoryRoot 'mobile\desired_state_app')
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'Dependencies failed. App not started.' }
dart format --output=none --set-exit-if-changed lib test
if ($LASTEXITCODE -ne 0) { throw 'Formatting check failed. App not started.' }
flutter analyze --no-pub
if ($LASTEXITCODE -ne 0) { throw 'Analysis failed. App not started.' }
flutter test --no-pub
if ($LASTEXITCODE -ne 0) { throw 'Tests failed. App not started.' }
flutter build apk --debug --no-pub
if ($LASTEXITCODE -ne 0) { throw 'Build failed. App not started.' }
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (!(Test-Path -LiteralPath $adb)) { throw "ADB missing at $adb. App not started." }
& $adb -s $DeviceId install -r '.\build\app\outputs\flutter-apk\app-debug.apk'
if ($LASTEXITCODE -ne 0) { throw 'Upgrade failed. App not started. Do not uninstall or clear recording storage.' }
flutter run --no-pub -d $DeviceId
if ($LASTEXITCODE -ne 0) { throw 'Launch failed.' }
