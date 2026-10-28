#requires -Version 7.0
param([switch]$TestFixtures)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$downloads = Join-Path $projectRoot 'build/downloads'
[void][IO.Directory]::CreateDirectory($downloads)
[IO.File]::WriteAllText((Join-Path $projectRoot 'build/.gdignore'), '')
[void][IO.Directory]::CreateDirectory((Join-Path $projectRoot 'native/bin'))

function Assert-FileHash([string]$Path, [string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) {
        throw "Dependency checksum mismatch: $Path"
    }
}

function Get-PinnedFile([string]$Url, [string]$Path, [string]$Hash) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Invoke-WebRequest -Uri $Url -OutFile ($Path + '.download')
        Assert-FileHash ($Path + '.download') $Hash
        Move-Item -LiteralPath ($Path + '.download') -Destination $Path
    }
    Assert-FileHash $Path $Hash
}

$media = Get-Content (Join-Path $projectRoot 'native/third_party/mediapipe/manifest.json') -Raw | ConvertFrom-Json
$library = Join-Path $projectRoot 'native/bin/libmediapipe.dll'
if (-not (Test-Path -LiteralPath $library)) {
    $wheel = Join-Path $downloads 'mediapipe-1.1.1-win_amd64.zip'
    Get-PinnedFile $media.binary_archive.url $wheel $media.binary_archive.sha256
    $zip = [IO.Compression.ZipFile]::OpenRead($wheel)
    try {
        $entry = $zip.GetEntry('mediapipe/tasks/c/libmediapipe.dll')
        if ($null -eq $entry) { throw 'MediaPipe native library is absent from the pinned archive' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $library, $false)
    } finally { $zip.Dispose() }
}
Assert-FileHash $library $media.library_sha256

$seven = Get-Content (Join-Path $projectRoot 'native/third_party/7zip/manifest.json') -Raw | ConvertFrom-Json
$library = Join-Path $projectRoot 'native/bin/7z.dll'
if (-not (Test-Path -LiteralPath $library)) {
    $archive = Join-Path $downloads '7z2605-x64.exe'
    Get-PinnedFile $seven.binary_archive.url $archive $seven.binary_archive.sha256
    & tar.exe -xf $archive -C (Join-Path $projectRoot 'native/bin') 7z.dll
    if ($LASTEXITCODE -ne 0) { throw 'Unable to extract 7z.dll; the installer is never executed' }
}
Assert-FileHash $library $seven.library.sha256

$models = Get-Content (Join-Path $projectRoot 'mocap/models/manifest.json') -Raw | ConvertFrom-Json
foreach ($model in $models.PSObject.Properties) {
    Get-PinnedFile $model.Value.url (Join-Path $projectRoot ('mocap/models/' + $model.Name)) $model.Value.sha256
}
if ($TestFixtures) {
    $fixtureRoot = Join-Path $projectRoot 'mocap/test_data'
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $fixtures = Get-Content (Join-Path $projectRoot 'tests/fixtures/mediapipe.json') -Raw | ConvertFrom-Json
    foreach ($fixture in $fixtures.PSObject.Properties) {
        Get-PinnedFile $fixture.Value.url (Join-Path $fixtureRoot $fixture.Name) $fixture.Value.sha256
    }
}
& (Join-Path $PSScriptRoot 'prepare_native.ps1')
