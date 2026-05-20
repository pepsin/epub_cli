# epub-repl

An interactive terminal EPUB reader written in [Zig](https://ziglang.org/). Open a book, browse chapters, search text, and read with a vim-style pager — all without leaving your terminal.

> **Requirements:** Zig 0.15.x

---

## Quick Start

```bash
# Clone and build
git clone <repo-url>
cd epub-repl
zig build

# Run with an EPUB file
zig build run -- book.epub
```

---

## Features

- **Interactive REPL** — Navigate books with simple slash commands.
- **Vim-style Pager** — Read chapters with `j/k/↑/↓`, `u/d` half-page scrolling, `g/G` top/bottom, and `q` to quit.
- **Search** — Search within the current chapter (`// query`) or across all chapters (`/? query`).
- **Chinese Name Highlighting** — Automatically detects and highlights recurring Chinese personal names (bold magenta) using a surname dictionary + frequency-based filtering to reduce false positives.
- **ANSI Rendering** — Converts EPUB XHTML to styled plain text with bold/italic/heading colors.
- **Graceful Fallback** — In non-TTY environments (CI, pipes), the pager falls back to printing the full chapter.

---

## Commands

All commands start with `/`. Typing anything without a leading `/` shows a reminder.

| Command | Alias | Description |
|---------|-------|-------------|
| `/go <n>` | `/cd`, `/goto` | Jump to chapter `n` |
| `/next` | `/n` | Next chapter |
| `/prev` | `/p` | Previous chapter |
| `/show` | `/cat`, `/read` | Show current chapter in pager |
| `/toc` | `/ls` | Show table of contents |
| `// <query>` | — | Search current chapter |
| `/? <query>` | — | Search all chapters |
| `/names` | — | Toggle Chinese name highlighting |
| `/info` | — | Show book title, author, chapter count |
| `/clear` | `/cls` | Clear screen |
| `/help` | `/h`, `/?` | Show help |
| `/quit` | `/q`, `/exit` | Exit reader |

You can also type a bare number (e.g., `4`) as a shorthand for `/go 4`.

---

## Pager Navigation

When viewing a chapter, the terminal enters raw mode. Use these keys to scroll:

| Key | Action |
|-----|--------|
| `j`, `↓`, `Enter`, `Space` | Scroll down 1 line |
| `k`, `↑` | Scroll up 1 line |
| `d`, `PageDown` | Scroll down half a page |
| `u`, `PageUp` | Scroll up half a page |
| `g`, `Home` | Jump to top of chapter |
| `G`, `End` | Jump to bottom of chapter |
| `q`, `Esc` | Quit pager, return to command prompt |

---

## Project Structure

```
src/
├── main.zig   # CLI entry point
├── epub.zig   # EPUB loader: ZIP, OPF, NCX parsing
├── html.zig   # HTML → ANSI plain-text renderer
├── names.zig  # Chinese name detection (~300 surnames + frequency filters)
├── term.zig   # Terminal raw mode, window size, key input
├── repl.zig   # Interactive REPL and pager
├── xml.zig    # Lightweight XML utilities
└── zip.zig    # ZIP archive reader
```

---

## How Name Highlighting Works

1. **Candidate extraction** — Scans all chapters for sequences that begin with a known Chinese surname (including compound surnames like 欧阳, 司马) followed by 1–3 CJK characters.
2. **Frequency analysis** — Counts global character frequencies across the entire book.
3. **Filtering** — Applies statistical thresholds to eliminate common words:
   - 2-character names: Jaccard co-occurrence ≥ 0.15
   - 3-character names: minimum character frequency ratio ≥ 0.30
   - 4-character names: prefix-matching + ratio filter
   - All names: must occur at least 2 times in the book
4. **Rendering** — Surviving names are wrapped in `<name>` tags and rendered in **bold magenta**.

---

## License

MIT
