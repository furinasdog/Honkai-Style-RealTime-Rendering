#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$GodotExecutable,
    [switch]$RuntimeOnly,
    [switch]$ExportOnly,
    [switch]$StageOnly
)

$ErrorActionPreference = 'Stop'
$script:ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:BuildRoot = Join-Path $script:ProjectRoot 'build'
$script:DistributionRoot = Join-Path $script:ProjectRoot 'dist/HonkaiRender'
$script:NativeLibraries = @('mocap_native.dll', 'libmediapipe.dll', '7z.dll')
$script:ModelFiles = @('face_landmarker.task', 'hand_landmarker.task', 'pose_landmarker_lite.task', 'manifest.json')

function Write-Utf8File([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Assert-WorkspacePath([string]$Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    $prefix = $script:ProjectRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Generated path is outside this workspace: $absolute"
    }
    return $absolute
}

function Copy-FilteredTree([string]$Source, [string]$Destination) {
    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\', '/')
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    if ($sourceRoot.Equals($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
        $relative = $file.FullName.Substring($sourceRoot.Length + 1)
        if ($relative -match '(^|[\\/])(\.git|\.godot|__pycache__|qa|motions)([\\/]|$)' -or
            $file.Name -eq '.gdignore' -or $file.Extension -in @('.pdb', '.lib', '.pyc', '.log')) { continue }
        $target = Join-Path $destinationRoot $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

function Move-LegacyRuntime {
    $legacy = @('runtime/blender', 'runtime/mmd_tools', 'runtime/importer', 'runtime/capture', 'runtime/model_import', 'licenses/godot-cpp_LICENSE.md')
    $backup = Assert-WorkspacePath (Join-Path $script:BuildRoot ('retired_conversion_runtime_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')))
    foreach ($relative in $legacy) {
        $target = Join-Path $script:DistributionRoot $relative
        if (Test-Path -LiteralPath $target) {
            $target = Assert-WorkspacePath $target
            [void][IO.Directory]::CreateDirectory($backup)
            $name = $relative.Replace('/', '_')
            Move-Item -LiteralPath $target -Destination (Join-Path $backup $name)
        }
    }
}

function Assert-NoCharacterAssets([string]$Path) {
    foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File -Force) {
        $relative = $file.FullName.Substring([IO.Path]::GetFullPath($Path).TrimEnd('\', '/').Length + 1).Replace('\', '/')
        if ($file.Extension.ToLowerInvariant() -in @('.pmx', '.pmd', '.vmd', '.vpd', '.blend', '.fbx', '.glb', '.gltf') -or
            $relative -match '(^|/)assets/march(/|$)') {
            throw "Character/model content is forbidden in the source/export stage: $relative"
        }
        if ($file.Extension -in @('.gd', '.tscn', '.tres') -and
            (Get-Content -LiteralPath $file.FullName -Raw) -match 'res://assets/march') {
            throw "Remove the built-in character dependency before export: $relative"
        }
        if ($file.Extension -in @('.gd', '.tscn', '.tres') -and
            (Get-Content -LiteralPath $file.FullName -Raw) -match '\.venv[\\/]|mocap/bridge\.py|mocap/model_import\.py|MocapCapture\.exe|ModelImporter\.exe|runtime/(blender|mmd_tools|importer)/|import_pmx_blender\.py|scripts/runtime_paths\.gd') {
            throw "Remove the retired conversion/helper dependency before export: $relative"
        }
    }
}

function Assert-NativePackage([string]$Path) {
    $base = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    foreach ($file in Get-ChildItem -LiteralPath $base -Recurse -File -Force) {
        $relative = $file.FullName.Substring($base.Length + 1).Replace('\', '/')
        if ($file.Extension.ToLowerInvariant() -in @('.pmx', '.pmd', '.vmd', '.vpd', '.blend', '.fbx', '.glb', '.gltf') -or
            $relative -match '(^|/)(\.venv|outputs|model_cache|backups|__pycache__|tests)(/|$)' -or
            $relative -match '^runtime/(blender|mmd_tools|importer|capture|model_import)/' -or
            $file.Name -match '^(python.*\.(exe|dll)|blender.*\.exe|MocapCapture\.exe|ModelImporter\.exe)$' -or
            $file.Extension -eq '.py') {
            throw "Forbidden content in the native distribution: $relative"
        }
    }
}

function New-ExportStage {
    & (Join-Path $script:ProjectRoot 'tools/prepare_native.ps1') | Out-Null
    $stage = Join-Path $script:BuildRoot ('export_source_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    [void][IO.Directory]::CreateDirectory($stage)
    foreach ($folder in @('scripts', 'scenes', 'shaders')) {
        Copy-FilteredTree (Join-Path $script:ProjectRoot $folder) (Join-Path $stage $folder)
    }
    foreach ($folder in @('runtime', 'render')) {
        Copy-FilteredTree (Join-Path $script:ProjectRoot "plugins/honkai_mmd/$folder") (Join-Path $stage "plugins/honkai_mmd/$folder")
    }
    $native = Join-Path $stage 'native'
    [void][IO.Directory]::CreateDirectory((Join-Path $native 'bin'))
    Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'native/mocap.gdextension') -Destination $native
    foreach ($name in $script:NativeLibraries) {
        $source = Join-Path $script:ProjectRoot "native/bin/$name"
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Native build is incomplete: $name" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $native "bin/$name")
    }
    $models = Join-Path $stage 'mocap/models'
    [void][IO.Directory]::CreateDirectory($models)
    $modelManifest = Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'mocap/models/manifest.json') -Raw | ConvertFrom-Json
    foreach ($name in $script:ModelFiles) {
        $source = Join-Path $script:ProjectRoot "mocap/models/$name"
        if ($name -ne 'manifest.json' -and (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $modelManifest.$name.sha256) {
            throw "MediaPipe model checksum mismatch: $name"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $models $name)
    }
    Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'icon.svg') -Destination $stage
    $project = Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'project.godot') -Raw
    $project = [regex]::Replace($project, '(?m)^_mcp_game_helper=.*\r?\n', '')
    $project = [regex]::Replace($project, '(?ms)^\[editor_plugins\]\s*\r?\n.*?(?=^\[|\z)', '')
    Write-Utf8File (Join-Path $stage 'project.godot') $project
    $preset = @'
[preset.0]
name="Windows Desktop"
platform="Windows Desktop"
runnable=true
export_filter="all_resources"
include_filter="*.json,*.task"
exclude_filter=""
export_path=""
script_export_mode=2

[preset.0.options]
custom_template/debug=""
custom_template/release=""
debug/export_console_wrapper=0
binary_format/embed_pck=true
binary_format/architecture="x86_64"
codesign/enable=false
application/modify_resources=true
application/product_name="Honkai-style real-time rendering"
application/file_description="Local native MediaPipe MMD motion capture"
'@
    Write-Utf8File (Join-Path $stage 'export_presets.cfg') $preset
    Assert-NoCharacterAssets $stage
    return $stage
}

function Get-IsolatedEditor([string]$Executable) {
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw 'GodotExecutable must select the editor executable' }
    $source = (Resolve-Path -LiteralPath $Executable).Path
    $versionOutput = Invoke-LoggedProcess $source @('--version') (Join-Path $script:BuildRoot 'godot_version.log')
    if ($versionOutput -notmatch '(\d+\.\d+\.\d+\.(?:stable|rc\d+|beta\d+|dev\d+))') { throw 'Cannot determine Godot template version' }
    $version = $Matches[1]
    $editorFolder = [IO.Path]::GetDirectoryName($source)
    $candidates = @((Join-Path $editorFolder "editor_data/export_templates/$version"))
    if ($env:APPDATA) { $candidates += (Join-Path $env:APPDATA "Godot/export_templates/$version") }
    $templateFolder = $candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'windows_release_x86_64.exe') -PathType Leaf } | Select-Object -First 1
    if (-not $templateFolder) { throw "Install the matching Windows x64 export template: $version" }
    $destination = Join-Path $script:BuildRoot 'editor_runtime'
    [void][IO.Directory]::CreateDirectory($destination)
    $editor = Join-Path $destination ([IO.Path]::GetFileName($source))
    if (-not $source.Equals($editor, [StringComparison]::OrdinalIgnoreCase) -and
        (-not (Test-Path -LiteralPath $editor) -or (Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $editor).Hash)) {
        Copy-Item -LiteralPath $source -Destination $editor -Force
    }
    foreach ($name in @('steam_api64.dll')) {
        $extra = Join-Path $editorFolder $name
        if (Test-Path -LiteralPath $extra -PathType Leaf) { Copy-Item -LiteralPath $extra -Destination (Join-Path $destination $name) -Force }
    }
    Write-Utf8File (Join-Path $destination '_sc_') ''
    $localTemplates = Join-Path $destination "editor_data/export_templates/$version"
    [void][IO.Directory]::CreateDirectory($localTemplates)
    $template = Join-Path $templateFolder 'windows_release_x86_64.exe'
    $localTemplate = Join-Path $localTemplates 'windows_release_x86_64.exe'
    if (-not $template.Equals($localTemplate, [StringComparison]::OrdinalIgnoreCase)) { Copy-Item -LiteralPath $template -Destination $localTemplate -Force }
    return $editor
}

function Invoke-LoggedProcess([string]$Executable, [string[]]$Arguments, [string]$LogPath) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(300000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Native tool timed out: $Executable"
        }
        $text = $output.GetAwaiter().GetResult() + $errors.GetAwaiter().GetResult()
        Write-Utf8File $LogPath $text
        if ($process.ExitCode -ne 0) { throw "Native tool exited with $($process.ExitCode); see $LogPath" }
        return $text
    }
    finally { $process.Dispose() }
}

function Invoke-Godot([string]$Executable, [string[]]$Arguments, [string]$LogName) {
    $log = Join-Path $script:BuildRoot $LogName
    $text = Invoke-LoggedProcess $Executable $Arguments $log
    if ($text -match 'ERROR:|SCRIPT ERROR:') { throw "Godot failed; see $log" }
}

function Copy-Notices {
    $licenses = Join-Path $script:DistributionRoot 'licenses'
    [void][IO.Directory]::CreateDirectory($licenses)
    if ($GodotExecutable) {
        foreach ($name in @('LICENSE.txt', 'COPYRIGHT.txt')) {
            $source = Join-Path ([IO.Path]::GetDirectoryName((Resolve-Path -LiteralPath $GodotExecutable).Path)) $name
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Godot license file is missing: $name" }
            Copy-Item -LiteralPath $source -Destination (Join-Path $licenses "Godot_$name") -Force
        }
    }
    $thirdParty = @{
        'MediaPipe' = @('native/third_party/mediapipe/LICENSE', 'native/third_party/mediapipe/NOTICE', 'native/third_party/mediapipe/manifest.json')
        '7-Zip' = @('native/third_party/7zip/DOC/License.txt', 'native/third_party/7zip/DOC/copying.txt', 'native/third_party/7zip/DOC/unRarLicense.txt', 'native/third_party/7zip/BINARY_LICENSE.txt', 'native/third_party/7zip/manifest.json')
        'Spout2' = @('native/third_party/Spout2/LICENSE', 'native/third_party/Spout2/NOTICE', 'native/third_party/Spout2/NOTICE.txt', 'native/third_party/Spout2/REVISION.txt')
        'Honkai-MMD' = @('plugins/honkai_mmd/LICENSE', 'plugins/honkai_mmd/UPSTREAM.md')
        'Kaitai' = @('plugins/honkai_mmd/thirdparty/ksy/kaitai/LICENSE')
    }
    foreach ($component in $thirdParty.Keys) {
        $folder = Join-Path $licenses $component
        [void][IO.Directory]::CreateDirectory($folder)
        foreach ($relative in $thirdParty[$component]) {
            $source = Join-Path $script:ProjectRoot $relative
            if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination (Join-Path $folder ([IO.Path]::GetFileName($source))) -Force }
        }
    }
    Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'README.md') -Destination (Join-Path $script:DistributionRoot 'README.md') -Force
    foreach ($name in @('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'NOTICE', 'NOTICE.md')) {
        $source = Join-Path $script:ProjectRoot $name
        if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination (Join-Path $script:DistributionRoot $name) -Force }
    }
    $notice = @'
# Third-party software

Motion capture, PMX reading and archive handling use native C++ with Godot, MediaPipe and 7-Zip DLLs. The MMD parser is a modified MIT fork of V-Sekai/godot-pmx, including the MIT Kaitai runtime. Spout2 provides native GPU texture output under its BSD 2-Clause license. No Python or Blender runtime is required or included.

Complete available license/NOTICE texts and pinned version manifests are in licenses/.

- Godot source: https://github.com/godotengine/godot
- MediaPipe source: https://github.com/google-ai-edge/mediapipe
- 7-Zip 26.05 source: https://github.com/ip7z/7zip/releases/download/26.05/7z2605-src.tar.xz
- 7-Zip license: https://www.7-zip.org/license.txt
- Spout2 source: https://github.com/leadedge/Spout2

7-Zip contains LGPL, BSD and unRAR-restricted components. The application exposes ZIP/7z import only; it does not expose RAR, encrypted or split-archive import.

No MMD character model or character texture is included. Users must obtain models and follow their authors' terms. The project's own code uses the MIT license; third-party licenses remain separate.
'@
    Write-Utf8File (Join-Path $script:DistributionRoot 'THIRD_PARTY_NOTICES.md') $notice
    Write-Utf8File (Join-Path $script:DistributionRoot '使用说明.txt') "运行 HonkaiRender.exe，整个文件夹一起分发。`n应用不附角色模型，请导入自己的 ZIP/7z 并选择 PMX。`nPMX 由 C++ 原生加载，无需 Blender 或 Python。正常运行无需联网。`n个人设置、缓存和日志保存在当前 Windows 用户的数据目录。`n画面 → OBS 视频输出中选择分辨率、帧率并启动；OBS安装Spout2插件后添加BengRender源，Alpha使用预乘。`n"
}

function New-DistributionArchive {
    Assert-NativePackage $script:DistributionRoot
    $checksums = @{}
    $lines = foreach ($file in Get-ChildItem -LiteralPath $script:DistributionRoot -Recurse -File | Sort-Object FullName) {
        if ($file.Name -eq 'SHA256SUMS.txt') { continue }
        $relative = $file.FullName.Substring($script:DistributionRoot.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $checksums[$relative] = $hash
        "$hash  $relative"
    }
    $manifest = Join-Path $script:DistributionRoot 'SHA256SUMS.txt'
    Write-Utf8File $manifest (($lines -join "`n") + "`n")
    $checksums['SHA256SUMS.txt'] = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $rootName = [IO.Path]::GetFileName($script:DistributionRoot)
    $archiveName = "$rootName-windows-x64.zip"
    $archive = Join-Path $script:ProjectRoot "dist/$archiveName"
    $temporary = Join-Path $script:BuildRoot ('MotionCapture_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.zip')
    [IO.Compression.ZipFile]::CreateFromDirectory($script:DistributionRoot, $temporary, [IO.Compression.CompressionLevel]::Optimal, $true)
    $zip = [IO.Compression.ZipFile]::OpenRead($temporary)
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($entry in $zip.Entries) {
            if (-not $entry.Name) { continue }
            if (-not $entry.FullName.StartsWith("$rootName/")) { throw 'Unexpected ZIP root' }
            $relative = $entry.FullName.Substring($rootName.Length + 1)
            if (-not $checksums.ContainsKey($relative) -or -not $seen.Add($relative)) { throw "Unexpected or duplicate ZIP entry: $relative" }
            $stream = $entry.Open()
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
            finally { $algorithm.Dispose(); $stream.Dispose() }
            if ($hash -ne $checksums[$relative]) { throw "ZIP verification failed: $relative" }
        }
        if ($seen.Count -ne $checksums.Count) { throw 'ZIP is missing files' }
    }
    finally { $zip.Dispose() }
    Move-Item -LiteralPath $temporary -Destination $archive -Force
    $digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8File ($archive + '.sha256') "$digest  $archiveName`n"
    return [ordered]@{ archive = $archive; bytes = (Get-Item -LiteralPath $archive).Length; sha256 = $digest; files = $seen.Count }
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (([int]($RuntimeOnly.IsPresent) + [int]($ExportOnly.IsPresent) + [int]($StageOnly.IsPresent)) -gt 1) { throw 'Select only one of RuntimeOnly, ExportOnly and StageOnly' }
[void][IO.Directory]::CreateDirectory($script:BuildRoot)
[void][IO.Directory]::CreateDirectory($script:DistributionRoot)
Write-Utf8File (Join-Path $script:BuildRoot '.gdignore') ''
Write-Utf8File (Join-Path $script:BuildRoot '.gitignore') "*`n"
Write-Utf8File (Join-Path $script:ProjectRoot 'dist/.gdignore') ''
if ($StageOnly) {
    $stage = New-ExportStage
    [ordered]@{ stage = $stage; exported = $false } | ConvertTo-Json
    exit 0
}
Move-LegacyRuntime
Copy-Notices
if ($RuntimeOnly) {
    [ordered]@{ portable_directory = $script:DistributionRoot; exported = $false } | ConvertTo-Json
    exit 0
}
if (-not $GodotExecutable) { throw 'GodotExecutable is required for export' }
$stage = New-ExportStage
$editor = Get-IsolatedEditor $GodotExecutable
Invoke-Godot $editor @('--headless', '--editor', '--path', $stage, '--import') 'godot_import.log'
Invoke-Godot $editor @('--headless', '--path', $stage, '--export-release', 'Windows Desktop', (Join-Path $script:DistributionRoot 'HonkaiRender.exe')) 'godot_export.log'
$libraries = Join-Path $script:DistributionRoot 'native/bin'
[void][IO.Directory]::CreateDirectory($libraries)
foreach ($name in $script:NativeLibraries) { Copy-Item -LiteralPath (Join-Path $stage "native/bin/$name") -Destination (Join-Path $libraries $name) -Force }
$duplicates = Join-Path $script:BuildRoot ('retired_flat_native_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
foreach ($name in $script:NativeLibraries) {
    $flat = Join-Path $script:DistributionRoot $name
    if (Test-Path -LiteralPath $flat -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $flat).Hash -ne (Get-FileHash -LiteralPath (Join-Path $libraries $name)).Hash) { throw "Unexpected duplicate native library: $name" }
        [void][IO.Directory]::CreateDirectory($duplicates)
        Move-Item -LiteralPath (Assert-WorkspacePath $flat) -Destination (Join-Path $duplicates $name)
    }
}
Write-Utf8File (Join-Path $script:BuildRoot 'last_export_source.txt') $stage
New-DistributionArchive | ConvertTo-Json
