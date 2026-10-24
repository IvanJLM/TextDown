# Changelog

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
