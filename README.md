# Photo Browser

[简体中文](README.zh-CN.md) · English

A native macOS photo browser for reviewing and organizing camera photos. Matching RAW, HIF, and JPG files appear as one capture. Review panorama candidates as groups, then move every format and its XMP sidecars into a new folder with undo and recovery.

## Download

Download the universal macOS app from [Releases](https://github.com/985860612/photo-browser/releases). It supports **macOS 14 or later**, on Apple Silicon and Intel Macs. Unzip it and move the app to Applications.

The app is called **Photo Browser** in English and **照片浏览器** in Simplified Chinese. The interface follows your macOS preferred language; other languages fall back to English. In macOS System Settings → General → Language & Region → Applications, you can select a language for this app, then reopen it.

Release builds are ad-hoc signed, without Apple notarization. If macOS blocks the downloaded app, use System Settings → Privacy & Security → Open Anyway after verifying that you downloaded it from this repository. You can also build it from source.

Starting with v0.4.12, the app checks for updates at launch and every 24 hours. Use **Photo Browser → Check for Updates…** to check manually. In Settings → Software Update you can disable checks or opt into automatic downloads and installation on quit. Update prompts support installing and relaunching immediately, skipping a version, or being reminded later. Restart waits for ongoing file moves, deletions and video exports. Updates and their feed are verified with Ed25519 signatures. Versions through v0.4.11 need one manual upgrade to gain the updater; `swift run` does not enable updates. See [release instructions](docs/updates.md).

## Screenshots

Examples from the Simplified Chinese interface. English is also supported.

**Large photo preview and folder filmstrip**

![Large photo preview with RAW/HIF format selection, capture settings, and a folder filmstrip](docs/screenshots/photo-preview.png)

**Photo grid and panorama group information**

![Photo grid with folder covers, panorama groups, capture counts, and file sizes](docs/screenshots/grid-and-groups.png)

## Features

- **One capture, multiple formats:** pair matching RAW/HIF/JPG/AVIF files and XMP sidecars. AVIF supports thumbnails, large previews, fullscreen originals, and HDR through the same color-managed display path. Choose a format in the inspector, or enable Prefer RAW for large previews.
- **Fast browsing:** background thumbnails, decoded large-image caching, and adjacent-photo preloading. In Settings (⌘,), configure previous/next counts, defaulting to 2 previous and 5 next; 0 disables a direction. Background large-image decoding defaults to 4 parallel workers, configurable from 1 to 8. Changes apply immediately and persist across launches; running decodes finish normally, and two foreground workers remain available independently. Preloading starts alongside the current photo and preserves overlapping work during navigation; fullscreen preloads native pixels. Decoded-cache capacity follows 1/16 of physical RAM, bounded to 128 MiB–4 GiB, and preserves HDR precision. Under memory pressure, the current photo and closer neighbors take priority. Drag panel dividers or the filmstrip divider to resize them; widths, filmstrip height, panel visibility, and window frame are saved between launches.
- **Full-resolution preview:** press Space for fullscreen. A cached browsing preview or thumbnail appears while the original loads. Pinch to zoom; scroll or drag to pan. Fit to Screen and 100% Pixels let you inspect detail.
- **HDR and color management:** Core Image and Metal render into a floating-point surface with EDR. Supported HLG, PQ, and gain-map images use the display's available range. SDR images stay SDR; a 10-bit HIF is not necessarily HDR.
- **Panorama groups:** automatic candidates from capture time, burst sequence, and focal length; manual grouping, splitting, merging, renaming, and dissolving.
- **Recoverable moves:** review the destination and full file list before moving a group. All formats and sidecars move together. Move History supports undo and interrupted-operation recovery.
- **Folder navigation:** clickable breadcrumbs, a path field, history, parent navigation, and subfolder cards. Single-click selects a card; double-click opens it. Folder and photo-info panels can be collapsed independently.
- **Folder caching:** cover fingerprints, photo counts and recursive file sizes persist locally. Folder cards show saved results first, then validate in the background. Directory checks are throttled to five minutes, sizes expire after six hours, and moves/deletion/undo invalidate affected folders and ancestors. ⌘R forces a refresh; cached timestamps and update failures appear in the card tooltip. The first visit calculates any missing entries.
- **Camera Raw:** open the preferred RAW or a specific format in Camera Raw hosted by Adobe Bridge. Bridge and an enabled Camera Raw plug-in must be installed separately. This entry selects the photo in Bridge and invokes Open in Camera Raw without launching Photoshop. Format and camera support depend on the installed Camera Raw version; failures are reported.
- **Video playback:** MP4, MOV, and M4V appear as independent items alongside photos, with cached covers and duration badges. Double-click to play in the main preview; use Space to play/pause, the player controls to seek and change volume, and Control-Command-F for fullscreen. Switching items stops the previous video. The inspector shows duration, resolution, frame rate, and file size. Playback depends on macOS codec support, and unsupported files show an error. Videos support copying files and reversible moves to `_del`; they are excluded from automatic panorama grouping.
- **Browsing diagnostics:** the status bar shows how many neighboring photo previews are actually resident. Settings shows memory use, foreground cache hits, and queue/source-open/decode/GPU-completion durations, with the latest 100 requests retained for this session. Decoding can include file I/O; the figures do not claim to separate all disk reads from decoder work.
- **Cache management:** Settings shows local thumbnail/video-cover storage and a configurable 1–20 GB quota (default 2 GB). Local usage is indexed once, updated as files are written or removed, and reconciled every five minutes when queried. Maintenance sorts entries only when over quota; access history is flushed at most every 30 seconds during maintenance and immediately at quit. Eviction follows recent access, including across launches. Clear Preview Cache releases decoded RAM and removes local thumbnails/covers; the displayed image/player, original files, groups, move history, folder indexes, and playback positions are retained. Background warming stops after clearing; thumbnails regenerate on demand.
- **Video continuity:** playback position, volume, and mute survive switching and reopening. Restoring a video leaves it paused unless explicitly played; completed or replaced videos start at the beginning. Neighbor preparation loads bounded video information without starting a second player.
- **External edits:** directory/file events update the current view without resetting selection, search, or existing groups. Every three seconds, lightweight checks inspect the directory timestamp and focused files; there are no periodic full scans. Events, detected changes, reactivating the app, and ⌘R can request a full scan. Changed image/XMP families invalidate previews. Native RAW decoding still does not apply Camera Raw's XMP development instructions.
- **Clipboard:** Command-C copies selected files and their paired formats/sidecars for pasting in Finder. Command-Shift-C copies a full-resolution still image for pasting into messages or documents. Right-click menus provide both actions; video copying uses the file action.
- **English and Simplified Chinese:** menus, buttons, tooltips, status text, dialogs, capture settings, and application error messages are localized.

- **Photo location:** GPS-enabled photos show latitude, longitude, and available altitude in the inspector. Open in Maps locates the photo in Apple Maps using the embedded coordinates. Missing or invalid GPS hides the location section; the app does not infer positions from filenames or camera models. Old source-header caches are enriched once without regenerating thumbnail JPEGs, and missing GPS results are cached too. Browsing does not launch Maps; the button uses Apple's [MapKit Maps launcher](https://developer.apple.com/documentation/mapkit/mkmapitem/openinmaps%28launchoptions%3A%29).

Thumbnail warming runs at most two background requests concurrently, with two independent foreground workers. Visible requests promote queued shared work; changing folders cancels the old batch. Progress refreshes at most twice per second and immediately on completion. Maintenance passes are separated by at least two seconds, and maintenance sorting/encoding does not block RAM cache hits.

Nearby thumbnail requests use a separate priority queue instead of repeatedly scanning/rebuilding the remaining library. Queue indexing and dequeueing run on a separate actor. Card appearances coalesce over 100 ms using the latest neighborhood; older priority results cannot overwrite newer requests. Photo positions are indexed once per visible order and invalidated when sorting, groups, search, or assets change. The lazy grid retains existing selection, navigation, and context menus.

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

## Culling assistant

Switch the toolbar to **Cull**, then choose **Start Analysis** to analyze the current folder, filter/group, or selected photos. Apple Vision runs locally for image similarity, face capture quality, and content labels. macOS 15+ also provides overall aesthetics scores and utility-image detection. Apple Intelligence does not need to be enabled, and photos are not uploaded. Videos are skipped; Live Photos use their still image. Analysis uses a consistent preview size independently of the viewer's RAW preference.

- The sidebar filters unreviewed, kept, undecided, rejected, similar, suggested, and review-needed photos. Individual similarity groups and recognized content labels are also available. Existing panorama/manual groups are excluded from automatic similarity grouping but can still be marked individually.
- Use single-image, grid, or side-by-side views. **Set as Reference** pins the left photo while selection changes the right. Zoom and pan can be synchronized. **100% Pixels** loads originals and calculates each pane's pixel scale independently; **Inspect Subject** locates a face or salient region. Both commands disable synchronization for independent inspection. Narrow windows hide the inspector while keeping marking controls available below the images.
- `P` keeps, `M` marks undecided, `X` rejects, `U` clears, and `⌘Z` undoes a decision or similarity-group edit. Multiple selection supports batch marking. Single-photo marking advances by default; disable this in the inspector. Text editing keeps these keys. The existing Delete shortcut still moves files to `_del`.
- The inspector switches between culling and existing photo information. Overall scores are presented as relative group rankings, and face capture scores are intended for consecutive photos of the same person. A low overall score is not presented as a separate diagnosis of blur, bad exposure, or closed eyes. Content labels retain Vision's identifiers.
- Remove photos from a similarity group, split at the current photo, or form a manual similarity group from a selection. Human grouping edits and decisions survive reanalysis. Adjust similarity strictness in the analysis sheet. Automatic grouping compares each candidate against group anchors within a bounded 32-photo neighborhood and, where known, a 90-second capture window. It is not whole-library deduplication or panorama validation.
- Pause analysis and start again to reuse results with matching file fingerprints and settings, continue unfinished work, and retry failures. Changing folders or source files stops obsolete tasks. Read errors remain visible rather than becoming low scores.
- **Review Results…** lists manually rejected photos across the current folder, including all paired formats and XMP files. Files move to `_del` only after confirmation, with undo available in Move History. Changes to source files preserve decisions but require reconfirmation before using this cleanup list.

Human decisions live in `~/Library/Application Support/PhotoBrowser/Culling/<folder-id>/decisions.json`; replaceable per-photo analysis lives in its sibling `Analysis/` directory. Identical names in different folders do not share decisions. Clearing preview caches preserves culling records. A failure to restore or save human records is reported and never replaces them with empty records; damaged machine caches can be regenerated. Natural-language culling is outside this version's scope.

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
swift run BrowserCullingChecks
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

Optional culling UI renders: `bash scripts/check-culling-ui.sh -AppleLanguages '(en)'`. This uses temporary generated photos and isolated settings, runs real Vision analysis, then renders comparison, grid, narrow-window, and two sheet layouts to `dist/culling-preview/`. It is not run in headless CI. Default snapshots read only this application's own views and may omit system materials and Metal layers; the actual comparison panes receive separate Metal pixel checks. Optional `--window-capture` captures the complete window and requires Screen Recording permission. Permission failures stop the check with an error.

## Code organization

`BrowserCore` owns media data and reusable services; `PhotoBrowser` owns application state and views.

| Directory | Responsibility |
| --- | --- |
| `Sources/BrowserCore/Library` | Media pairing, grouping, ordering, source fingerprints, and saved sessions |
| `Sources/CullingCore` | Vision photo analysis, similarity grouping, and independent culling persistence |
| `Sources/PhotoBrowser/Culling` | Culling state, analysis tasks, comparison UI, and human decisions |
| `Sources/BrowserCore/Media` | Image decoding, native metadata, and video cover generation |
| `Sources/BrowserCore/Caching` | Memory/disk caches, access policy, and invalidation |
| `Sources/BrowserCore/FileOperations` | Recoverable moves and validated permanent deletion |
| `Sources/BrowserCore/Support` | Localization, preferences, layout calculations, queues, and diagnostics |
| `Sources/PhotoBrowser/Browsing` | One browser state owner, directory observation, selection, and sorting integration |
| `Sources/PhotoBrowser/Previews` | Warming task ownership, progressive presentation, and Metal rendering |
| `Sources/PhotoBrowser/Actions` | Group, clipboard, Camera Raw, and file-operation commands |
| `Sources/PhotoBrowser/Playback` | Video player state and playback commands |
| `Sources/PhotoBrowser/Views` | Layout, reusable view components, inspector, and sheets |

`BrowserStore` remains the source of truth for the current library, groups, selection, and focus. Its action extensions coordinate that state; they do not own a second copy. `PreviewCoordinator` and `CaptureDateLoader` own their tasks, cancellation, and progress. Their change notifications reach the browser through subscriptions, with progress read directly from each owner.

Keep filesystem work in services and pixel work on bounded worker queues. The core module never imports the application. Saved session paths and JSON fields remain compatible with previous builds; clearing image caches does not clear manual groups or move records. Integration checks compile the controller folders and use separate files for sorting, navigation, prefetch, deletion, and task ownership.

New features should have a clear state owner and dedicated views/tests. Review files around 500 lines for mixed responsibilities; split by responsibility rather than creating arbitrary line-count fragments. Future photo analysis should use a separate target and feature store, feeding explicit preview/move commands into the existing browser instead of expanding `BrowserStore` with detector state.

## License

[MIT](LICENSE). Copyright © 2026 wangxiaojie.

## Network photo reads and Live Photos

Network JPEGs up to 32 MiB are read sequentially into a bounded buffer before ImageIO decoding; larger files and other codecs retain native URL decoding. Thumbnail resolution and original metadata are preserved. The decoder creates a Core Image context only when a RAW embedded preview needs rotation. Directory monitoring no longer performs a full scan on a 30-second timer: lightweight checks detect directory/current-file changes, while filesystem events, activation, and manual refresh reconcile the contents. Initial generation still needs to read each uncached original over the network.

LIVP archives appear as one photo with a Live Photo badge. Browsing extracts only the original still image, preserving orientation, HDR data, and available GPS metadata. Selecting a single LIVP opens its preview and automatically plays the motion video; arrow-key navigation does the same. Multi-selection does not start playback. Motion completion automatically returns to the still photo, including in fullscreen. Return to Photo stops playback, and Play Live Photo in the toolbar or context menu starts it again. Copy, move, and delete act on the original archive. Original members are cached locally with a 1 GB budget; videos load on demand and active playback is protected during cache clearing. Invalid or ambiguous archives and files exceeding the member/cache limits report an error. Playback depends on macOS codec support.
