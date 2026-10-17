# Camera Raw 原生宿主实验

2026-10-17 已在 Photo Browser 的独立原生辅助进程中直接打开 Camera Raw 18.1.1（2422），并完成 TIFF 和 Nikon D3S NEF 的混色调整及保存验证。应用菜单已改接原生辅助程序，当前属于实验性集成。窗口中可见 Light、Color、Color Mixer、HDR 等界面，像素回传及 HDR 输出尚未实现或验证。

## 应用集成

`Native/CameraRawHost/main.mm` 使用公开 SDK 的 `formatSelectorBulkSettings=20`，以 `fileCount` 和等长文件／标记／参数数组传入一张或多张照片及已有 XMP。输入通过带版本号的 JSON 清单传递，避免路径转义和命令行长度限制。不声明 `PIFmtBulkOpenMask` 和 `PIFmtBulkModifyListMask`，只支持调参与插件自身写出合并文件，不接收像素或让插件重分配宿主数组。实测仍可使用全景合并。公共内存服务由宿主与探针共用。调用生命周期为 `24 → 1 → 20 → 25`。

`CameraRawLauncher.swift` 启动应用包内的 `Contents/Helpers/CameraRawHost.app`，识别用户级／系统级插件目录，不启动 Bridge 或 Photoshop。相同文件集合（忽略顺序、去除规范路径重复）会激活已有编辑器，其他集合会提示先结束当前编辑。启动前通过 AppKit 的协作激活 API 允许辅助应用获得前台。辅助进程启动、观察到编辑器、正常关闭或失败时写原子 JSON，记录输入数量；Swift 同时检查退出状态及 JSON，缺失、损坏、崩溃及插件错误不会误报成功。正常关闭不等于已保存，不给 Done／Cancel 编造保存结果。

「完成」由 Camera Raw 向实际照片或 XMP 写设置，浏览器不复制测试图、不修改 XMP 内容。关闭后走现有目录核对逻辑，保留选择和分组。浏览器仍使用系统 RAW 解码，不执行 Adobe XMP 显影。编辑过程不限时，退出浏览器不会主动结束辅助进程。

`scripts/build-camera-raw-host.sh` 从固定版本 SDK 编译 arm64 或通用辅助程序并签名，`build-app.sh` 将其打包后再签主应用。SDK 仅为构建依赖，不复制进源码或应用，也不打包 Adobe 插件。UI 自动操作只在显式测试构建中编译，正式打包强制关闭它。

基础检查：`bash scripts/check-camera-raw.sh`。已安装插件和 ExifTool 时运行 `bash scripts/check-camera-raw.sh --ui --raw /path/to/sample.NEF`，所有界面测试只编辑临时副本。测试产物保存在 `.build/camera-raw-checks.*/`。下面保留前两轮诊断过程，`read` 探针与应用使用的 `BulkSettings` 是不同路径。

本机集成验收已通过，产物位于 `.build/camera-raw-checks.GuN0S5/`：TIFF／NEF 混色明亮度保存为 `+1`，重新打开能读回；随后改为 `2` 再取消，TIFF 及 NEF／XMP 的内容哈希保持取消前状态。原始 NEF 哈希仍为 `5922721d13f11795557d97fdeb0a60b900086c402bc82a848ff280d15b99ffd4`。测试使用含中文、引号、空格、反引号及表情的路径，Swift 启动器的实际打包调用、同图复用、异图忙碌提示和异步完成也通过。UI 自动操作先等待控件可用，使用宿主自身事件和标准 Cocoa action，并以独立 ExifTool 和文件哈希验收，不把窗口关闭当作保存证据。

应用已完成 arm64／x86_64 通用打包及递归签名校验，预览状态检查、中英文本地化和打包更新器检查通过；Intel 版本仅验证编译及架构，未在 Intel 硬件上运行 Adobe 插件。产物是当前 worktree 下的 `dist/照片浏览器.app`，没有替换已安装应用或发布更新。

## 多选与全景拼接

浏览器选中多张照片后右键打开，每张拍摄仅选择 RAW 或首选图片，不重复发送配对格式，排除视频／实况。右键未选中的照片只开该张；指定格式仍只开该文件。关闭 Camera Raw 后核对相关目录，已写入当前目录的新 DNG 能进入现有扫描／预览链路。

已验证三张 768×512 重叠 TIFF 一起进入胶片栏，⌘M 可打开 Panorama Merge Preview。普通 Merge… 的 NSSavePanel 在本机报告无法连接系统保存面板服务；改用 Launch Services 启动、调整资源文件上下文及测试面板外观均未解决，因此没有把这些未证实的改动放进正式宿主，也不把普通保存面板列为已通过能力。

已通过 ⌘⇧M（使用上次设置直接合并）生成 `overlap-1-Pano.dng`：ExifTool 报告 DNG 1.7.0.0、1278×510，输入 TIFF 哈希不变。浏览器实际扫描出四张照片并解码新 DNG，原图为 1278×510；此验证不等同于 HDR 合并验证。相关记录在 `.build/camera-raw-checks.nDBvZd/results/panorama/`。测试没有读取或修改用户全景素材。

复跑完整检查：`bash scripts/check-camera-raw.sh --ui --panorama --raw /path/to/sample.NEF`。全景素材由 `PanoramaFixtures.swift` 确定性生成。`check-panorama.py` 的 `--automatic` 明确选择直接合并，默认模式检查预览和普通保存面板，不会在失败时静默改走快捷流程。生产程序没有自动按键，合并操作由用户在 Camera Raw 中执行。

## 第一轮结果：最小宿主

实验直接加载本机插件，使用 Adobe 官方 C++ SDK 的结构体与函数签名调用入口，全程没有调用 Bridge 或 Photoshop。辅助进程使用 Photo Browser 自己的宿主签名 `PBrw`。

| 阶段 | 实测结果 |
| --- | --- |
| `NSBundle` / `dlopen` | 成功，解析到 `EntryFM` 与 `EntryFI` |
| 文件格式加载 `24` | 返回 `0`，同时记录未知宿主签名及缺失服务 |
| 读取准备 `1` | 返回 `0` |
| 打开图像 `2` | 弹出宿主不兼容错误，没有进入编辑器 |
| 文件格式卸载 `25` | 返回 `0`，正常结束进程 |

关键原始日志：

```text
Unknown hostSignature: 0x50427277 ('PBrw')
AcquireSuite: Photoshop Plugin State Suite for Plug-ins v1
Window: Error
Window text: Unable to use the Camera Raw plug-in.
Window text: It is not compatible with this host.
Dismissing this helper's unsupported-host alert.
Returned selector=2 result=1 state=0x0 missingSuites=8
Returned selector=25 result=0 state=0x0 missingSuites=8
```

`result=1` 是探针关闭该错误弹窗后的返回值，不能单独解释成 Adobe 的“宿主不兼容”错误码。兼容性结论来自插件自身的窗口文本。`missingSuites` 是失败的请求次数，包含重复请求。

初始化还请求了以下服务：

- `Photoshop Access Suite for Plug-ins v1`
- `AS ZString Suite v1`
- `AS ZString Dictionary Suite v1`
- `OS Direct ExpressView Suite v3`
- `Photoshop Utilities Suite for Plug-ins v1`
- `SP Suites Suite v2`

探针实现了 `SPBasicSuite` 的内存管理和服务查询，以及返回明确“属性未定义”错误的 Property Suite 回调；其他服务返回 SDK 的 `kSPSuiteNotFoundError`。因此这是一份最小宿主的兼容性实验，不是完整 Photoshop 宿主实现。

本次取得的官方 SDK 中，未找到 `Photoshop Plugin State Suite` 的公开定义。后续继续推进需要调查并实现实际的宿主服务协议及兼容性要求。当前结果适用于本机插件版本和这份最小宿主，不能据此断言所有第三方宿主均无法实现。

## 第二轮进展：编辑器窗口已打开

在同一个独立宿主中逐步改变兼容性配置，实测结果如下：

| 配置变化 | 实测结果 |
| --- | --- |
| 使用 `8BIM` 兼容性签名 | 从“宿主不兼容”变成“与此版本的 Photoshop 不兼容” |
| 按 SDK 规范提供 `propVersion=25.0.0` | 入口返回 `-30900`，即 SDK 定义的 `errPlugInHostInsufficient` |
| 增加标准及 PICA 内存服务、非空 `advanceState` 回调 | 越过上述检查，进入设置面板初始化；出现 `Bad fSettingsPane` 错误 |
| 包装为自己的原生 `.app` 并完成 AppKit 启动 | 单独未解决设置面板错误 |
| 用 `CFBundleOpenBundleResourceMap` 打开插件自身资源 | 读取到 2 个 PiPL，设置面板错误消失，出现 `Camera Raw 18.1.1` 窗口 |

这里的 `8BIM` 和接口版本是可切换的诊断配置，不代表宿主已实现全部 Photoshop API。默认配置仍为 `PBrw`。没有修改插件、订阅配置或序列号／令牌数据。

打开的窗口中能看到 Color Mixer 的八色滑块，以及 HDR 按钮。AppKit 对宿主自有窗口的截图保存在对应日志目录的 `camera-raw-window.png`；这类截图不能可靠捕获 Metal 预览图层，因此不能仅凭截图的灰色预览区判断照片是否正常渲染。

对运行进程的采样显示，主线程停留在 Camera Raw 调用的 `NSApplication runModalForWindow:` 中等待事件。窗口打开后不立即返回属于预期行为，限时探针到期终止进程的记录不能单独视为初始化挂死。

日志仍有 `Fetch token method not implemented` 和缺少访问令牌的告警。现有证据仅能说明窗口在这些告警下仍可打开，不能据此确认哪些在线功能可用，也不能直接认定告警阻止基础调色。

### 参数保存验证

使用宿主自身 AppKit 事件队列向自有窗口发送键盘与鼠标事件，调整 Color Mixer → HSL → Luminance 的第一行，再点击 Done。用独立的 ExifTool 读取保存结果，不以控件显示值作为成功证据。

| 输入 | 保存结果 | 校验 |
| --- | --- | --- |
| 生成的 64×64 RGB TIFF | XMP 嵌入 TIFF | `HasSettings=true`，`LuminanceAdjustmentRed=+1` |
| 公开样本 Nikon D3S NEF，4288×2844 | 新建 `fixture.xmp` | 同上，NEF 文件 SHA-256 保持不变 |

最终验证的 TIFF 日志位于 `.build/camera-raw-host-results/20261017-121440-829257/`；NEF 日志位于 `.build/camera-raw-host-results/20261017-121751-276404/`。两次包装脚本均退出 `0`，没有超时或崩溃。NEF 保存证据：

```json
{
  "HasSettings": true,
  "LuminanceAdjustmentRed": "+1"
}
```

测试 NEF 的原始副本和保存后的副本 SHA-256 均为 `5922721d13f11795557d97fdeb0a60b900086c402bc82a848ff280d15b99ffd4`。Cancel 也已通过自有窗口鼠标事件验证，可正常返回。

点击 Done 或 Cancel 后，Camera Raw 返回 `-128`，然后正常完成 `selector=25` 卸载；原生进程将非零入口结果保留为退出码 `2`。包装脚本会结合“窗口确实打开”和“对话框正常关闭”判断成功；`edit-save` 模式还必须读回正确的 XMP 参数才返回 `0`。未实现的可选服务请求数不能直接视为界面失败。

尝试过的合成 CFA DNG 被插件返回 `formatUnsupportedRaw=-30504`，没有进入编辑界面。这个样本虽然通过 ExifTool 结构验证，但不替代真实相机兼容性测试。当前 RAW 成功证据限于上述 Nikon D3S NEF。

## 复现

需要 macOS、Apple Command Line Tools、`uv`、Git，以及本机已安装的 Camera Raw 插件。在包含此实验的 worktree 根目录运行：

```bash
git clone https://github.com/AdobeDocs/photoshop-cpp-sdk.git .build/camera-raw-sdk
git -C .build/camera-raw-sdk checkout 7e9aca4353a3d4615e9522f47521bf840fb4388c
uv run scripts/probe-camera-raw-host.py
```

SDK 只下载到忽略的 `.build/`，没有把 SDK 或 Adobe 插件复制进项目源码。使用 SDK 前可查看其自身的 `LICENSE.md`。已有 SDK 时直接运行最后一条命令；也可以使用 `--sdk /path/to/sdk`。

默认生成一张 64×64 RGB TIFF，在独立进程中依次测试 `load`、`initialize`、`prepare`、`read`。Camera Raw 支持 TIFF，因此此项验证不需要访问照片库。指定 `--image /path/to/photo.ARW` 时，脚本先复制到本次实验目录，再交给插件，原文件及已有 XMP 不会传给插件。

```bash
uv run scripts/probe-camera-raw-host.py --mode load
uv run scripts/probe-camera-raw-host.py --mode read --image /path/to/test.ARW
```

复现已经打开窗口的兼容性配置：

```bash
uv run scripts/probe-camera-raw-host.py --mode read \
  --host-signature 8BIM --api-version 25.0.0 --services public \
  --app-environment --resource-map --capture-window --timeout 120
```

该命令直接调用本机插件，不启动 Bridge 或 Photoshop。只对生成的测试图或 `--image` 的临时副本进行操作。`--automation cancel` 用于检查关闭流程；`--automation edit-save` 验证上述八色 HSL 布局中的一个参数保存。

也可以使用快捷配置，默认保留窗口 5 分钟供交互：

```bash
uv run scripts/probe-camera-raw-host.py --editor
uv run scripts/probe-camera-raw-host.py --editor --image /path/to/photo.NEF
```

`--editor` 启用上面经过验证的兼容性配置。它始终编辑临时副本，保存结果留在本次实验目录。需要检查时再加 `--capture-window`，截图只读取宿主自己的窗口。

复跑混色保存验证需要 ExifTool，并要求当前 Camera Raw 的 Color Mixer 位于 HSL 明亮度页，显示八色数值行；面板布局不匹配时验证不会通过：

```bash
uv run scripts/probe-camera-raw-host.py --editor --automation edit-save --timeout 20
```

`summary.json` 分别记录 `editor_window_opened` 和 `settings_round_trip_verified`。`working_editor_verified` 保持 `false`，因为这两项成功还不等于整个编辑宿主已实现。

每次运行保留编译日志、各阶段日志、测试图和 `summary.json`，目录为 `.build/camera-raw-host-results/<timestamp>/`。脚本会打印实际路径。

原生辅助进程的退出码：`0` 表示探针调用完成；`2` 表示入口返回非零结果；`3` 表示记录到缺失服务。包装脚本对上述正常关闭进行单独处理，其他非零或超时返回 `1`。最小配置的默认全流程仍返回 `1`，是已记录的兼容性失败，不是编译失败。

每个进程默认限时 15 秒；超时只终止本次探针自己的进程组。探针仅检查自己创建的窗口，并自动点击已识别的“宿主不兼容”弹窗的默认按钮，不需要辅助功能权限。它不会自动操作其他弹窗。

## 实验边界

前两轮实验已验证一个 HSL 参数保存到 TIFF／NEF XMP；像素回传、其他调色项和 HDR 预览／导出尚未验证。应用集成使用上面的设置专用入口。没有修改已安装的 Adobe 插件、应用身份或订阅配置；兼容性签名与版本只作用于宿主传入的参数块。

`advanceState` 目前是明确返回错误的未实现回调，不能使用 read 探针的 Open 按钮把处理后的像素导入宿主。正式入口通过 BulkSettings 不提供此操作；若插件仍请求像素传输，会明确报错。公共内存服务位于 `Native/CameraRawHost/MemorySuites.hpp`，属于有限的宿主实现。

最初未补齐加载／卸载生命周期时，读取准备后的进程会在 GPU 管理器退出阶段挂住；采用 `24 → 1 → 2 → 25` 后，最终验证的四个阶段均无崩溃、无超时。

## 来源

- [Adobe 官方 Photoshop C++ SDK](https://github.com/AdobeDocs/photoshop-cpp-sdk)：本次使用版本 `7e9aca4353a3d4615e9522f47521bf840fb4388c`。
- SDK 的 `PIFormat.h`：`FormatRecord`、入口选择器和宿主签名字段。
- SDK 的 `PIGeneral.h` 与 `SPBasic.h`：Property Suite、服务查询及内存管理接口。
- 本机 `/Library/Application Support/Adobe/Plug-Ins/CC/File Formats/Camera Raw.plugin`：版本信息、导出符号和上述运行日志。
- [rawpy 的 Nikon NEF 测试样本](https://github.com/letmaik/rawpy/blob/a39c2e7a44911889c3360891012f862f904ba551/test/iss030e122639.NEF)：仅下载到忽略的 `.build/` 并复制后测试，没有纳入项目源码。
