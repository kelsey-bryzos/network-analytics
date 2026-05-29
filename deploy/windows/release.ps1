# Optics Windows release script (Release Plan §6.3–§6.8).
#
# Usage (on the Windows build machine, PowerShell):
#   $env:CERT_THUMBPRINT="aabbcc..."     # Bryzos LLC code-signing cert
#   .\deploy\windows\release.ps1 -Version 1.0.0
#
# Prereqs:
#   - Windows 10/11 build machine.
#   - Visual Studio 2022 with Desktop development with C++ workload.
#   - Flutter for Windows.
#   - Code-signing cert (OV or EV) installed in the local cert store, OR
#     present on a YubiKey/SafeNet hardware token with PIN cached.
#   - signtool.exe on PATH (ships with Windows 10 SDK).
#
# Outputs:
#   build/windows/release/Optics-<Version>.msix    (signed)
#   build/windows/release/Optics.appinstaller      (updated manifest)

param(
  [Parameter(Mandatory=$true)][string]$Version
)

$ErrorActionPreference = "Stop"

Set-Location "$PSScriptRoot\..\.."   # project root: program\flutter_app

Write-Host "▶︎ Building Windows release…"
flutter build windows --release

Write-Host "▶︎ Creating MSIX…"
flutter pub run msix:create --version $Version

$msix = "build\windows\x64\runner\Release\Optics.msix"
if (-Not (Test-Path $msix) -and (Test-Path "build\windows\x64\runner\Release\optics.msix")) {
  # Tolerate the pre-rebrand lowercase name during the cutover window.
  $msix = "build\windows\x64\runner\Release\optics.msix"
}
if (-Not (Test-Path $msix)) {
  throw "MSIX not produced at $msix"
}

$OutDir = "build\windows\release"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$signedMsix = "$OutDir\Optics-$Version.msix"
Copy-Item $msix $signedMsix -Force

if (-Not $env:CERT_THUMBPRINT) {
  throw "CERT_THUMBPRINT env var not set. Find with: Get-ChildItem Cert:\CurrentUser\My"
}

Write-Host "▶︎ Signing MSIX with cert $env:CERT_THUMBPRINT…"
signtool sign /fd SHA256 /sha1 $env:CERT_THUMBPRINT `
  /tr http://timestamp.digicert.com /td SHA256 `
  $signedMsix

Write-Host "▶︎ Verifying signature…"
signtool verify /pa /v $signedMsix

Write-Host "▶︎ Updating App Installer manifest…"
$appinstaller = "deploy\windows\Optics.appinstaller"
$content = Get-Content $appinstaller -Raw
$content = $content -replace 'Version="[\d\.]+"', "Version=`"$Version.0`""
$content = $content -replace 'Optics-[\d\.]+\.msix', "Optics-$Version.msix"
Set-Content -Path "$OutDir\Optics.appinstaller" -Value $content

Write-Host ""
Write-Host "✅ Done. Outputs in $OutDir\"
Write-Host "   1. Upload $signedMsix to the update host."
Write-Host "   2. Upload $OutDir\Optics.appinstaller (overwrite the existing one)."
Write-Host "   3. End-users running Optics will get the update on next launch."
