---
name: photo-browser-release
description: 为照片浏览器构建并签名 macOS 通用更新包，提交推送、发布 GitHub Release、核验更新源及更新本机应用。用户在本项目说“发布新版”“提交发布”“提交推送部署”时使用；只准备产物或只验收时遵守该范围。
---

# Photo Browser 发布

在照片浏览器仓库执行。先读 [发布文档](../../../docs/updates.md)，以仓库脚本和 `scripts/app-settings.plist` 为配置源；不要在技能里维护版本、密钥、机器绝对路径或发布状态的第二份配置。

## 范围与准备

- “发布新版／提交发布”授权本次版本的普通提交、同名推送、标签和稳定 Release；“只准备／不发布／不推送”优先。创建或验证技能本身不授权发布应用。
- 本机更新沿用当前请求和会话中的部署授权。没有本机更新授权时只准备可安装产物。特殊推送仍遵守项目 Git 护栏，已有普通发布授权不重复询问。
- 检查主仓、任务 worktree、远端和现有 Release。复用已有任务 worktree；分清本次变更，不能把别人的改动一起发布。发布产物写入忽略的 `dist/`，证据和备份写入 `.build/`。
- 检查 `gh`、`uv`、Xcode 命令行工具、钥匙串签名账户、已安装应用位置和当前应用／Camera Raw 进程。私钥只经 Sparkle 工具从钥匙串读取，不导出、不打印、不重新生成公钥。
- 构建脚本会原地重写当前仓库的 `dist/照片浏览器.app`。首次构建前检查是否有主程序、Camera Raw 或更新助手从该产物路径运行；有占用则保留原 bundle 原位完整，换到包含同一待发布源码且无运行进程的 worktree 构建，或延后构建。
- 先从配置和发布历史决定下一个版本，同时递增整数 Build；编写中英文发布说明，说明最终行为和真实限制。

## 构建、提交和发布

1. 沿用开发阶段已完成的功能验证，运行与改动相关的编译和静态检查。准备签名通用包：

   ```bash
   bash scripts/prepare-update.sh /absolute/path/release-notes.md
   bash scripts/check-update-installation.sh 'dist/照片浏览器.app'
   ```

   前者包含通用构建、本地化、更新配置和签名检查；后者用隔离应用验收安装、重启及篡改拒绝。若开发时配置了 `PHOTO_BROWSER_BUILD_PATH`，后续命令保持一致。Camera Raw SDK 的显式缓存路径通过 `PHOTO_CAMERA_RAW_SDK` 传入；缓存或权限失败就报告，不能静默换配置。
2. 按项目提交规则完成暂存、提交、任务分支备份、worktree 合并及同名主分支推送。已有 `ship`、`worktree` 技能时复用各自流程；否则按项目规则完成这些步骤。主仓脏、pull 无法 fast-forward、冲突或检查失败时先处理原因；不 force、不跳过 hook、不覆盖已有版本目录或标签。
3. 确认发布源码与产物一致，再创建与配置一致的标签并推送。用 `gh release create --verify-tag --draft` 上传**同一批** ZIP、SHA-256 文件和已签名 `appcast.xml`。命令模板见发布文档；不要修改签名后的 XML。
4. 找到**本次提交 SHA** 对应的 CI，等其通过。核对草稿版本、三个附件、大小、签名和发布说明；在已有发布授权内执行 `gh release edit vVERSION --draft=false --latest`。预发布版本不设 latest。
5. 验证公开产物和 latest 更新源：

   ```bash
   bash .claude/skills/photo-browser-release/scripts/verify-public-release.sh
   ```

   脚本仅下载和校验，版本与签名账户来自配置；`PHOTO_BROWSER_BUILD_PATH` 可指定 Sparkle 工具缓存，`PHOTO_RELEASE_VERIFY_DIR` 可指定证据父目录。每次验证创建独立子目录，保留失败证据。失败后按实际原因处理，不无限重试或把失败当成功。

## 本机安装与编辑会话

- 从运行进程和实际安装目录确认目标应用，别假设总在 `/Applications`。复制旧版到 `.build/deployment-backups/`，以旧版本和 Build 命名；不覆盖备份。先在目标目录所在卷准备新版临时 `.app`，核对版本、Build、完整签名及主程序／宿主的 `arm64 x86_64` 架构。
- Camera Raw 是独立宿主，可能在主程序退出后继续编辑。**不结束该会话。**宿主在编辑时，先用 `diff -qr` 确认旧版与临时新版的完整 `Contents/Helpers/CameraRawHost.app` 字节一致；有差异则保留主程序和编辑会话，延后本机替换，继续完成已授权的公开发布并明确本机状态。
- 先检查运行状态，再正常退出**目标路径**的主程序：

  ```bash
  swift .claude/skills/photo-browser-release/scripts/quit-app.swift --check-only "$PHOTO_INSTALLED_APP"
  swift .claude/skills/photo-browser-release/scripts/quit-app.swift "$PHOTO_INSTALLED_APP" 45
  ```

  脚本按 bundle 路径匹配，退出完成以 PID 是否存在判断，避免只依赖可能滞后的 `NSRunningApplication.isTerminated`。超时返回非零，保留文件，先检查实际进程和文件操作；不强杀、不把超时写成应用崩溃。
- 旧程序退出且宿主条件满足后，把旧应用移动到保留位置，再把同卷临时应用移至安装路径，核验并启动。第二次移动失败时把旧应用移回；不删除唯一备份。部署重试先核对已存在的临时包、备份和进程，从上次停下的步骤续做，不能盲目重跑整串命令。
- 在删除任务 worktree 前，将发布包、应用、必要日志和备份放到稳定目录；确认没有进程仍从该 worktree 加载文件，再清理 worktree 和已合并的本地分支。

## 旧版更新验收与缓存排查

公开下载验签之外，用真实 Sparkle 检查确认上一版能发现新 Build；不要把“发现更新”描述成“已真实安装”。真实安装、重启由隔离安装检查覆盖。

- 在 `.build/` 复制上一版应用，保留它的版本、Build、更新源和公钥；改成唯一的 `local.wxj.PhotoBrowser.ReleaseChecks.UUID` bundle ID，关闭自动检查，用本次检查构建的 `UpdaterChecks` 替换其可执行文件并重签名。构建方式见 `scripts/check-updates.sh`；不要使用不明来源的旧检查二进制。
- 运行该临时应用的 `Contents/MacOS/PhotoBrowser --probe --expect found --result /absolute/path/result`，设有限超时，并从日志确认发现的是目标 Build。该模式在发现更新时退出，不安装、不触碰真实用户偏好。记录版本和结果，结束后只清理本次唯一测试 ID 的偏好和缓存。
- 若公开 XML 已是新 Build，旧版仍返回“已是最新版”，先保留日志，打印 `showUpdateNotFoundWithError` 的 NSError/userInfo 及找到的 appcast 版本，核对实际 FeedURL、主机版本与响应。需要诊断改动时复制测试源码到 `.build/`，不改发布产物。
- 曾遇到旧版探针拿到上一版更新源：在探针结束后，把**该唯一测试 ID** 的 `~/Library/Caches/ID` 移到证据目录，重新用同一生产 FeedURL 验收一次。不得清生产应用缓存、偏好或照片，不用加查询参数的替代地址冒充生产地址验收。一次隔离重验仍失败时继续查实际网络／版本原因，不反复清缓存碰运气。

## 完成回执

重新读取并报告：版本和 Build、提交 SHA、main 与远端差异、工作区和 worktree 状态、CI、Release 是否为稳定 latest、三个公开附件的校验、本机实际运行路径与版本、备份位置、旧版发现新 Build 的结果，以及 Camera Raw 会话是否保留。公开发布与本机安装分开报告，任何未完成步骤都明确列出。

本技能真源位于 `.claude/skills/photo-browser-release`，项目 Codex 入口 `.agents/skills/photo-browser-release` 是指向真源的相对软链接。参见 [官方技能目录规则](https://learn.chatgpt.com/docs/build-skills)。
