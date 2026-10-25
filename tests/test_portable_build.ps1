#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../tools/build_portable.ps1')
$fixture = Join-Path $script:ProjectRoot ('outputs/portable_build_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$plain = Join-Path $fixture 'plain'
[void][IO.Directory]::CreateDirectory($plain)
Write-Utf8File (Join-Path $plain 'main.gd') 'extends Node'
Assert-NoCharacterAssets $plain

function Assert-Rejected([scriptblock]$Action) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'The packaging guard accepted forbidden content' }
}

$character = Join-Path $fixture 'character'
[void][IO.Directory]::CreateDirectory($character)
Write-Utf8File (Join-Path $character 'model.pmx') 'fixture'
Assert-Rejected { Assert-NoCharacterAssets $character }
$reference = Join-Path $fixture 'reference'
[void][IO.Directory]::CreateDirectory($reference)
Write-Utf8File (Join-Path $reference 'actor.gd') 'var model = load("res://assets/march/model.glb")'
Assert-Rejected { Assert-NoCharacterAssets $reference }
$pythonReference = Join-Path $fixture 'python_reference'
[void][IO.Directory]::CreateDirectory($pythonReference)
Write-Utf8File (Join-Path $pythonReference 'runtime.gd') 'var helper = "res://.venv/Scripts/python.exe"'
Assert-Rejected { Assert-NoCharacterAssets $pythonReference }
$legacy = Join-Path $fixture 'legacy'
[void][IO.Directory]::CreateDirectory((Join-Path $legacy 'runtime/capture'))
Write-Utf8File (Join-Path $legacy 'runtime/capture/MocapCapture.exe') 'fixture'
Assert-Rejected { Assert-NativePackage $legacy }
$worker = Join-Path $fixture 'worker'
[void][IO.Directory]::CreateDirectory((Join-Path $worker 'runtime/importer'))
Write-Utf8File (Join-Path $worker 'runtime/importer/import_pmx_blender.py') 'fixture'
Assert-NativePackage $worker
Write-Utf8File (Join-Path $worker 'runtime/importer/model_import.py') 'fixture'
Assert-Rejected { Assert-NativePackage $worker }
$helper = Join-Path $fixture 'log helper.ps1'
Write-Utf8File $helper "param([string]`$Value)`nWrite-Output ('VALUE=' + `$Value)`n"
$shell = (Get-Process -Id $PID).Path
$text = Invoke-LoggedProcess $shell @('-NoProfile', '-File', $helper, '测试 参数') (Join-Path $fixture 'native_process.log')
if ($text -notmatch 'VALUE=测试 参数') { throw 'Native argument quoting or output capture failed' }

$savedProjectRoot = $script:ProjectRoot
$savedBuildRoot = $script:BuildRoot
$savedDistributionRoot = $script:DistributionRoot
try {
	$script:ProjectRoot = Join-Path $fixture 'archive'
	$script:BuildRoot = Join-Path $script:ProjectRoot 'build'
	$script:DistributionRoot = Join-Path $script:ProjectRoot 'MotionCapture'
	[void][IO.Directory]::CreateDirectory($script:BuildRoot)
	[void][IO.Directory]::CreateDirectory($script:DistributionRoot)
	[void][IO.Directory]::CreateDirectory((Join-Path $script:ProjectRoot 'dist'))
	Write-Utf8File (Join-Path $script:DistributionRoot '说明.txt') 'portable checksum fixture'
	$result = New-DistributionArchive
	if (-not (Test-Path -LiteralPath $result.archive) -or $result.files -ne 2) { throw 'ZIP manifest verification did not finish' }
}
finally {
	$script:ProjectRoot = $savedProjectRoot
	$script:BuildRoot = $savedBuildRoot
	$script:DistributionRoot = $savedDistributionRoot
}
Write-Output 'PORTABLE_BUILD_PASS stage filtering, native argument quoting and ZIP SHA256 verification'
