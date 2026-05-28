# epub-repl

An interactive terminal EPUB reader built with [TypeScript](https://www.typescriptlang.org/) and [Ink](https://github.com/vadimdemedes/ink). Open a book, browse chapters, search text, and read with a vim-style pager — all without leaving your terminal.

> **Requirements:** Node.js ≥ 22

---

## Quick Start

```bash
# Install dependencies
npm install

# Build
npm run build

# Run with an EPUB file
npm start -- book.epub
# or directly
./dist/main.js book.epub
```

---

## Features

- **Modern TUI** — Built with [Ink](https://github.com/vadimdemedes/ink) (React for terminals) for a smooth, responsive interface.
- **Vim-style Pager** — Read chapters with `j/k/↑/↓`, `u/d` half-page scrolling, `g/G` top/bottom, and `q` to quit.
- **Table of Contents** — Interactive TOC selector with arrow keys or `j/k`.
- **Search** — Search within the current chapter (`/`) or across all chapters (`?`).
- **Chinese Name Highlighting** — Automatically detects and highlights recurring Chinese personal names in distinct colors using a surname dictionary + frequency-based filtering to reduce false positives.
- **ANSI Rendering** — Converts EPUB XHTML to styled plain text with bold/italic/heading colors.
- **Progress Persistence** — Automatically saves your reading progress and detected names to `~/.epub_repl.json`.

---

## Keyboard Shortcuts

### Global

| Key | Action |
|-----|--------|
| `Enter` | Start reading (from welcome screen) |
| `t` | Show table of contents |
| `/` | Search current chapter |
| `?` | Search all chapters |
| `h` | Show help |
| `q` | Quit / back |

### Chapter Reader

| Key | Action |
|-----|--------|
| `j`, `↓` | Scroll down 1 line |
| `k`, `↑` | Scroll up 1 line |
| `Space` | Page down |
| `d` | Half page down |
| `u` | Half page up |
| `g`, `Home` | Jump to top of chapter |
| `G`, `End` | Jump to bottom of chapter |
| `n` | Next chapter |
| `p` | Previous chapter |
| `m` | Toggle Chinese name highlighting |
| `q`, `Esc` | Back to welcome screen |

### TOC Selector

| Key | Action |
|-----|--------|
| `j`, `↓` | Move down |
| `k`, `↑` | Move up |
| `g` | Go to first chapter |
| `G` | Go to last chapter |
| `Enter` | Select chapter |
| `q`, `Esc` | Cancel |

---

## Project Structure

```
src/
├── main.tsx         # CLI entry point
├── epub.ts          # EPUB loader: ZIP, OPF, NCX parsing
├── html.ts          # HTML → ANSI plain-text renderer
├── names.ts         # Chinese name detection (~345 surnames + frequency filters)
├── config.ts        # JSON progress persistence
├── xml.ts           # Lightweight XML utilities
├── zip.ts           # ZIP archive reader (via adm-zip)
├── cjk.ts           # CJK character width utilities
├── useTerminalSize.ts  # Terminal resize hook
└── App.tsx          # Main Ink TUI component
```

---

## How Name Highlighting Works

1. **Candidate extraction** — Scans all chapters for sequences that begin with a known Chinese surname (including compound surnames like 欧阳, 司马) followed by 1–3 CJK characters.
2. **Frequency analysis** — Counts global character frequencies across the entire book.
3. **Filtering** — Applies statistical thresholds to eliminate common words:
   - 2-character names: Jaccard co-occurrence ≥ 0.10
   - 3-character names: minimum character frequency ratio ≥ 0.20
   - 4-character names: prefix-matching + ratio filter
   - All names: must occur at least 2 times in the book
4. **Rendering** — Surviving names are wrapped in `<name{N}>` tags and rendered in **distinct bold colors**.

---

## License

MIT
