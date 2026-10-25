#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$MediaPipeLibrary,
    [string]$SevenZipLibrary,
    [string]$ModelsPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$binaryRoot = Join-Path $projectRoot 'native/bin'
[void][IO.Directory]::CreateDirectory($binaryRoot)

function Copy-InputFile([string]$InputPath, [string]$Destination) {
    if (-not $InputPath) { return }
    $source = (Resolve-Path -LiteralPath $InputPath).Path
    if (-not $source.Equals([IO.Path]::GetFullPath($Destination), [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $source -Destination $Destination -Force
    }
}

function Assert-Hash([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required native dependency is missing: $Path" }
    $digest = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $Expected -or $digest -ne $Expected.ToLowerInvariant()) { throw "Pinned dependency checksum mismatch: $Path" }
    return $digest
}

Copy-InputFile $MediaPipeLibrary (Join-Path $binaryRoot 'libmediapipe.dll')
Copy-InputFile $SevenZipLibrary (Join-Path $binaryRoot '7z.dll')
$mediaManifest = Get-Content -LiteralPath (Join-Path $projectRoot 'native/third_party/mediapipe/manifest.json') -Raw | ConvertFrom-Json
$zipManifest = Get-Content -LiteralPath (Join-Path $projectRoot 'native/third_party/7zip/manifest.json') -Raw | ConvertFrom-Json
$modelManifest = Get-Content -LiteralPath (Join-Path $projectRoot 'mocap/models/manifest.json') -Raw | ConvertFrom-Json
$mediaHash = Assert-Hash (Join-Path $binaryRoot 'libmediapipe.dll') $mediaManifest.library_sha256
$zipHash = Assert-Hash (Join-Path $binaryRoot '7z.dll') $zipManifest.library.sha256
$headerCount = 0
foreach ($header in $mediaManifest.header_sha256.PSObject.Properties) {
    [void](Assert-Hash (Join-Path $projectRoot ('native/third_party/mediapipe/include/' + $header.Name)) $header.Value)
    $headerCount++
}
if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'native/third_party/7zip/CPP/7zip/Archive/IArchive.h') -PathType Leaf)) {
    throw 'The pinned 7-Zip source interfaces are missing'
}
$models = [ordered]@{}
foreach ($model in $modelManifest.PSObject.Properties) {
    $target = Join-Path $projectRoot ('mocap/models/' + $model.Name)
    if ($ModelsPath) { Copy-InputFile (Join-Path $ModelsPath $model.Name) $target }
    $models[$model.Name] = Assert-Hash $target $model.Value.sha256
}
foreach ($relative in @('native/third_party/mediapipe/LICENSE', 'native/third_party/7zip/DOC/License.txt', 'native/third_party/7zip/DOC/copying.txt', 'native/third_party/7zip/DOC/unRarLicense.txt', 'native/third_party/7zip/BINARY_LICENSE.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $relative) -PathType Leaf)) { throw "Required third-party license is missing: $relative" }
}
$importsChecked = @()
$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
if ($dumpbin) {
    foreach ($name in @('libmediapipe.dll', '7z.dll', 'mocap_native.dll')) {
        $path = Join-Path $binaryRoot $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $imports = & $dumpbin.Source /dependents $path
        if ($LASTEXITCODE -ne 0 -or ($imports -join "`n") -match '(?im)^\s*python\S*\.dll\s*$') { throw "Native import validation failed: $name" }
        $importsChecked += $name
    }
}
[ordered]@{
    ok = $true
    mediapipe_version = $mediaManifest.version
    mediapipe_sha256 = $mediaHash
    seven_zip_version = $zipManifest.version
    seven_zip_sha256 = $zipHash
    mediapipe_headers = $headerCount
    models = $models
    import_tables_checked = $importsChecked
    native_capture_built = (Test-Path -LiteralPath (Join-Path $binaryRoot 'mocap_native.dll') -PathType Leaf)
} | ConvertTo-Json -Depth 6
