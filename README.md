# TextDown

A minimal, native text editor and Markdown reader for Apple Silicon Macs.

TextDown does two things: it shows Markdown files beautifully formatted, and
it edits plain text simply. It is written from scratch in Swift and AppKit,
with no third-party code, using
[MarkEdit](https://github.com/MarkEdit-app/MarkEdit) only as a reference for
what a Markdown app on the Mac should feel like. MarkEdit edits in CodeMirror
inside a web view; TextDown uses only what macOS already ships: Foundation's
Markdown parser (the same cmark-gfm GitHub uses), TextKit to lay out the
text and AppKit's document architecture for opening and saving.

## Why

Measured on an M-series Mac with macOS 26, with `./scripts/benchmark.sh`:

| | TextDown 1.0 | TextEdit |
|---|---|---|
| Memory, a README open | 31 MB, formatted | 29 MB, as raw text |
| Memory, 25 windows | 176 MB | 215 MB |
| CPU while idle | 0.0 % | 0.0 % |
| Threads while idle | 3 | 16 |
| App size | 0.8 MB | — |

TextDown quits when its last window closes, so it uses no memory at all when
you are not reading or writing.

## What it does

- **Reads Markdown formatted**, in a centered column that never gets too wide
  to read: headings, emphasis, links, lists, task lists, quotes, code blocks,
  tables, rules and images, in light and dark mode. GitHub Flavored Markdown,
  plus the HTML most READMEs use for centered logos and titles. YAML front
  matter is hidden.
- **Edits plain text** with nothing in the way: no smart quotes, no
  autocorrection, no rich text. `.txt` files open ready to type.
- **⌘E switches a Markdown file to its source** and back. Markdown opens
  read-only, so a stray key never changes it.
- **Follows the file**: change it in another app and TextDown shows the new
  version at once, keeping your place.
- **Links work**: web links open in your browser, `#section` links jump to the
  heading, links to other `.md` files open them in TextDown.
- **Local images** are shown, decoded at the size they are drawn. Remote
  images are not downloaded; their description links to them.
- Autosave and versions, rename and move from the title bar, find and
  replace (⌘F), zoom (⌘+ / ⌘−), print and PDF, full screen, Open Recent.
- Keeps the file's encoding (UTF-8, UTF-16, Windows Latin 1, Mac Roman…).

There are no preferences, no toolbar, no tabs, no syntax highlighting, no
live preview pane and no auto-updates.

## Shortcuts

| Key | Action |
|---|---|
| ⌘E | Edit the Markdown source / show it formatted |
| ⌘N / ⌘O | New document / open |
| ⌘S | Save |
| ⌘F, ⌥⌘F | Find / find and replace |
| ⌘G, ⇧⌘G | Find next / previous |
| ⌘+ / ⌘− / ⌘0 | Zoom in / out / actual size |
| ⇧⌘R | Show in Finder |
| ⌘P | Print |
| ⌃⌘F | Full screen |

## How it stays light

- One process, no web view: nothing to start besides the app itself.
- Each window makes its views when first needed: a Markdown file you only
  read never creates an editor, a text file never creates a reader.
- The formatted text is built once per change, straight from the parser's
  output; parsing temporaries are released as it goes. Going back to it
  with ⌘E reuses it. Documents over 64 KB are formatted in the background,
  so the window never waits for them.
- Zoom and ⌘E keep your place by character, so only the text on screen
  is laid out, never the whole document.
- Each image file is decoded once per document, at most twice the column
  width, never at full size.
- Changes on disk are noticed by one kernel event per open file: no polling,
  no timers. Nothing runs while you read.
- Menus are built in code (no nib to load). The app quits with its last window.

Rendering times for a document full of tables, lists and images:

| Size | Time | Memory added |
|---|---|---|
| 10 KB | 65 ms | 7 MB |
| 100 KB | 150 ms | 17 MB |
| 1 MB | 0.95 s | 57 MB |

## Install

Requirements: an Apple Silicon Mac with macOS 15 or later, Xcode 26 or later,
and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
./scripts/install.sh
```

The script builds a Release copy, installs it in `/Applications` and asks
macOS to make TextDown the default app for Markdown and plain text files.
macOS asks you to confirm each change in its own dialog. To skip that step,
run `./scripts/install.sh --no-default`.

To install on another Mac, run `./scripts/package.sh`, copy
`dist/TextDown-<version>.zip` over, unzip it into `/Applications` and open
TextDown once: it offers to become the default app for Markdown and text.

## Development

```bash
./scripts/test.sh                 # unit tests (Debug build)
./scripts/benchmark.sh            # memory, threads and idle activity (Release build)
./scripts/bump-version.sh minor   # or patch / major, then fill in CHANGELOG.md
swift scripts/make-icon.swift     # redraws the app icon
```

The code is in `App/Sources`: `MarkdownRenderer.swift` turns Markdown into
formatted text, `DocumentWindowController.swift` holds the reader and the
editor, `TextDocument.swift` reads, saves and follows the file.

## License

MIT. See [LICENSE](LICENSE).
