# SpaceSense — AI-Powered macOS Storage Manager

**Current Version:** `v0.4.0`

SpaceSense is a native macOS storage analyzer and cleanup utility built with Swift and SwiftUI for Apple Silicon Macs (macOS 14+). It helps users inspect disk usage, visualize directory trees, locate large and duplicate files, understand macOS System Data, track historical disk trends, and safely reclaim disk space with optional Gemini AI insights.

## Version History

- **`v0.4.0`** — Added SQLite Storage History with Swift Charts, macOS Keychain API credential storage, Gemini AI Storage Assistant with telemetry inspector, Settings & Privacy controls, and full 9-section native macOS window navigation.
- **`v0.3.0`** — Implemented 3-stage CryptoKit SHA-256 Duplicate Finder, System Data Analyzer (measured vs. estimated vs. restricted paths), and Smart Cleanup engine with Trash review workflow.
- **`v0.2.0`** — Added Overview dashboard, interactive Squarified Treemap storage visualization, hierarchical Storage Analyzer browser, and Large Files Finder with Quick Look preview and safe Trash actions.
- **`v0.1.0`** — Initial project structure, core storage models, security-scoped bookmark manager, and asynchronous filesystem scanning engine.

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (`arm64`) or Intel Mac
- Swift 5.10+ / Swift 6 Command Line Tools or Xcode
