# Windows 便携发行包

默认发行目录是 `dist/HonkaiRender/`，运行 `HonkaiRender.exe`。发布包不带角色、贴图、私人缓存或开发工具，PMX 由原生 C++ 加载，不需要 Blender / Python。

## 准备及构建

```powershell
git submodule update --init --recursive
./tools/fetch_dependencies.ps1
cmake -S native -B build/native -G "Visual Studio 18 2026" -A x64 "-DGODOT_EXECUTABLE=$Godot" -DBUILD_NATIVE_TESTS=ON
cmake --build build/native --config Release --parallel
ctest --test-dir build/native -C Release --output-on-failure
./tools/build_portable.ps1 -ExportOnly -GodotExecutable $Godot
```

`$Godot` 是本机 Godot 4.7 单精度 Windows x64 编辑器，需要安装匹配的导出模板。原生 DLL 及 Tasks 模型分别放在 `native/bin/` 和 `mocap/models/`，准备脚本固定版本并核对哈希。C++ GDExtension 使用 Godot 官方 C 接口，不运行 Python 绑定生成器。当前已验证 Visual Studio 2026，其他编译器未验证。

`-StageOnly` 只生成并校验隔离导出副本。副本仅包括通用脚本、场景、着色器、MMD 子模块的 runtime/render、图标、原生库和 Tasks 模型，不复制 `assets/`、测试、参考图片或开发插件。编辑器与模板复制到 `build/editor_runtime/`，不修改系统安装目录。

导出副本和发行包不包含 Blender、mmd_tools 或 Python worker。`tools/import_pmx_blender.py` 仅保留为受控开发参考脚本。构建时若在旧发行目录发现转换运行时，会将它们移至工作区 `build/retired_conversion_runtime_时间戳/` 留存；包过滤仍拒绝这些组件。

导出后生成 ZIP、同名 `.sha256` 和包内 `SHA256SUMS.txt`，重新逐文件读取 ZIP 验证 SHA-256。校验完成才替换旧归档。与 Release 一起提供完整第三方许可，角色资产不得放入源码或 Release。

## 检查

`tests/test_portable_build.ps1` 验证包过滤、参数传递、ZIP 与校验清单。它不代替实际原生导入、渲染和 Spout 测试。使用隔离的 APPDATA 运行界面测试，以免读取或改写使用者配置。普通测试不能调用 `test_camera_live.gd`；该脚本是手动摄像头硬件检查。
