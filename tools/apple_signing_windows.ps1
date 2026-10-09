[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('CreateCsr','ExportP12')][string]$Action,
    [string]$Directory = (Join-Path $env:LOCALAPPDATA 'DesiredStateAppleSigning'),
    [string]$CertificatePath
)
$ErrorActionPreference = 'Stop'
$openssl = Get-Command openssl -ErrorAction SilentlyContinue
if ($openssl) { $opensslPath = $openssl.Source }
else {
    $git = Get-Command git -ErrorAction Stop
    $candidate = Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'usr\bin\openssl.exe'
    if (!(Test-Path -LiteralPath $candidate)) {
        throw 'OpenSSL was not found. Install Git for Windows with its bundled OpenSSL or specify it on PATH.'
    }
    $opensslPath = $candidate
}
New-Item -ItemType Directory -Force -Path $Directory | Out-Null
$key = Join-Path $Directory 'distribution-private.key'
$csr = Join-Path $Directory 'distribution.csr'
$p12 = Join-Path $Directory 'distribution.p12'
if ($Action -eq 'CreateCsr') {
    if (Test-Path -LiteralPath $key) { throw 'A signing key already exists. Preserve it; choose another directory for a new key.' }
    & $opensslPath req -new -newkey rsa:2048 -nodes -keyout $key -out $csr -subj '/CN=Desired State Apple Distribution'
    if ($LASTEXITCODE -ne 0) { throw 'CSR generation failed.' }
    Write-Host "Upload this CSR to Apple Certificates: $csr"
    Write-Host 'Keep the private key locally. Do not put it in the repository or chat.'
} else {
    if (!(Test-Path -LiteralPath $key)) { throw 'Create the CSR/private key first.' }
    if (!$CertificatePath -or !(Test-Path -LiteralPath $CertificatePath)) { throw 'Provide the Apple-issued distribution.cer path.' }
    if (Test-Path -LiteralPath $p12) { throw 'An exported P12 already exists. Preserve it or use another directory.' }
    $pem = Join-Path $Directory 'distribution-certificate.pem'
    & $opensslPath x509 -inform DER -in $CertificatePath -out $pem
    if ($LASTEXITCODE -ne 0) { throw 'Certificate conversion failed.' }
    $legacy = @()
    $version = & $opensslPath version
    if ($version -match '^OpenSSL 3\.') { $legacy = @('-legacy') }
    & $opensslPath pkcs12 @legacy -export -inkey $key -in $pem -out $p12 -name 'Apple Distribution'
    if ($LASTEXITCODE -ne 0) { throw 'P12 export failed.' }
    Write-Host "P12 exported: $p12. Store its chosen password in the GitHub certificate-password secret."
}
