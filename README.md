# SpaceSense — AI-Powered macOS Storage Manager

**Current Version:** `v1.2.1`

SpaceSense is a native macOS Dock application built with Swift and SwiftUI for Apple Silicon Macs (macOS 14+). It helps users understand, analyze, visualize, organize, and safely reclaim disk space on their Macs using local filesystem telemetry, cryptographic SHA-256 duplicate detection, SQLite storage history, and an optional Google Gemini AI assistant.

---

## Features

1. **Overview Dashboard**: Real-time boot volume capacity, used/available space, utilization percentage, category breakdown bar, recently detected large files, reclaimable space summary, and recent storage growth deltas.
2. **Storage Analyzer & Interactive Treemap**: Recursive background filesystem scanner with symlink loop prevention, metadata-only size calculation, subtree caching, cancellation, breadcrumb navigation, and an interactive squarified treemap visualization.
3. **Large Files Finder**: Sort and filter large files by size, file extension, modification date, and filename; preview text/images via native Quick Look / preview sheet; reveal or open in Finder; and review selections before moving to Trash.
4. **Duplicate Finder (CryptoKit SHA-256)**: 3-stage duplicate detection pipeline (exact size grouping → 64 KB head/tail pre-hash → streaming full SHA-256 digest) that automatically preserves at least one copy per duplicate group by default.
5. **System Data Analyzer**: Inspects real user and system library paths (`~/Library/Caches`, `~/Library/Logs`, `Xcode/DerivedData`, `Xcode/Archives`, `CoreSimulator`, `MobileSync/Backup`, `Application Support`, `Containers`, `Homebrew`, `/private/var/tmp`), clearly distinguishing **Measured**, **Estimated** (APFS snapshots/VM swap), and **Restricted** (SIP/Full Disk Access) storage.
6. **Smart Cleanup**: Generates safe cleanup candidates with 5-part explanations (what will be removed, location, size, why recommended, potential consequences), requires explicit confirmation, and moves items exclusively to the macOS Trash.
7. **Storage History (SQLite + Swift Charts)**: Persists scan snapshots in `~/Library/Application Support/SpaceSense/storage_history.sqlite`, visualizes disk usage trends and category growth over time, and highlights growing folders.
8. **AI Storage Assistant (Gemini API)**: Answers natural-language questions grounded strictly in actual scan telemetry, with a built-in Telemetry Inspector showing the exact metadata sent to Gemini.
9. **Settings & Privacy**: Stores the Gemini API key in the macOS Keychain, configures AI models (`gemini-2.5-flash`, `gemini-2.5-pro`, `gemini-2.0-flash`), manages scan exclusions, history retention, appearance (`Dark`, `Light`, `System`), notifications, and path privacy.

---

## Required User Configuration

- **Gemini API Key (Optional)**: SpaceSense works offline without an API key. To use the **AI Assistant** tab, open **Settings** inside SpaceSense and paste a Google Gemini API key, which is saved securely in the macOS Keychain (`com.spacesense.macos.credentials`).
- **Filesystem Permissions**: Use the **Choose Folder…** button to grant access to user directories via native macOS `NSOpenPanel` and security-scoped bookmarks. To inspect protected `~/Library` containers or system caches, grant **Full Disk Access** to SpaceSense (or your terminal) in **System Settings → Privacy & Security → Full Disk Access**.

---

## Build, Run, and Package Instructions

### 1. Run Directly via Swift Package Manager
```bash
swift run SpaceSense
```

### 2. Package & Install Standalone Native `SpaceSense.app` Bundle
```bash
chmod +x scripts/bundle-app.sh
./scripts/bundle-app.sh --install
open /Applications/SpaceSense.app
```
This builds the release binary, generates the Retina `AppIcon.icns`, signs `SpaceSense.app` in a clean staging folder, installs `/Applications/SpaceSense.app`, and creates distributable `build/SpaceSense-v1.1.0.dmg` and `build/SpaceSense-v1.1.0-macOS-arm64.zip` archives.

### 3. Run Automated Test Suite
```bash
# Run the built-in automated verification suite (works with Command Line Tools or Xcode):
swift run SpaceSense --self-test

# Or via Swift Package Manager's Swift Testing runner:
swift test --enable-swift-testing --disable-xctest
```

---

## Version History

- **`v1.2.1`** — Responsive fluid window shrinking (`680×480` minimum with adaptive grids, `ViewThatFits` headers/toolbars, and dynamic split views), full tree & System Data state pruning after Trash operations, hardened protected-path & SHA-256 read verification, and multi-agent review improvements.
- **`v1.2.0`** — Faster bottom-up filesystem scanner with determinate percent bar & stop-scan confirmation prompt, unified **Delete Hub** (with Unused Large Files detection, 250 MB–1 GB thresholds, SHA-256 duplicates, and non-blocking async refresh), universal AI API key support with automatic provider & model detection, hover tooltips on technical concepts, 3-color modern palette, and About/Credits with GitHub release update checker.
- **`v1.1.0`** — Added automated Retina `.icns` icon generation (`AppIcon.icns`), clean-staged code signing, one-step `/Applications/SpaceSense.app` installer, and `.dmg` + `.zip` release packaging.
- **`v1.0.1`** — Hardened logical-size duplicate hashing, hard-link deduplication, container-safe Trash cleanup, SQLite latest-snapshot ordering, Gemini `x-goog-api-key` header & role-ordering, and UI/UX polish from 4-agent code review.
- **`v1.0.0`** — Added comprehensive automated XCTest suite, standalone `SpaceSense.app` bundle packaging script, and production documentation.
- **`v0.4.0`** — Added SQLite Storage History with Swift Charts, macOS Keychain API credential storage, Gemini AI Storage Assistant with telemetry inspector, Settings & Privacy controls, and full 9-section native macOS window navigation.
- **`v0.3.0`** — Implemented 3-stage CryptoKit SHA-256 Duplicate Finder, System Data Analyzer (measured vs. estimated vs. restricted paths), and Smart Cleanup engine with Trash review workflow.
- **`v0.2.0`** — Added Overview dashboard, interactive Squarified Treemap storage visualization, hierarchical Storage Analyzer browser, and Large Files Finder with Quick Look preview and safe Trash actions.
- **`v0.1.0`** — Initial project structure, core storage models, security-scoped bookmark manager, and asynchronous filesystem scanning engine.
