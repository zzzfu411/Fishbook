# Changelog

## 0.8.3 — 2026-10-05

- Keep papers in library order when opening them in All Papers, the reading queue and other regular filters.
- Sort by activity time only in Recently Read and Recently Removed, with library order preserved for ties.

## 0.8.2 — 2026-10-05

- Use ⌘B to toggle the library sidebar and ⇧⌘B to toggle the companion pane.
- Update toolbar hints, the welcome screen and the shortcut reference to match.

## 0.8.1 — 2026-10-04

- Adopt the MIT license and include license notices in the app bundle.
- Support building with pre-macOS 26 SDKs by using the existing native material appearance; builds with newer SDKs retain Liquid Glass on supported systems.
- Split the workspace view expression so older Swift compilers can type-check it without timing out.

## 0.8.0 — 2026-10-04

First public release.

- Native macOS workspace for PDF originals, companion documents and personal notes.
- Immersive reading, collapsible sidebars, light/dark appearance and six PDF color presets.
- Searchable outlines, page thumbnails and named bookmarks.
- Six annotation colors, highlighting, underlines, strikeouts and text comments.
- Annotation search, editing, undo/redo and export to an annotated PDF copy.
- Local libraries, document revisions, reading queues, questions, Feynman-style reflection, backup and restore.
- A public build that starts with an empty library and includes no personal paper collection.

Requires macOS 14+ and Apple Silicon. Releases are ad-hoc signed, not notarized. OCR, freehand drawing, signatures, page rearrangement and cloud sync are not included.
