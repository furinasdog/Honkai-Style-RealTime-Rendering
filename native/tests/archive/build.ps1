param([string]$Archive = '', [switch]$BuildOnly)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$buildDirectory = Join-Path $projectRoot 'build/archive_tests'
$compiler = (Get-Command cl.exe -ErrorAction Stop).Source
$vcRoot = $compiler -replace '\\Tools\\MSVC\\.*$', ''
$vcvars = Join-Path $vcRoot 'Auxiliary/Build/vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) { throw 'Visual C++ x64 developer environment was not found' }
$null = $compiler -match 'MSVC\\(\d+\.\d+)\.'
$compilerVersion = $Matches[1]
$ninja = Join-Path (Split-Path -Parent $vcRoot) 'Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe'
if (-not (Test-Path -LiteralPath $ninja)) { throw 'Visual Studio native Ninja executable was not found' }
$configure = 'call "' + $vcvars + '" -vcvars_ver=' + $compilerVersion + ' >nul && cmake -S "' + $PSScriptRoot + '" -B "' + $buildDirectory + '" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER="' + $compiler + '" -DCMAKE_MAKE_PROGRAM="' + $ninja + '" && cmake --build "' + $buildDirectory + '"'
& cmd.exe /d /c $configure
if ($LASTEXITCODE -ne 0) { throw 'Archive service compilation failed' }
if (-not $BuildOnly) {
    $testArguments = @((Join-Path $projectRoot 'native/bin/7z.dll'), (Join-Path $projectRoot ('outputs/archive_cpp_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))))
    if ($Archive) { $testArguments += (Resolve-Path -LiteralPath $Archive).Path }
    & (Join-Path $buildDirectory 'archive_service_tests.exe') @testArguments
    if ($LASTEXITCODE -ne 0) { throw 'Archive service tests failed' }
}
