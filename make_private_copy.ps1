$ErrorActionPreference = 'Stop'

$source = [System.IO.Path]::GetFullPath($PSScriptRoot)
$destination = Join-Path $env:USERPROFILE 'LuminoPrivateSource'

if ([string]::Equals(
  $source.TrimEnd('\'),
  $destination.TrimEnd('\'),
  [System.StringComparison]::OrdinalIgnoreCase
)) {
  throw 'This is already the private working copy. Edit and build it directly.'
}

if ($destination.StartsWith(
  $source.TrimEnd('\') + '\',
  [System.StringComparison]::OrdinalIgnoreCase
)) {
  throw 'The private copy cannot be created inside the repository.'
}

if (-not (Test-Path -LiteralPath (Join-Path $source 'pubspec.yaml'))) {
  throw "This script must stay in the Lumino project folder: $source"
}

Write-Host "Source:      $source"
Write-Host "Private copy: $destination"
Write-Host 'Copying app source, assets and build scripts (excluding server code, Git history and generated builds)...'

New-Item -ItemType Directory -Path $destination -Force | Out-Null
$excludedDirectories = @(
  (Join-Path $source '.git'),
  (Join-Path $source '.dart_tool'),
  (Join-Path $source '.idea'),
  (Join-Path $source 'build'),
  (Join-Path $source 'Output'),
  (Join-Path $source 'release_output'),
  (Join-Path $source 'server'),
  (Join-Path $source 'android\.gradle'),
  (Join-Path $source 'android\app\build'),
  (Join-Path $source 'linux\build'),
  (Join-Path $source 'windows\flutter\ephemeral')
)

& robocopy.exe $source $destination /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /XD $excludedDirectories /XF '*.iml' '.env' '.env.*' '*.pem' '*.key' '*.pfx' '*.p12' '*.keystore' '*.jks'
if ($LASTEXITCODE -ge 8) {
  throw "Source copy failed with Robocopy exit code $LASTEXITCODE."
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$userSid = $identity.User.Value

Write-Host ''
Write-Host 'Restricting this copy to your Windows account, SYSTEM and local administrators...'
& icacls.exe $destination /inheritance:r /T /C
if ($LASTEXITCODE -ne 0) {
  throw 'Could not remove inherited permissions from the private copy.'
}

$explicitPermissions = @(
  "*${userSid}:(F)"
  '*S-1-5-18:(F)'
  '*S-1-5-32-544:(F)'
)
& icacls.exe $destination /grant:r $explicitPermissions /T /C
if ($LASTEXITCODE -ne 0) {
  throw 'Could not apply private-copy permissions.'
}
$inheritablePermissions = @(
  "*${userSid}:(OI)(CI)(F)"
  '*S-1-5-18:(OI)(CI)(F)'
  '*S-1-5-32-544:(OI)(CI)(F)'
)
& icacls.exe $destination /grant $inheritablePermissions /T /C
if ($LASTEXITCODE -ne 0) {
  throw 'Could not apply permissions for new files in the private copy.'
}

$info = @(
  'Lumino private working copy'
  ''
  "Source copied from: $source"
  "Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  ''
  'This folder is editable and can be built with Flutter.'
  'Git history, generated build files, and the separate server folder were not copied.'
  ''
  'The Windows permissions limit access to this Windows account.'
  'Local administrators can still take ownership. Do not share your Windows account.'
)
[System.IO.File]::WriteAllLines(
  (Join-Path $destination 'PRIVATE_COPY_INFO.txt'),
  $info,
  [System.Text.UTF8Encoding]::new($false)
)

Write-Host ''
Write-Host "Private copy ready: $destination" -ForegroundColor Green
Write-Host 'Other standard Windows accounts should receive Access Denied.'
Start-Process explorer.exe -ArgumentList "`"$destination`""
