# Changelog

## 1.1.0 — 2026-10-24

Faster and lighter with long documents, and three fixes, after the first
audit.

- Large Markdown files (over 64 KB) are formatted in the background: the
  window opens at once and never freezes while they are formatted.
- Zoom and ⌘E keep your place exactly, by character, and lay out only the
  text on screen. With 1 MB of Markdown, ⌘+ took 4.4 s of CPU and 240 MB;
  now 1 s in the background and 157 MB. In the editor, zoom is instant.
- ⌘E back to the formatted view reuses it when nothing changed.
- 1 MB of Markdown formats in 0.94 s instead of 1.55 s.
- YAML front matter is hidden in files with Windows line endings too.
- Saving keeps the file's byte order mark (UTF-8 with BOM, UTF-16 big and
  little endian): saving an unchanged file no longer alters it.
- A file that is deleted and written again later is still followed.
- The CI builds with Xcode 26.6, the oldest supported.

## 1.0.0 — 2026-10-24

First release. A native Swift/AppKit text editor and Markdown reader written
from scratch, using MarkEdit as the reference for behaviour (no MarkEdit code).

- Markdown opens formatted and read-only, in a centered reading column:
  headings, emphasis, links, lists, task lists, quotes, code blocks, tables,
  rules, local images and common README HTML. Light and dark mode.
- ⌘E switches between the formatted view and the Markdown source.
- Plain text opens ready to edit, with no automatic substitutions.
- Follows changes made to the file by other apps.
- `#section` links jump to headings; links to other Markdown files open them.
- Autosave, versions, rename, find and replace, zoom, print, full screen.
- Keeps each file's text encoding.
- Quits when the last window closes. A README open: 31 MB, 3 threads, no
  activity while idle.
- Offers once to become the default app for Markdown and text (macOS asks you
  to confirm).
