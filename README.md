# Photo Browser

[简体中文](README.zh-CN.md) · English

A native macOS photo browser for reviewing and organizing camera photos. Matching RAW, HIF, and JPG files appear as one capture. Review panorama candidates as groups, then move every format and its XMP sidecars into a new folder with undo and recovery.

## Download

Download the universal macOS app from [Releases](https://github.com/985860612/photo-browser/releases). It supports **macOS 14 or later**, on Apple Silicon and Intel Macs. Unzip it and move the app to Applications.

The app is called **Photo Browser** in English and **照片浏览器** in Simplified Chinese. The interface follows your macOS preferred language; other languages fall back to English. In macOS System Settings → General → Language & Region → Applications, you can select a language for this app, then reopen it.

Release builds are ad-hoc signed, without Apple notarization. If macOS blocks the downloaded app, use System Settings → Privacy & Security → Open Anyway after verifying that you downloaded it from this repository. You can also build it from source.

## Screenshots

Examples from the Simplified Chinese interface. English is also supported.

**Large photo preview and folder filmstrip**

![Large photo preview with RAW/HIF format selection, capture settings, and a folder filmstrip](docs/screenshots/photo-preview.png)

**Photo grid and panorama group information**

![Photo grid with folder covers, panorama groups, capture counts, and file sizes](docs/screenshots/grid-and-groups.png)

## Features

- **One capture, multiple formats:** pair matching RAW/HIF/JPG/AVIF files and XMP sidecars. AVIF supports thumbnails, large previews, fullscreen originals, and HDR through the same color-managed display path. Choose a format in the inspector, or enable Prefer RAW for large previews.
- **Fast browsing:** background thumbnails, decoded large-image caching, and adjacent-photo preloading. In Settings (⌘,), configure previous/next counts, defaulting to 2 previous and 5 next; 0 disables a direction. Preloading starts alongside the current photo and preserves overlapping work during navigation; fullscreen preloads native pixels. Decoded-cache capacity follows 1/16 of physical RAM, bounded to 128 MiB–4 GiB, and preserves HDR precision. Under memory pressure, the current photo and closer neighbors take priority. Drag panel dividers or the filmstrip divider to resize them; widths, filmstrip height, panel visibility, and window frame are saved between launches.
- **Full-resolution preview:** press Space for fullscreen. A cached browsing preview or thumbnail appears while the original loads. Pinch to zoom; scroll or drag to pan. Fit to Screen and 100% Pixels let you inspect detail.
- **HDR and color management:** Core Image and Metal render into a floating-point surface with EDR. Supported HLG, PQ, and gain-map images use the display's available range. SDR images stay SDR; a 10-bit HIF is not necessarily HDR.
- **Panorama groups:** automatic candidates from capture time, burst sequence, and focal length; manual grouping, splitting, merging, renaming, and dissolving.
- **Recoverable moves:** review the destination and full file list before moving a group. All formats and sidecars move together. Move History supports undo and interrupted-operation recovery.
- **Folder navigation:** clickable breadcrumbs, a path field, history, parent navigation, and subfolder cards. Single-click selects a card; double-click opens it. Folder and photo-info panels can be collapsed independently.
- **Folder caching:** cover fingerprints, photo counts and recursive file sizes persist locally. Folder cards show saved results first, then validate in the background. Directory checks are throttled to five minutes, sizes expire after six hours, and moves/deletion/undo invalidate affected folders and ancestors. ⌘R forces a refresh; cached timestamps and update failures appear in the card tooltip. The first visit calculates any missing entries.
- **Camera Raw:** open the preferred RAW or a specific format in Camera Raw hosted by Adobe Bridge. Bridge and an enabled Camera Raw plug-in must be installed separately. This entry selects the photo in Bridge and invokes Open in Camera Raw without launching Photoshop. Format and camera support depend on the installed Camera Raw version; failures are reported.
- **English and Simplified Chinese:** menus, buttons, tooltips, status text, dialogs, capture settings, and application error messages are localized.

## Getting started

1. Open a photo folder with **⌘O**. The app scans only the current folder. Matching filenames are paired without reading every original image.
2. Select photos in the grid or filmstrip. **Command-click** toggles selection; **Shift-click** selects a range. **Shift + Left/Right** extends or shrinks the range from its anchor.
3. **⌘G** groups the selection. Auto Group reads metadata and proposes candidate groups. Review the actual image overlap before treating them as panorama material.
4. Right-click a group to rename it or choose **Move Group to New Folder…**. Choose a destination, review the file list, and confirm the move. The destination must be a new folder.
5. Use **Move History** to undo a completed move or recover an interrupted one. Filename conflicts, changed files, and missing files stop the operation instead of overwriting data.

Automatic grouping requires [ExifTool](https://exiftool.org/):

```bash
brew install exiftool
```

Burst frames join a candidate when sequence numbers increase, focal length matches, and the gap is at most 8 seconds. Non-burst shots can join within 5 seconds at the same focal length. Candidates need at least 3 captures. The algorithm does not match image features or validate stitching; repeated compositions may be grouped. The first metadata read from a NAS can take several minutes and can be canceled while browsing.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘O | Open photo folder |
| ⌘R | Refresh folder |
| ⌘L | Type or paste a folder path |
| ⌘[ / ⌘] | Back / forward |
| ⌘↑ | Parent folder |
| ← / → | Previous / next photo or folder card |
| ⇧← / ⇧→ | Extend or shrink photo selection |
| ⌫ (Backspace) / Delete | Move selected photos and all paired formats/XMP to `_del` |
| Return | Open the selected folder |
| Space / Esc | Enter / exit fullscreen preview |
| ⌘J | Toggle grid / large preview |
| ⌘G | Group selected photos |
| ⌘⇧F | Show current photo in Finder |

## Data and rendering

Groups and move records are stored in `~/Library/Application Support/PhotoBrowser/`; thumbnails are cached in `~/Library/Caches/PhotoBrowser/`. Browsing and grouping do not write to the original photos. A confirmed move or the deletion shortcut changes their location. File moves happen individually, with records written before the first move; they are not one atomic filesystem transaction. Keep Move History until recovery is complete.

On an Apple keyboard, press **⌫ (Backspace)** to move selected captures, including RAW, HIF/JPG, and XMP files, into `_del` in the current folder. Forward Delete (Fn + ⌫) also works. Consecutive deletions reuse this folder. Nothing is permanently erased; Move History restores the files and their group memberships. A filename conflict stops the entire batch before moving files. While typing in a text field, ⌫ deletes text as usual. Holding the key does not delete successive photos, and folder cards cannot be deleted with this shortcut.

Existing groups and Chinese CSV lists remain readable. A list at `全景素材筛选/全景候选文件清单.csv` can be imported on first access. The legacy columns are `组号`, `文件名`, and optionally `分类` and `判断依据`. Saved group names, folder names, and user descriptions are preserved when the interface language changes.

Normal RAW thumbnails use embedded JPEG previews. Fullscreen RAW uses macOS original-image decoding; the result can differ from Camera Raw development. Format and camera support depend on macOS and the installed Camera Raw version. HDR brightness also depends on the display's EDR capability. See [Apple HDR image support](https://developer.apple.com/videos/play/wwdc2023/10181/) and [Core Image / Metal EDR rendering](https://developer.apple.com/videos/play/wwdc2022/10114/).

## Build

Requires macOS 14+, a Swift 6 toolchain, and Apple Command Line Tools or Xcode. The project uses SwiftUI, AppKit, ImageIO, Core Image, and Metal; there are no third-party Swift package dependencies.

```bash
git clone https://github.com/985860612/photo-browser.git
cd photo-browser
bash scripts/build-app.sh
open 'dist/照片浏览器.app'
```

To build a universal Apple Silicon + Intel app:

```bash
PHOTO_BROWSER_UNIVERSAL=1 bash scripts/build-app.sh
```

## Checks

```bash
swift run BrowserCoreChecks
swift run BrowserHDRChecks
swift run BrowserThumbnailChecks
bash scripts/check-preview-store.sh
bash scripts/check-localization.sh 'dist/照片浏览器.app'
```

Localization checks run in separate English and Chinese processes, verify catalog coverage and interpolated names/counts/paths, and check the packaged app's resource loading. Core move checks use temporary fixtures to verify all-format moves, undo, collisions, partial failures, journal failures, and crash recovery.

For a read-only check against your own photos:

```bash
swift run BrowserSmokeChecks '/path/to/photos' PHOTO_BASENAME ANOTHER_BASENAME
```

## License

[MIT](LICENSE). Copyright © 2026 wangxiaojie.
