# Honkai-style real-time rendering

简称 **Honkai Render**。面向 Windows 的开源角色动捕与卡通渲染应用：导入自己的 MMD 角色，通过摄像头驱动面部、手势和上肢，再通过 Spout2 向 OBS 输出高清透明视频。渲染以米哈游游戏的卡通视觉风格为参考，采用自有着色器。

**程序、源码和 Release 均不带角色模型或贴图，首次启动为空场景。** 本项目不是游戏原版渲染器，也不附带游戏资源。

## 使用

从 Releases 下载 Windows x64 ZIP，完整解压后运行 `HonkaiRender.exe`。常规运行不需要 Python、Blender或开发工具，不会在启动时打开摄像头。

1. 通过“模型”导入 ZIP / 7z，选择包内 PMX，也可拖入压缩包。贴图应包含在原始包中。
2. 在“捕捉”选择摄像头，点击开始；可打开同一采集帧的视频及关键点预览。
3. 在“映射”调整眼睛阈值、范围、平滑和 Sigmoid 曲率。曲线实时圆点显示当前识别值。
4. 在“画面”调整灯光、描边、相机、MSAA 和 OBS 输出；在“场景”设置背景、图片或 GLB 场景。

默认仅角色展示区域透明，保留系统标题栏；菜单保持不透明、支持缩放、拖动和收起。常驻面板只保留六个入口及捕捉状态。下肢保持站姿，不包含角色行走或战斗。

| 按键 | 操作 |
|---|---|
| 中键拖动 | 旋转镜头 |
| Shift + 中键 | 平移 |
| Ctrl + 中键、滚轮 | 缩放 |
| 小键盘 1 / 3 / 7 | 正面 / 右侧 / 顶部 |
| Ctrl + 小键盘 1 / 3 / 7 | 对应反面 |
| 小键盘 5 | 透视 / 正交 |
| Home、小键盘小数点 | 重新取景 |
| H | 隐藏 / 恢复导航 |
| F12 | 保存带 Alpha 的 PNG |

设置、截图及导入缓存保存在当前用户的 `%APPDATA%/Godot/app_userdata/MMD Motion Capture`。旧版用户目录继续使用，发布包不携带个人配置。

## 导入与渲染

PMX 默认直接在应用内由 C++ 读取，不再经过 Blender / glTF 材质转换。独立的 [MMD 加载与渲染器仓库](https://github.com/furinasdog/Honkai-MMD-Loader)通过 Git submodule 固定版本。读取原始 UV、材质面范围、贴图、骨骼、顶点表情、描边权重和刚体关节；重复使用的贴图共享内存。缺失必需贴图、损坏数据或超出支持范围时取消导入，并保留当前角色。

渲染包括分材质明暗分层、头部空间面部阴影、头发高光和 MMD 几何描边。遵守材质的单面／双面设置，避免背面内衬覆盖外层贴图。材质识别兼容简繁中文、日文和常见英文名称，未知模型仍可能需要适配。脸部没有作者提供的 SDF 时使用通用头部空间近似，不能保证与所有角色的游戏实机完全一致。

PMX 刚体和弹簧 6DOF 关节映射到 Jolt，以 120 Hz 求解；头发防穿模辅助覆盖头颈、肩膀和身体。碰撞使用模型代理形状，不是布料网格自碰撞，因此不能保证所有姿势完全无穿插。

支持 BDEF1/2/4，SDEF/QDEF 使用线性蒙皮兼容模式；顶点和顶点组合表情可用于动捕。骨骼／UV／材质／冲量变形、附加变换约束和 PMX 软体尚未完整支持。详见加载器的 UPSTREAM.md。原生路径未实现的特殊模型可显式选择 Blender 兼容转换，兼容组件需另行准备；默认 Release 不包含 Blender。

## OBS 输出

安装 [OBS Spout2 插件](https://github.com/Off-World-Live/obs-spout2-plugin)，在“画面 → OBS 视频输出”选择 720p、1080p、1440p（2K）或 4K，30 / 60 FPS，启动后在 OBS 选择 `BengRender` 源。Alpha 使用预乘。输出独立于窗口尺寸，只包含角色，不包含菜单或附加场景。最小化窗口可继续输出。

当前提供 Spout2 视频源，不注册 Windows 系统摄像头。会议软件可通过 OBS 的普通虚拟摄像头转发，普通视频链路不保留 Alpha。4K 60 FPS 取决于显卡和模型负载。独立原生 Spout 接收端已验证，OBS 插件内端到端接收尚未实测。

## 从源码构建

需要 Windows SDK、C++17、CMake 3.20+、PowerShell 7，以及 Godot 4.7 单精度 x64 编辑器和匹配的导出模板。已验证 Visual Studio 2026；其他编译器尚未验证。没有 Python 绑定生成步骤，不定制 Godot 引擎。

```powershell
git clone --recurse-submodules https://github.com/furinasdog/Honkai-Style-RealTime-Rendering.git
cd Honkai-Style-RealTime-Rendering
./tools/fetch_dependencies.ps1
# $Godot 指向本机 Godot 4.7 编辑器
cmake -S native -B build/native -G "Visual Studio 18 2026" -A x64 "-DGODOT_EXECUTABLE=$Godot" -DBUILD_NATIVE_TESTS=ON
cmake --build build/native --config Release --parallel
ctest --test-dir build/native -C Release --output-on-failure
./tools/build_portable.ps1 -ExportOnly -GodotExecutable $Godot
```

依赖准备脚本从固定版本官方发行文件提取 MediaPipe 原生 DLL、7z DLL 和 Tasks 模型，并核对 SHA-256。MediaPipe 的发行压缩包是 wheel，但只提取原生 DLL，不安装或运行 Python。头文件、第三方许可和版本清单随源码保留。首次准备依赖需要联网，正常运行无需联网。

可选 Blender 兼容包使用 `-IncludeBlenderCompatibility -BlenderExecutable $Blender -MmdToolsPath $MmdTools` 构建。只在显式兼容转换时通过受控 Blender bpy worker 导入，禁止自动执行模型脚本。详见 [PORTABLE_BUILD.md](PORTABLE_BUILD.md)。

## 验证与许可

`tests/test_native_importer.gd` 验证 ZIP 到原生 PMX 的完整路径；`test_imported_model.gd` 验证完整面数、映射、物理和多姿态渲染；`test_toon_materials.gd` 用合成几何验证反面材质不会覆盖正面。其余测试覆盖动捕越界、阈值曲率、设置、透明窗口及 Spout 输出。真实角色测试由使用者提供私有资源，不随仓库发布。普通回归不打开摄像头，`test_camera_live.gd` 是需手动运行的硬件检查。

自有源码采用 MIT。第三方组件保留各自版权及许可证，包括加载器上游 MIT、Kaitai MIT、Godot MIT、MediaPipe Apache-2.0、Spout2 BSD-2-Clause 和 7-Zip 相关许可。角色资源的使用和分发需遵守原作者规则，本项目许可证不覆盖角色资源。