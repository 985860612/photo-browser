# 自动更新与发布

应用使用 Sparkle 2.10.0。正式更新源为 GitHub 最新稳定 Release 的 `appcast.xml` 附件：

`https://github.com/985860612/photo-browser/releases/latest/download/appcast.xml`

默认启用启动检查和每 24 小时检查，默认不自动下载。用户可以在设置中开启后台下载、退出时安装，也可从更新提示立即安装并重启。Sparkle 保存检查开关、自动安装开关、跳过版本和上次检查时间。应用仅在 `.app` 中启用更新；文件移动、删除与视频导出期间延迟安装重启，退出保护同步覆盖这些操作。

## 版本与密钥

`scripts/app-settings.plist` 是版本、构建号、更新源、公钥和钥匙串账户的配置源。每次发布同时增加 `Version` 和整数 `Build`；Sparkle 用 `Build`（`CFBundleVersion`）判断更新先后，不使用 Git 标签比较。

签名私钥仅存于本机登录钥匙串，Sparkle 账户为 `local.wxj.PhotoBrowser`。仓库只保存公钥。不要重新生成或更换公钥：当前临时签名发行方式无法依靠 Developer ID 身份恢复丢失的 Ed25519 密钥。迁移发布机器时使用 Sparkle 的 `generate_keys` 工具，通过安全方式导出和导入私钥；不要将私钥提交或上传为 Release 附件。公钥可通过以下只读命令核对：

```bash
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account local.wxj.PhotoBrowser -p
```

应用在解压前验证更新包签名，并强制验证更新源签名。改动已签名的 XML 或更新包会导致拒绝更新；修改后必须重新生成签名。正式源及下载地址使用 HTTPS。

## 准备发布包（不推送、不发布）

1. 修改 `scripts/app-settings.plist` 中的版本和构建号。
2. 执行项目检查和真实安装检查。安装检查使用临时密钥、临时应用、独立偏好域和 localhost 服务，不更新已安装的照片浏览器。
3. 准备 Markdown 发布说明，然后运行以下命令（说明文件可省略）：

```bash
swift run BrowserCoreChecks
bash scripts/check-preview-store.sh
swift run BrowserThumbnailChecks
swift run BrowserHDRChecks
PHOTO_BROWSER_UNIVERSAL=1 bash scripts/build-app.sh
bash scripts/check-localization.sh 'dist/照片浏览器.app'
bash scripts/check-update-installation.sh 'dist/照片浏览器.app'
bash scripts/prepare-update.sh /absolute/path/release-notes.md
```

真实安装检查需要 `uv` 来运行本地测试 HTTP 服务。`prepare-update.sh` 从钥匙串取签名，构建 Apple Silicon + Intel 通用应用，检查资源与更新配置，然后生成签名更新源、ZIP 及 SHA-256 校验文件到 `dist/releases/v<版本>/`。如相同目录已存在则报错，先移走旧结果再重新生成，避免误覆盖已核对的产物。可通过 `PHOTO_BROWSER_BUILD_PATH` 指定构建缓存目录。

## 发布已确认的产物

完成审阅并获得发布授权后，将代码提交和推送到对应发布提交，再创建与配置一致的版本标签。用下列命令创建草稿 Release，核对后在 GitHub 发布，并将它设为最新稳定版本：

```bash
gh release create v<版本> --verify-tag --draft \
  --title '照片浏览器 v<版本> / Photo Browser v<版本>' \
  --notes-file /absolute/path/release-notes.md \
  dist/releases/v<版本>/*.zip \
  dist/releases/v<版本>/*.sha256 \
  dist/releases/v<版本>/appcast.xml
```

`--verify-tag` 要求远端已存在该标签，避免把旧远端代码误当成发布源码。每一个最新稳定 Release 必须同时包含这三个附件；不要先发布仅有 ZIP 的稳定版本，否则更新源会暂时失效。发布包名称和 URL 由 `prepare-update.sh` 生成，签名后不要改 XML。预发布版本不要设为最新稳定版。发布后从线上 URL 下载更新源与 ZIP，核验签名，并从上一版进行一次更新验收。

CI 仅构建与运行隔离测试，不持有正式私钥，不自动发布。当前应用仍采用临时代码签名、未公证；Sparkle 的更新签名不能替代首次安装时的 Apple 公证。v0.4.11 及更早版本需手动安装一次含 Sparkle 的版本，之后才能应用内更新。
