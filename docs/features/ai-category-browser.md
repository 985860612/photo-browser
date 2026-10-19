# AI category browsing

The window starts in **Folders**. Use the segmented switch in the window toolbar to enter **AI Categories** and browse a flat photo wall within the chosen folder and all its subfolders. Both modes share this switch without an extra content row; full-screen previews hide it. The first scope is the current directory; later visits restore the AI scope and filters independently of folder navigation.

Scene, subject and environment are expanded initially. Labels come directly from the recognition protocol, dictionary and observed terms. Multiple selections within one field mean **OR**; different fields and whitespace-separated search words mean **AND**. Facet counts include other fields' constraints and omit their own field's selections. Each field initially shows its ten most frequent labels; expand or search the field for others. Selected chips can always be removed, including when a combination has no results.

Recognized, pending and error states are separate. Pending photos can be searched by filename or directory. Returning to recognized photos restores tag selections. Cards show an AI title, source directory relative to the scope, and grouped formats. Capture time determines order; file modification time is the fallback.

Click a photo to inspect cached AI information, double-click for a large preview, and press Space for a full resolution preview. Arrow keys navigate the current results. **Show in Folder** opens the original parent directory and selects its format family. Returning to AI categories retains browsing state. Completed scopes reopen directly from the local index; use Refresh to check source-file or external batch changes. Native generation in this app updates the index immediately. Copy/Finder and single-photo AI generation remain available; grouping, moving, Camera Raw edits and deletion are disabled in this mode. Select All applies to **loaded** photos and is labeled accordingly. AI generation uses the existing model settings and 720-pixel input preparation.

Folders have **Exclude from AI Album** / **Include in AI Album** context actions. Exclusions cover the folder and all descendants across every AI scope, including search, paging, state totals and facets. Inherited exclusions are labeled and must be removed at the parent folder. Explicit child exclusions remain when a parent is included again. The folder icon shows an exclusion mark; normal folder browsing and original metadata remain available. Rules are saved separately in application preferences (`aiBrowseExcludedDirectories`), so rebuilding the derived index preserves them. Including a folder again uses cached results immediately, without reimport or model requests.

## Image-vector similarity

**Find Similar Photos** adds a removable **Similar to: …** chip to the current photo wall. There is no separate similarity sheet. Scope, exclusions, recognition state, text and tag filters constrain candidates before vector ranking. While the chip is active, results use similarity order and the capture-time sort control is replaced by a similarity indicator. Clear the chip to restore ordinary sorting; the original loaded position and selection are restored when the other filters are unchanged.

The wall loads 60 photos at a time from one nearest-500 ranking. Pagination never recomputes distances. Reference changes, filters and catalog/vector revisions invalidate the ranking. The source photo is omitted. Facets and counts describe eligible vector-bearing candidates, including candidates outside the nearest 500. Browsing only reads existing vectors; use Background Tasks to generate missing vectors. A missing reference vector reports a visible error rather than reading original images or automatically starting a library job.

Apple Vision feature-print revision 2 produces 768 Float32 elements on macOS 14+. The model identifier fixes crop/scale and storage conventions. Source changes invalidate vectors; metadata-only edits preserve their exact database snapshot, including fractional timestamp round-trip compatibility. Similarity uses L2 image-vector distance, rather than tags or a confidence percentage.

## Background tasks

The window toolbar's **Background Tasks** button is shared by folder and AI-category browsing. It opens an independent task window with **Tasks** and **Recognition Results** pages. Create jobs for a folder or selected photos, choose AI recognition, image vectors, or both, and review actual pending counts before starting. Default processing fills missing results; explicit regeneration keeps the last good result until a replacement succeeds. Folder scans are explicit and never start recognition on their own.

The app owns all jobs, including single-photo AI generation. Changing photos, switching modes or closing the task window does not cancel them. Pause stops new dispatch and drains in-flight work; Cancel stops remaining work and preserves saved results. On application exit, checkpoints are saved and unfinished requests are cancelled. Restarted jobs remain paused until manually resumed. A saved AI analysis carries a task-item token so resuming after a crash between the response save and queue checkpoint does not resend it.

Global AI concurrency defaults to 8 (adjustable 1–32), vector concurrency to 2 (1–4), and thumbnail preparation to 2. Overlapping tasks reuse matching work. Existing local previews and exact thumbnail-cache keys are preferred. Missing previews are generated from originals at a 720-pixel maximum edge. AI and vectors share the prepared preview but succeed/fail independently. Only AI calls the configured model, with the saved prompt and model settings and thinking disabled by default. Credentials remain in Keychain.

Tasks show completed/reused/failed counts, separate AI and vector totals, throughput, estimated remaining time and errors. Results are paginated and independently filterable by AI/vector state. Selecting a photo shows its description, labels, vector model and, for newly generated vectors, timestamp. **Find Similar Photos** returns to the main wall with the photo as reference. Thumbnail failures are shown separately as waiting for a thumbnail. Unavailable storage pauses affected preparation; authentication errors pause AI while vectors continue. Transient network/HTTP 429/5xx failures retry at most twice and honor Retry-After; malformed output does not automatically resend.

Task records are additive SQLite tables in the existing local catalog. Photos, model credentials, historical batch queues and existing successful results are not rewritten by creating a job. No automatic full-library paid run is started by opening either browsing mode or the task window.

## Local derived index

`~/Library/Application Support/PhotoBrowser/AIBrowse/catalog-v1.sqlite` is a rebuildable local SQLite index. It contains normalized photos, field terms, memberships, source stamps and folder-scope inventories. WAL allows independent, cancellable read connections while imports commit batches. Pages contain 60 items and use capture-time/row-ID cursors rather than offsets. Lists, summaries and facets are separate requests. Facet results are cached by scope revision and canonical filter parameters.

Import precedence is native generated analyses, local V2 batches, then NAS V2 metadata. Existing recognition parsers and the current-analysis pointer remain authoritative. Neither browsing nor indexing calls a model. Original metadata records, queues and photos are read-only. The task checkpoint updates the derived index after an atomic native save; a failed generation retains the old result.

Unchanged metadata is recognized from file size/mtime plus format/dictionary stamps, without reopening its JSON. The inventory visits at most two source folders concurrently, reads directory entries and file attributes, and does not decode originals or read EXIF. Previously identified photos without normal filename extensions retain their original names and metadata-sourced type hints; neither probing nor renaming originals is required. Show in Folder carries these hints into normal browsing and folder observation. File family identity includes the standardized parent path and original asset stem, while the underlying `PhotoAsset.id` remains unchanged. Changed image snapshots become pending; a successful complete inventory removes vanished members. An interrupted/unavailable inventory preserves cached memberships, reports the error, and leaves the scope incomplete.

Videos, PSD/PSB, hidden entries, `_del`, NAS thumbnails, QNAP `@Recently-Snapshot` history and recycle folders are excluded. Directory symlinks are not traversed. Local batch previews are preferred; only visible cards request thumbnails. Cached information remains browsable when the source is unavailable; opening an unavailable original reports a preview error.

## Checks

- `bash scripts/check-ai-catalog.sh`: isolated query/import/inventory and UI-state checks. Does not contact a model or require a NAS.
- `bash scripts/check-preview-store.sh`: existing folder, navigation and preview regression suite.
- `bash scripts/check-localization.sh`: English and Simplified Chinese resources.
- `swift run AICatalogChecks --library /Volumes/照片库`: build/update the real local derived catalog, then measure page/search/tag/facet query timings. Reads source media attributes only.
- `bash scripts/check-ai-ui.sh`: native SwiftUI integration against the existing local catalog; saves `dist/ai-categories.png`. Uses isolated local image fixtures to test inline similarity, task results and continuation after closing the task window; it never calls a model.

The preview app uses a separate application identifier and does not replace the installed release. Publication remains a separate release action.

Build the local app with `PHOTO_BROWSER_LOCAL_PREVIEW=1 bash scripts/build-app.sh` (set `PHOTO_CAMERA_RAW_SDK` to an existing SDK cache when available).

## Local preview verification (2026-10-19)

The completed scope contains 89,060 photo families, with 87,186 recognized, 1,866 pending and 8 failed. Its 134,323 image files include grouped RAW/rendered variants. All historical successful recognition IDs are accounted for except three deliberately excluded PSD files. A clean local rebuild and source inventory completed in 391 seconds with no model requests.

Twenty-sample query P95: first page 6.6 ms, Chinese substring search 24.9 ms, tag selection 39.4 ms, cached scene facet 0.9 ms. The first uncached scene facet took 253 ms. Native UI integration measured a first page in approximately 134 ms and tag-to-page P95 of approximately 127 ms, including view updates. These are local preview measurements against this mounted library, rather than a guarantee for every machine.

Core, catalog/state, folder/navigation/preview/HDR regression checks and both language catalogs passed. The packaged preview has its own application identifier, passed signature/resource checks and was launched at 1440 × 940. Evidence is kept locally in the ignored `.build/ai-category-verification/` folder.
