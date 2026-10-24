param(
  [string]$Version
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pubspecPath = Join-Path $root 'pubspec.yaml'
$issPath = Join-Path $root 'lumino.iss'

function Stop-WithMessage([string]$Message) {
  Write-Host "ERROR: $Message" -ForegroundColor Red
  exit 1
}

if (-not (Test-Path -LiteralPath $pubspecPath)) {
  Stop-WithMessage 'pubspec.yaml was not found.'
}
if (-not (Test-Path -LiteralPath $issPath)) {
  Stop-WithMessage 'lumino.iss was not found.'
}

$pubspec = [System.IO.File]::ReadAllText($pubspecPath)
$versionMatch = [regex]::Match(
  $pubspec,
  '(?m)^version:[ \t]*(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?[ \t]*\r?$'
)
if (-not $versionMatch.Success) {
  Stop-WithMessage 'Could not read a numeric version from pubspec.yaml.'
}

$buildNumber = if ($versionMatch.Groups[4].Success) {
  $versionMatch.Groups[4].Value
} else {
  '1'
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $major = [int]$versionMatch.Groups[1].Value
  $minor = [int]$versionMatch.Groups[2].Value
  $patch = [int]$versionMatch.Groups[3].Value + 1
  $Version = "$major.$minor.$patch"
}
$Version = $Version.Trim()
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  Stop-WithMessage "Version '$Version' is invalid. Use the format 0.3.3."
}

$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
if ($flutterCommand) {
  $flutter = $flutterCommand.Source
} else {
  $flutter = 'C:\flutter\bin\flutter.bat'
}
if (-not (Test-Path -LiteralPath $flutter)) {
  Stop-WithMessage 'Flutter was not found. Add flutter to PATH or install it at C:\flutter.'
}

$compilerCandidates = @(
  (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
  (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
  (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
  (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\ISCC.exe'),
  (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
$iscc = $compilerCandidates | Select-Object -First 1
if (-not $iscc) {
  Stop-WithMessage 'Inno Setup Compiler (ISCC.exe) was not found. Install Inno Setup 6 or 7 first.'
}

$iss = [System.IO.File]::ReadAllText($issPath).TrimStart([char]0xFEFF)
$issVersionPattern = '(?m)^#define MyAppVersion "[^"]+"\r?$'
if ([regex]::Matches($iss, $issVersionPattern).Count -ne 1) {
  Stop-WithMessage 'lumino.iss must contain exactly one #define MyAppVersion line.'
}

$newPackageVersion = "$Version+$buildNumber"
$newPubspec = [regex]::new(
  '(?m)^version:[ \t]*\d+\.\d+\.\d+(?:\+\d+)?[ \t]*\r?$'
).Replace($pubspec, "version: $newPackageVersion", 1)
if (-not [regex]::IsMatch(
  $newPubspec,
  "(?m)^version:[ \t]*$([regex]::Escape($newPackageVersion))[ \t]*\r?$"
)) {
  Stop-WithMessage 'Could not update the version in pubspec.yaml.'
}
$newIss = [regex]::new($issVersionPattern).Replace(
  $iss,
  "#define MyAppVersion `"$Version`"",
  1
)

Write-Host ""
Write-Host "Setting app version to $newPackageVersion ..."
[System.IO.File]::WriteAllText(
  $pubspecPath,
  $newPubspec,
  [System.Text.UTF8Encoding]::new($false)
)
[System.IO.File]::WriteAllText(
  $issPath,
  $newIss,
  [System.Text.UTF8Encoding]::new($true)
)

Push-Location $root
try {
  Write-Host ""
  Write-Host 'Building Windows Debug ...' -ForegroundColor Cyan
  & $flutter build windows --debug
  if ($LASTEXITCODE -ne 0) {
    Stop-WithMessage "Flutter Debug build failed with exit code $LASTEXITCODE."
  }

  Write-Host ""
  Write-Host 'Building Windows Release ...' -ForegroundColor Cyan
  & $flutter build windows --release
  if ($LASTEXITCODE -ne 0) {
    Stop-WithMessage "Flutter Release build failed with exit code $LASTEXITCODE."
  }
} finally {
  Pop-Location
}

$debugExe = Join-Path $root 'build\windows\x64\runner\Debug\lumino.exe'
$releaseExe = Join-Path $root 'build\windows\x64\runner\Release\lumino.exe'
foreach ($exe in @($debugExe, $releaseExe)) {
  if (-not (Test-Path -LiteralPath $exe)) {
    Stop-WithMessage "Build output was not found: $exe"
  }
}

$outputDirectory = Join-Path $root "release_output\Lumino-$Version"
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

Write-Host ""
Write-Host 'Building the Inno Setup installer ...' -ForegroundColor Cyan
& $iscc "/O$outputDirectory" '/FLumino' $issPath
if ($LASTEXITCODE -ne 0) {
  Stop-WithMessage "Inno Setup compilation failed with exit code $LASTEXITCODE."
}
$installer = Join-Path $outputDirectory 'Lumino.exe'
if (-not (Test-Path -LiteralPath $installer)) {
  Stop-WithMessage "Installer was not created at $installer"
}

function Get-ExeVersion([string]$Path) {
  $item = Get-Item -LiteralPath $Path
  $info = $item.VersionInfo
  [pscustomobject]@{
    Path           = $Path
    FileVersion    = $info.FileVersion.Trim()
    ProductVersion = $info.ProductVersion.Trim()
    SizeBytes      = $item.Length
  }
}

$debugVersion = Get-ExeVersion $debugExe
$releaseVersion = Get-ExeVersion $releaseExe
$installerVersion = Get-ExeVersion $installer

$buildConsistency = if (
  $debugVersion.ProductVersion -eq $newPackageVersion -and
  $releaseVersion.ProductVersion -eq $newPackageVersion -and
  $installerVersion.ProductVersion -eq $Version
) {
  'OK: Debug, Release, and installer versions match the version files.'
} else {
  'MISMATCH: Review the versions listed above before publishing.'
}

$githubTitle = 'NOT AVAILABLE'
$githubTag = 'NOT AVAILABLE'
$githubAsset = 'NOT FOUND'
$githubAssetUrl = ''
$githubInstallerVersion = 'NOT CHECKED'
$githubPublished = 'NOT AVAILABLE'
$githubError = ''
$comparison = 'Could not compare versions.'
$githubAssetComparison = 'Could not compare versions.'
$temporaryDownload = Join-Path ([System.IO.Path]::GetTempPath()) (
  'Lumino-GitHub-' + [guid]::NewGuid().ToString('N') + '.exe'
)
try {
  $headers = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'Lumino-Version-Checker'
  }
  $releases = Invoke-RestMethod `
    -Uri 'https://api.github.com/repos/theLuni/lumino/releases?per_page=100' `
    -Headers $headers `
    -TimeoutSec 30
  $publishedRelease = $releases |
    Where-Object { -not $_.draft } |
    Sort-Object { [datetime]$_.published_at } -Descending |
    Select-Object -First 1

  if ($publishedRelease) {
    $githubTitle = $publishedRelease.name
    $githubTag = $publishedRelease.tag_name
    $githubPublished = $publishedRelease.published_at
    $asset = $publishedRelease.assets |
      Where-Object { $_.name -ieq 'Lumino.exe' } |
      Select-Object -First 1
    if ($asset) {
      $githubAsset = "$($asset.name) ($($asset.size) bytes)"
      $githubAssetUrl = $asset.browser_download_url
      Invoke-WebRequest `
        -Uri $asset.browser_download_url `
        -OutFile $temporaryDownload `
        -Headers @{ 'User-Agent' = 'Lumino-Version-Checker' } `
        -TimeoutSec 180
      $githubInstallerVersion = (Get-Item -LiteralPath $temporaryDownload).VersionInfo.ProductVersion.Trim()
      if ($githubInstallerVersion -match '^\s*(\d+\.\d+\.\d+)') {
        $remoteInstallerVersion = [version]$Matches[1]
        $localVersion = [version]$Version
        if ($remoteInstallerVersion -lt $localVersion) {
          $githubAssetComparison = 'Uploaded installer metadata is older than this local build.'
        } elseif ($remoteInstallerVersion -eq $localVersion) {
          $githubAssetComparison = 'Uploaded installer metadata matches this local build.'
        } else {
          $githubAssetComparison = 'Uploaded installer metadata is newer than this local build.'
        }
      }
    }
    $remoteVersionText = [string]$publishedRelease.name
    if ($remoteVersionText -match '^\s*v?(\d+\.\d+\.\d+)') {
      $remoteVersion = [version]$Matches[1]
      $localVersion = [version]$Version
      if ($remoteVersion -lt $localVersion) {
        $comparison = 'GitHub release is older than this local build. Upload the new installer to GitHub.'
      } elseif ($remoteVersion -eq $localVersion) {
        $comparison = 'GitHub release title matches this local build version.'
      } else {
        $comparison = 'GitHub release is newer than this local build.'
      }
    }
  } else {
    $githubError = 'No published GitHub releases were found.'
  }
} catch {
  $githubError = $_.Exception.Message
} finally {
  if (Test-Path -LiteralPath $temporaryDownload) {
    Remove-Item -LiteralPath $temporaryDownload -Force
  }
}

$lines = @(
  'LUMINO WINDOWS RELEASE VERSION REPORT'
  "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  ''
  'LOCAL VERSION FILES'
  "pubspec.yaml: $newPackageVersion"
  "lumino.iss: $Version"
  ''
  'BUILT EXECUTABLES'
  "Debug FileVersion: $($debugVersion.FileVersion)"
  "Debug ProductVersion: $($debugVersion.ProductVersion)"
  "Release FileVersion: $($releaseVersion.FileVersion)"
  "Release ProductVersion: $($releaseVersion.ProductVersion)"
  "Local build consistency: $buildConsistency"
  ''
  'LOCAL INSTALLER'
  "Installer: $installer"
  "Installer FileVersion: $($installerVersion.FileVersion)"
  "Installer ProductVersion: $($installerVersion.ProductVersion)"
  "Installer size: $($installerVersion.SizeBytes) bytes"
  ''
  'LATEST PUBLISHED GITHUB RELEASE'
  "Release title/version: $githubTitle"
  "Release tag: $githubTag"
  "Published: $githubPublished"
  "Asset: $githubAsset"
  "Asset URL: $githubAssetUrl"
  "Downloaded asset ProductVersion: $githubInstallerVersion"
  "Uploaded installer comparison: $githubAssetComparison"
  "Version comparison: $comparison"
  'Note: this script builds the installer but does not upload it to GitHub.'
)
if ($githubError) {
  $lines += "GitHub check error: $githubError"
}

$reportPath = Join-Path $outputDirectory 'version.txt'
[System.IO.File]::WriteAllLines(
  $reportPath,
  $lines,
  [System.Text.UTF8Encoding]::new($true)
)

Write-Host ""
Write-Host "Installer and report created:" -ForegroundColor Green
Write-Host $outputDirectory
Write-Host ""
Get-Content -LiteralPath $reportPath
Start-Process explorer.exe -ArgumentList "`"$outputDirectory`""
