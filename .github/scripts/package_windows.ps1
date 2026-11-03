# Builds the Windows release and zips it with the extension host:
# build\windows\JHenTai_<version>_Windows.zip. Build Check and Build & Release
# both run this, so that a test package holds what a release holds.
param([Parameter(Mandatory = $true)][string]$Version)
$ErrorActionPreference = 'Stop'

flutter build windows -t lib/src/main.dart --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$DestDir = "build\windows\JHenTai_$Version"
$SrcDir = "build\windows\x64\runner\Release"
New-Item -Path $DestDir -ItemType Directory | Out-Null
Copy-Item $SrcDir\* -Recurse $DestDir
Copy-Item -Filter *.dll -Path windows\* -Destination $DestDir -Force
bash ext_host/desktop/package.sh "$DestDir"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$Zip = "build\windows\JHenTai_${Version}_Windows.zip"
Compress-Archive $DestDir $Zip

# The app starts the extension host from exthost\ next to it
# (lib/src/network/tachi/tachi_host.dart).
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Zip))
$Entries = $Archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }
$Archive.Dispose()
foreach ($Wanted in @("JHenTai_$Version/exthost/exthost.jar", "JHenTai_$Version/exthost/jre/bin/java.exe")) {
  if ($Entries -notcontains $Wanted) {
    throw "$Wanted is missing from $Zip"
  }
}
