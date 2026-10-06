param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$credentialFolder = Join-Path $env:LOCALAPPDATA 'DesiredState'
$destination = Join-Path $credentialFolder 'backend-token.dpapi'
if (Test-Path -LiteralPath $destination) {
    Write-Host 'A protected upload credential is already configured for this Windows login.'
    exit 0
}
$stage = Join-Path $env:TEMP ('desired-state-credential-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stage | Out-Null
# Remove inherited access: only this user and SYSTEM can read the temporary secret.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls $stage /inheritance:r /grant:r "*${identity}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the temporary credential directory.' }
try {
    $tokenFile = Join-Path $stage 'upload-token.txt'
    & scp -P 2222 'valentfx@gator4153.hostgator.com:/home2/valentfx/desired-state-private/config/upload-token.txt' $tokenFile
    if ($LASTEXITCODE -ne 0) { throw 'Credential transfer failed; upload is not configured.' }
    $token = [IO.File]::ReadAllText($tokenFile).Trim()
    if ($token -cnotmatch '^[a-f0-9]{64}$') { throw 'Unexpected upload token format.' }
    $encrypted = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($token), $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    New-Item -ItemType Directory -Path $credentialFolder -Force | Out-Null
    [IO.File]::WriteAllBytes($destination, $encrypted)
    Write-Host "Upload credential protected for this Windows login: $destination"
} finally {
    $token = $null
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
