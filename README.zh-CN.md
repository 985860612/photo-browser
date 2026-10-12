# 照片浏览器

简体中文 · [English](README.md)

## 下载与语言

从 [GitHub Releases](https://github.com/985860612/photo-browser/releases) 下载通用版，支持 macOS 14+ 的 Apple Silicon 和 Intel Mac。解压后放入 Applications。发布包采用临时签名，未经过 Apple 公证；如系统拦截，请核对来源后在“系统设置 → 隐私与安全”中选择“仍要打开”，也可自行从源码构建。

界面随 macOS 首选语言显示简体中文或英文（Photo Browser），其他语言回退到英文。可在“系统设置 → 通用 → 语言与地区 → 应用程序”中为本应用选择语言，重新打开后生效。已有目录名、分组名称和用户填写的描述会保留。

大图和全屏的“RAW 优先”开关可选择优先预览 RAW 或 HIF/JPG。左右面板可独立收起，拖动底部缩略条上边界可调整高度。

macOS 原生照片浏览器，同名 RAW、HIF、JPG 合并成一次拍摄，全景按组浏览，确认后整组移动到新文件夹，支持撤销与中断恢复。

## 使用

1. 打开“照片浏览器.app”，点击“打开目录”（⌘O）。点击顶部路径中的任一级文件夹即可跳转，⌘L 输入或粘贴路径，支持 `~/Pictures`。⌘[ / ⌘] 后退与前进、⌘↑ 上一级；“全部照片”视图在底部缩略条或网格开头显示子文件夹卡片，双击进入；路径栏菜单也可进入子目录。分组和“未分组”视图只显示对应照片。每次只扫描当前目录。
2. 同名格式只显示一个缩略图，右侧“预览格式”可切换 HIF/JPG 与 RAW。
3. 左侧选择分组，网格显示组内全部照片。双击照片进入大图，左右键切换，⌘J 切换网格与大图。**空格进入全屏并解码原始分辨率图像**，空格或 Esc 退出；可切换同名格式、适应屏幕或按 100% 像素检查细节。普通 RAW 浏览使用相机内嵌 JPEG 加速；全屏 RAW 使用系统原图解码，解码失败会明确提示切换格式。系统 RAW 显示与 Camera Raw 显影可能不同。
4. ⌘ 点击多选、⇧ 点击连选；⇧＋左右方向键以起始照片为锚点延伸连续选择，反向按键收缩范围，普通左右键恢复单张切换。⌘G 手动成组；在右侧按当前照片拆分、合并到其他组、或移出所选照片。
5. 右键分组选择“重命名…”，名称会保存，移动整组时默认使用此名称作为文件夹名；原照片名保持不变。“移动整组到新文件夹…”列出目标位置、所有格式及 XMP 文件，选择存放位置并填写新文件夹名称后，点击“确认移动”才修改原文件位置；可通过移动记录撤销。目标文件夹必须是新目录。
6. “移动记录”可撤销，也可恢复因退出或连接中断而未完成的操作。遇到同名文件、文件变化或缺失会报告并停止。
7. 在照片网格、底部缩略图或大图上右键，选择“在 Camera Raw 中打开”。优先选同名 RAW；也可在“指定格式”子菜单选择 HIF/JPG。RAW 直接交给 Photoshop 打开；HIF/JPG 通过 JSX 调用 Camera Raw 对话框，Photoshop 若提示外部脚本来源，请核对后允许。需要安装 Photoshop 及 Camera Raw，格式和相机支持由所装版本决定，打开失败会提示。此入口只打开素材，是否保存修改由你在 Camera Raw 中决定。参见 [Adobe Camera Raw 说明](https://helpx.adobe.com/camera-raw/desktop/get-started/overview-and-setup/introduction-camera-raw.html) 与 [Photoshop 脚本说明](https://helpx.adobe.com/photoshop/using/scripting.html)。
8. 大图和全屏均支持触控板捏合缩放、双指/鼠标滚动平移、鼠标拖拽平移（触控手势让照片跟随手指，兼容自然滚动开关）、⌘或 Option＋滚轮缩放，双击切换适应屏幕与 100% 像素。空白目录页显示子文件夹封面与合并后的照片数量，双击卡片进入，自动隐藏空的照片信息栏。

## HDR 与色彩

大图和全屏读取源图色彩配置，使用 Core Image 与 Metal 的 16 位浮点显示面，并启用系统 EDR。HDR 开关控制 ImageIO 的 HDR/SDR 解码方式；支持系统可解码的 HLG、PQ 与增益图 HDR，显示范围随当前屏幕能力调整，macOS 15+ 使用系统色调映射适配高光。普通 SDR 照片保持 SDR，不会人为拉亮。10 位 HIF 不必然是 HDR；界面依据实际解码后的动态范围标记 HDR/SDR。屏幕不支持 EDR 时无法显示超过 SDR 白点的亮度，但仍进行色彩管理。参考 [Apple HDR 图像支持](https://developer.apple.com/videos/play/wwdc2023/10181/) 和 [Core Image / Metal EDR 显示](https://developer.apple.com/videos/play/wwdc2022/10114/)。

分组和移动记录保存在 `~/Library/Application Support/PhotoBrowser/`，缩略图缓存在 `~/Library/Caches/PhotoBrowser/`，不会写入原照片。目录内已有 `全景素材筛选/全景候选文件清单.csv` 时首次自动导入；以后恢复本地保存的分组，也可手动导入 CSV。

## 自动分组

需要 ExifTool（`brew install exiftool`）。读取每次拍摄一个文件，优先 RAW，否则 HIF/JPG，避免重复读取同名格式。连拍序号递增、时间间隔不超过 8 秒且焦距相同归为一组；单拍间隔不超过 5 秒且焦距相同也形成候选组。每组至少 3 张。

算法只提供候选，可能包含重复构图。没有进行特征匹配或拼接验证，必须查看画面再确认。NAS 首次读取 EXIF 可能需要几分钟，后台读取期间可继续浏览或取消检测。重新检测会替换当前分组，操作前会提示。

## 构建与检查

要求 macOS 14+、Swift 6 工具链。使用系统 SwiftUI、AppKit、ImageIO，无需下载安装第三方 Swift 包。

```bash
swift run BrowserCoreChecks
swift run BrowserHDRChecks
swift run BrowserThumbnailChecks
bash scripts/check-preview-store.sh
bash scripts/build-app.sh
bash scripts/check-localization.sh 'dist/照片浏览器.app'
open 'dist/照片浏览器.app'
```

真实照片的只读检查（配对、CSV 导入、EXIF、缩略图方向、原始分辨率及缓存）：

```bash
swift run BrowserSmokeChecks '/path/to/photos' DSC00648 DSC00672
```

独立检查程序不依赖 XCTest，也可在仅安装 Command Line Tools 的机器运行。移动模块的测试只操作临时目录，覆盖全格式移动/撤销、同名冲突、部分失败回滚、日志写入失败和中断恢复。移动记录在原文件操作前写入；文件定位、大小及修改时间用于校验，不计算整库内容哈希。分组归档是逐文件移动，不是跨文件原子事务；连接不可用时保留记录，重新连接后从“移动记录”继续恢复。

预览使用 [Apple ImageIO](https://developer.apple.com/documentation/imageio/cgimagesource)，生成时按照片方向旋转，并限制分辨率以避免一次解码整个图库。打开目录后自动在后台生成所有合并照片的首选格式缩略图，底部显示进度。可见照片使用两个加载通道，后台预生成使用单独的一个通道，优先处理当前分组与滚动位置附近的照片；同一照片的请求共用解码，切换目录取消旧任务。沿用原有磁盘缓存，缓存 JPEG 在后台立即解码，内存命中直接返回图片与元数据。后台生成不挤占可见照片的内存缓存，也不改动原照片。首次访问未缓存照片仍需读取，后台生成完成后滚动直接使用本地缓存。缓存超过 2,000 张时清理较旧项目，保留当前目录的预览。

构建 Apple Silicon 与 Intel 通用版：`PHOTO_BROWSER_UNIVERSAL=1 bash scripts/build-app.sh`。中英文验证覆盖语言资源、动态数量、Unicode 名称、错误提示、旧分组读取及应用包内资源加载。

## 开源协议

[MIT](LICENSE)，Copyright © 2026 wangxiaojie。
