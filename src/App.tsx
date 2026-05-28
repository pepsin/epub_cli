import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Box, Text, useInput, useApp } from 'ink';
import { Epub, Chapter } from './epub.js';
import { renderToTerminal, renderWithSearchHighlight, injectNameTags } from './html.js';
import { buildNameSetFromContents, NameSet } from './names.js';
import { Config } from './config.js';
import { useTerminalSize } from './useTerminalSize.js';
import { physicalRows, sliceFromRow, displayWidth } from './cjk.js';

type Mode = 'welcome' | 'reading' | 'toc' | 'search' | 'search_results' | 'help';

interface AppProps {
  epub: Epub;
  bookPath: string;
  config: Config;
}

interface SearchResult {
  chapter: number;
  title: string;
}

export default function App({ epub, bookPath, config }: AppProps) {
  const { exit } = useApp();
  const size = useTerminalSize();
  const [mode, setMode] = useState<Mode>('welcome');
  const [currentChapter, setCurrentChapter] = useState(0);
  const [topLine, setTopLine] = useState(0);
  const [topRow, setTopRow] = useState(0);
  const [lines, setLines] = useState<string[]>([]);
  const [nameHighlight, setNameHighlight] = useState(false);
  const [nameSet, setNameSet] = useState<NameSet | null>(null);
  const [nameSetLoading, setNameSetLoading] = useState(false);
  const [searchTerm, setSearchTerm] = useState('');
  const [searchMode, setSearchMode] = useState<'current' | 'all'>('current');
  const [searchResults, setSearchResults] = useState<SearchResult[]>([]);
  const [tocSelected, setTocSelected] = useState(0);
  const [tocTop, setTocTop] = useState(0);

  // Keep tocTop in sync with tocSelected
  useEffect(() => {
    const total = epub.chapters.length;
    const headerRows = 2;
    const footerRows = 2;
    const tocVisible = Math.max(1, size.rows - headerRows - footerRows);
    setTocTop(prev => {
      let top = prev;
      if (tocSelected < top) top = tocSelected;
      if (tocSelected >= top + tocVisible) top = tocSelected - tocVisible + 1;
      if (top + tocVisible > total) top = Math.max(0, total - tocVisible);
      return top;
    });
  }, [tocSelected, size.rows, epub.chapters.length]);
  const [message, setMessage] = useState<string | null>(null);
  const [inputBuffer, setInputBuffer] = useState('');
  const [inputMode, setInputMode] = useState(false);

  const searchInputRef = useRef('');
  const linesRef = useRef<string[]>([]);
  const searchLinesRef = useRef<string[]>([]);
  linesRef.current = lines;

  // Restore saved progress
  useEffect(() => {
    const savedChapter = config.getProgress(bookPath);
    if (savedChapter !== null && savedChapter < epub.chapters.length) {
      setCurrentChapter(savedChapter);
    }
    const savedNames = config.getNames(bookPath);
    if (savedNames) {
      const savedSet = config.loadNameSet(bookPath);
      if (savedSet) {
        setNameSet(savedSet);
        setNameHighlight(true);
      }
    }
  }, [bookPath, config, epub.chapters.length]);

  // Background name parser
  useEffect(() => {
    if (nameSet !== null || nameSetLoading) return;
    setNameSetLoading(true);

    const contents: string[] = [];
    for (let i = 0; i < epub.chapters.length; i++) {
      const content = epub.getChapterContent(i);
      contents.push(content || '');
    }

    // Process in chunks to avoid blocking
    setTimeout(() => {
      try {
        const set = buildNameSetFromContents(contents);
        setNameSet(set);
        setNameHighlight(true);
        config.setProgress(bookPath, currentChapter, true);
        const nameList = Array.from(set.keys());
        config.setDetectedNames(bookPath, nameList);
        setMessage(`✓ Name highlighting auto-enabled (${nameList.length} names detected)`);
        setTimeout(() => setMessage(null), 3000);
      } catch (err) {
        // silently fail
      } finally {
        setNameSetLoading(false);
      }
    }, 100);
  }, [nameSet, nameSetLoading, epub, bookPath, config, currentChapter]);

  // Load chapter content
  useEffect(() => {
    if (mode !== 'reading' && mode !== 'search_results') return;

    const content = epub.getChapterContent(currentChapter);
    if (!content) {
      setLines(['Failed to load chapter content.']);
      return;
    }

    let processed = content;
    if (nameHighlight && nameSet) {
      processed = injectNameTags(content, nameSet);
    }

    let rendered: string;
    if (searchTerm && mode === 'reading') {
      rendered = renderWithSearchHighlight(processed, searchTerm);
    } else {
      rendered = renderToTerminal(processed);
    }

    const newLines = rendered.split('\n');
    setLines(newLines);

    // Reset scroll position when changing chapters
    if (mode === 'reading') {
      setTopLine(0);
      setTopRow(0);
    }
  }, [currentChapter, mode, nameHighlight, nameSet, searchTerm, epub]);

  const visibleLines = size.rows > 2 ? size.rows - 2 : size.rows;
  const cols = size.columns > 0 ? size.columns : 80;

  // Calculate screen rows from logical lines
  const calculateScreenRows = useCallback((lines: string[], startLine: number, startRow: number, maxRows: number): string[] => {
    const rows: string[] = [];
    let lineIdx = startLine;
    let rowIdx = startRow;

    while (rows.length < maxRows && lineIdx < lines.length) {
      const line = lines[lineIdx];
      const lineRows = physicalRows(line, cols);
      const startRowOffset = lineIdx === startLine ? rowIdx : 0;
      const remainingRows = lineRows - startRowOffset;
      const take = Math.min(remainingRows, maxRows - rows.length);

      for (let r = 0; r < take; r++) {
        const rowText = sliceFromRow(line, startRowOffset + r, cols);
        rows.push(rowText);
      }

      lineIdx++;
      rowIdx = 0;
    }

    return rows;
  }, [cols]);

  // Keyboard handling
  useInput((input, key) => {
    if (inputMode) {
      if (key.return) {
        setInputMode(false);
        const query = inputBuffer.trim();
        if (query) {
          if (mode === 'search') {
            handleSearch(query);
          }
        }
        setInputBuffer('');
        return;
      }
      if (key.escape) {
        setInputMode(false);
        setInputBuffer('');
        if (mode === 'search') setMode('reading');
        return;
      }
      if (key.backspace || key.delete) {
        setInputBuffer(prev => prev.slice(0, -1));
        return;
      }
      if (input && !key.ctrl && !key.meta) {
        setInputBuffer(prev => prev + input);
        return;
      }
      return;
    }

    if (mode === 'welcome') {
      if (input === 'q' || key.escape) {
        exit();
        return;
      }
      if (input === '\r' || input === '\n' || input === ' ') {
        setMode('reading');
        return;
      }
      if (input === 't' || input === 'T') {
        setTocSelected(currentChapter);
        setTocTop(0);
        setMode('toc');
        return;
      }
      if (input === '/' || input === '?') {
        setSearchMode(input === '/' ? 'current' : 'all');
        setInputBuffer('');
        setInputMode(true);
        setMode('search');
        return;
      }
      if (input === 'h' || input === 'H') {
        setMode('help');
        return;
      }
      return;
    }

    if (mode === 'toc') {
      const total = epub.chapters.length;
      if (input === 'q' || key.escape) {
        setMode('reading');
        return;
      }
      if (key.return) {
        setCurrentChapter(tocSelected);
        config.setProgress(bookPath, tocSelected, nameHighlight);
        setMode('reading');
        return;
      }
      if (input === 'j' || key.downArrow) {
        setTocSelected(prev => Math.min(prev + 1, total - 1));
        return;
      }
      if (input === 'k' || key.upArrow) {
        setTocSelected(prev => Math.max(prev - 1, 0));
        return;
      }
      if (input === 'g' || key.home) {
        setTocSelected(0);
        return;
      }
      if (input === 'G' || key.end) {
        // Fix: guard against empty book
        if (total > 0) setTocSelected(total - 1);
        return;
      }
      return;
    }

    if (mode === 'search') {
      if (key.escape) {
        setMode('reading');
        return;
      }
      return;
    }

    if (mode === 'search_results') {
      if (input === 'q' || key.escape) {
        setMode('reading');
        return;
      }
      if (input === 'j' || key.downArrow) {
        setTopLine(prev => Math.min(prev + 1, linesRef.current.length - 1));
        setTopRow(0);
        return;
      }
      if (input === 'k' || key.upArrow) {
        setTopLine(prev => Math.max(prev - 1, 0));
        setTopRow(0);
        return;
      }
      if (key.pageDown || input === ' ') {
        // Scroll down one page
        let remaining = visibleLines;
        let lineIdx = topLine;
        let rowIdx = topRow;
        while (remaining > 0 && lineIdx < linesRef.current.length) {
          const lineRows = physicalRows(linesRef.current[lineIdx], cols);
          const avail = lineRows - rowIdx;
          if (remaining < avail) {
            rowIdx += remaining;
            break;
          }
          remaining -= avail;
          lineIdx++;
          rowIdx = 0;
        }
        setTopLine(lineIdx);
        setTopRow(rowIdx);
        return;
      }
      if (key.pageUp) {
        let remaining = visibleLines;
        let lineIdx = topLine;
        let rowIdx = topRow;
        while (remaining > 0) {
          if (rowIdx > 0) {
            const back = Math.min(rowIdx, remaining);
            rowIdx -= back;
            remaining -= back;
            if (remaining === 0) break;
          }
          if (lineIdx === 0) break;
          lineIdx--;
          rowIdx = physicalRows(linesRef.current[lineIdx], cols);
          if (rowIdx > 0) rowIdx--;
        }
        setTopLine(lineIdx);
        setTopRow(rowIdx);
        return;
      }
      return;
    }

    if (mode === 'help') {
      if (input === 'q' || key.escape || key.return) {
        setMode('reading');
        return;
      }
      return;
    }

    if (mode === 'reading') {
      if (input === 'q' || key.escape) {
        setMode('welcome');
        return;
      }
      if (input === 't' || input === 'T') {
        setTocSelected(currentChapter);
        setTocTop(0);
        setMode('toc');
        return;
      }
      if (input === '/' || input === '?') {
        setSearchMode(input === '/' ? 'current' : 'all');
        setInputBuffer('');
        setInputMode(true);
        setMode('search');
        return;
      }
      if (input === 'h' || input === 'H') {
        setMode('help');
        return;
      }
      if (input === 'n' || input === 'N') {
        if (currentChapter + 1 < epub.chapters.length) {
          setCurrentChapter(prev => prev + 1);
          config.setProgress(bookPath, currentChapter + 1, nameHighlight);
        } else {
          setMessage('Already at the last chapter.');
          setTimeout(() => setMessage(null), 2000);
        }
        return;
      }
      if (input === 'p' || input === 'P') {
        if (currentChapter > 0) {
          setCurrentChapter(prev => prev - 1);
          config.setProgress(bookPath, currentChapter - 1, nameHighlight);
        } else {
          setMessage('Already at the first chapter.');
          setTimeout(() => setMessage(null), 2000);
        }
        return;
      }
      if (input === 'm' || input === 'M') {
        setNameHighlight(prev => {
          const next = !prev;
          config.setProgress(bookPath, currentChapter, next);
          return next;
        });
        return;
      }
      if (input === 'j' || key.downArrow) {
        const line = linesRef.current[topLine];
        const lineRows = physicalRows(line, cols);
        if (topRow + 1 < lineRows) {
          setTopRow(prev => prev + 1);
        } else if (topLine + 1 < linesRef.current.length) {
          setTopLine(prev => prev + 1);
          setTopRow(0);
        }
        return;
      }
      if (input === 'k' || key.upArrow) {
        if (topRow > 0) {
          setTopRow(prev => prev - 1);
        } else if (topLine > 0) {
          setTopLine(prev => prev - 1);
          const prevRows = physicalRows(linesRef.current[topLine - 1], cols);
          setTopRow(prevRows > 0 ? prevRows - 1 : 0);
        }
        return;
      }
      if (input === ' ') {
        // Scroll down one full page
        let remaining = visibleLines;
        let lineIdx = topLine;
        let rowIdx = topRow;
        while (remaining > 0 && lineIdx < linesRef.current.length) {
          const lineRows = physicalRows(linesRef.current[lineIdx], cols);
          const avail = lineRows - rowIdx;
          if (remaining < avail) {
            rowIdx += remaining;
            break;
          }
          remaining -= avail;
          lineIdx++;
          rowIdx = 0;
          if (lineIdx >= linesRef.current.length) {
            lineIdx = linesRef.current.length - 1;
            rowIdx = 0;
            break;
          }
        }
        setTopLine(lineIdx);
        setTopRow(rowIdx);
        return;
      }
      if (input === 'd' || input === 'D') {
        let remaining = Math.max(1, Math.floor(visibleLines / 2));
        let lineIdx = topLine;
        let rowIdx = topRow;
        while (remaining > 0 && lineIdx < linesRef.current.length) {
          const lineRows = physicalRows(linesRef.current[lineIdx], cols);
          const avail = lineRows - rowIdx;
          if (remaining < avail) {
            rowIdx += remaining;
            break;
          }
          remaining -= avail;
          lineIdx++;
          rowIdx = 0;
          if (lineIdx >= linesRef.current.length) {
            lineIdx = linesRef.current.length - 1;
            rowIdx = 0;
            break;
          }
        }
        setTopLine(lineIdx);
        setTopRow(rowIdx);
        return;
      }
      if (input === 'u' || input === 'U') {
        let remaining = Math.max(1, Math.floor(visibleLines / 2));
        let lineIdx = topLine;
        let rowIdx = topRow;
        while (remaining > 0) {
          if (rowIdx > 0) {
            const back = Math.min(rowIdx, remaining);
            rowIdx -= back;
            remaining -= back;
            if (remaining === 0) break;
          }
          if (lineIdx === 0) break;
          lineIdx--;
          rowIdx = physicalRows(linesRef.current[lineIdx], cols);
          if (rowIdx > 0) rowIdx--;
        }
        setTopLine(lineIdx);
        setTopRow(rowIdx);
        return;
      }
      if (input === 'g' || key.home) {
        setTopLine(0);
        setTopRow(0);
        return;
      }
      if (input === 'G' || key.end) {
        let rows = 0;
        let lineIdx = linesRef.current.length;
        let rowIdx = 0;
        while (lineIdx > 0) {
          const prevRows = physicalRows(linesRef.current[lineIdx - 1], cols);
          if (rows + prevRows > visibleLines) {
            rowIdx = prevRows - (visibleLines - rows);
            break;
          }
          rows += prevRows;
          lineIdx--;
        }
        if (lineIdx === 0) rowIdx = 0;
        setTopLine(lineIdx);
        setTopRow(rowIdx);
        return;
      }
      if (key.pageDown) {
        let remaining = Math.max(1, Math.floor(visibleLines / 2));
        let lineIdx = topLine;
        let rowIdx = topRow;
        while (remaining > 0 && lineIdx < linesRef.current.length) {
          const lineRows = physicalRows(linesRef.current[lineIdx], cols);
          const avail = lineRows - rowIdx;
          if (remaining < avail) {
            rowIdx += remaining;
            break;
          }
          remaining -= avail;
          lineIdx++;
          rowIdx = 0;
          if (lineIdx >= linesRef.current.length) {
            lineIdx = linesRef.current.length - 1;
            rowIdx = 0;
            break;
          }
        }
        setTopLine(lineIdx);
        setTopRow(rowIdx);
        return;
      }
      if (key.pageUp) {
        let remaining = Math.max(1, Math.floor(visibleLines / 2));
        let lineIdx = topLine;
        let rowIdx = topRow;
        while (remaining > 0) {
          if (rowIdx > 0) {
            const back = Math.min(rowIdx, remaining);
            rowIdx -= back;
            remaining -= back;
            if (remaining === 0) break;
          }
          if (lineIdx === 0) break;
          lineIdx--;
          rowIdx = physicalRows(linesRef.current[lineIdx], cols);
          if (rowIdx > 0) rowIdx--;
        }
        setTopLine(lineIdx);
        setTopRow(rowIdx);
        return;
      }
      return;
    }
  });

  const handleSearch = (query: string) => {
    setSearchTerm(query);
    setSearchResults([]);

    if (searchMode === 'current') {
      const content = epub.getChapterContent(currentChapter);
      if (content) {
        const lowerContent = content.toLowerCase();
        const lowerQuery = query.toLowerCase();
        if (lowerContent.includes(lowerQuery)) {
          setMode('reading');
        } else {
          setMessage('Not found in current chapter.');
          setTimeout(() => setMessage(null), 2000);
          setMode('reading');
        }
      }
    } else {
      const results: SearchResult[] = [];
      for (let i = 0; i < epub.chapters.length; i++) {
        const content = epub.getChapterContent(i);
        if (!content) continue;
        const lowerContent = content.toLowerCase();
        const lowerQuery = query.toLowerCase();
        if (lowerContent.includes(lowerQuery)) {
          results.push({ chapter: i, title: epub.chapters[i].title });
        }
      }
      setSearchResults(results);
      if (results.length > 0) {
        setMode('search_results');
      } else {
        setMessage('No matches found.');
        setTimeout(() => setMessage(null), 2000);
        setMode('reading');
      }
    }
  };

  // Welcome screen
  if (mode === 'welcome') {
    return (
      <Box flexDirection="column" padding={1}>
        <Text bold color="magenta">{'╔══════════════════════════════════════╗'}</Text>
        <Text bold color="magenta">{'║      📚 EPUB Interactive Reader      ║'}</Text>
        <Text bold color="magenta">{'╚══════════════════════════════════════╝'}</Text>
        <Box marginTop={1} flexDirection="column">
          {epub.title && <Text><Text bold color="yellow">Title:</Text>  {epub.title}</Text>}
          {epub.author && <Text><Text bold color="yellow">Author:</Text> {epub.author}</Text>}
          <Text><Text bold color="yellow">Chapters:</Text> {epub.chapters.length}</Text>
        </Box>
        <Box marginTop={1} flexDirection="column">
          <Text dimColor>Press [Enter] to start reading</Text>
          <Text dimColor>[t] Table of Contents</Text>
          <Text dimColor>[/] Search current chapter  [?] Search all chapters</Text>
          <Text dimColor>[h] Help  [q] Quit</Text>
        </Box>
        {message && (
          <Box marginTop={1}>
            <Text color="yellow">{message}</Text>
          </Box>
        )}
      </Box>
    );
  }

  // Help screen
  if (mode === 'help') {
    return (
      <Box flexDirection="column" padding={1}>
        <Text bold color="yellow">{'┌────────── Commands ──────────┐'}</Text>
        <Text>{'  [t]           Show table of contents'}</Text>
        <Text>{'  [n]           Next chapter'}</Text>
        <Text>{'  [p]           Previous chapter'}</Text>
        <Text>{'  [m]           Toggle name highlighting'}</Text>
        <Text>{'  [/]           Search current chapter'}</Text>
        <Text>{'  [?]           Search all chapters'}</Text>
        <Text>{'  [h]           Show this help'}</Text>
        <Text>{'  [q]           Back to welcome / quit'}</Text>
        <Text bold color="yellow">{'├────── In Chapter View ──────┤'}</Text>
        <Text>{'  [j/↓]         Scroll down one line'}</Text>
        <Text>{'  [k/↑]         Scroll up one line'}</Text>
        <Text>{'  [Space]       Page down'}</Text>
        <Text>{'  [d]           Half page down'}</Text>
        <Text>{'  [u]           Half page up'}</Text>
        <Text>{'  [g/Home]      Go to top'}</Text>
        <Text>{'  [G/End]       Go to bottom'}</Text>
        <Text bold color="yellow">{'└──────────────────────────────┘'}</Text>
        <Box marginTop={1}>
          <Text dimColor>Press [q] or [Enter] to close help</Text>
        </Box>
      </Box>
    );
  }

  // TOC screen
  if (mode === 'toc') {
    const total = epub.chapters.length;
    const headerRows = 2;
    const footerRows = 2;
    const tocVisible = Math.max(1, size.rows - headerRows - footerRows);

    let top = tocTop;
    if (tocSelected < top) top = tocSelected;
    if (tocSelected >= top + tocVisible) top = tocSelected - tocVisible + 1;
    if (top + tocVisible > total) top = Math.max(0, total - tocVisible);

    const end = Math.min(tocTop + tocVisible, total);
    const visibleChapters = epub.chapters.slice(top, end);

    return (
      <Box flexDirection="column">
        <Text bold color="green">{`┌────────── Table of Contents (${tocSelected + 1}/${total}) ──────────┐`}</Text>
        {visibleChapters.map((ch, idx) => {
          const i = tocTop + idx;
          const marker = i === tocSelected ? '▶' : ' ';
          const here = i === currentChapter ? ' [here]' : '';
          return (
            <Text key={i}>
              <Text color="cyan">{marker}</Text>
              <Text bold>{` ${String(i + 1).padStart(3)}.`}</Text>
              {` ${ch.title}`}
              <Text dimColor>{here}</Text>
            </Text>
          );
        })}
        <Text backgroundColor="gray" color="black">{'[↑/↓/j/k] move  [Enter] select  [q] cancel'}</Text>
      </Box>
    );
  }

  // Search input screen
  if (mode === 'search') {
    return (
      <Box flexDirection="column" padding={1}>
        <Text bold color="cyan">
          {searchMode === 'current' ? 'Search current chapter:' : 'Search all chapters:'}
        </Text>
        <Box borderStyle="single" paddingX={1}>
          <Text>{inputBuffer}</Text>
          <Text color="gray">_</Text>
        </Box>
        <Text dimColor>[Enter] search  [Esc] cancel</Text>
      </Box>
    );
  }

  // Search results screen
  if (mode === 'search_results') {
    const resultText = searchResults.map(r => `[${r.chapter + 1}] ${r.title}`).join('\n');
    const header = `\x1b[1;32mFound in ${searchResults.length} chapter(s):\x1b[0m\n`;
    const footer = '\n\x1b[2mUse [q] to return, [j/k] to scroll\x1b[0m';
    const allLines = (header + resultText + footer).split('\n');
    searchLinesRef.current = allLines;
    const screenRows = calculateScreenRows(allLines, topLine, topRow, visibleLines);

    return (
      <Box flexDirection="column">
        {screenRows.map((row, i) => (
          <Text key={i}>{row}</Text>
        ))}
        <Text backgroundColor="gray" color="black">
          {`-- ${topLine + 1}/${allLines.length} -- [j/k/q] --`}
        </Text>
      </Box>
    );
  }

  // Reading mode
  const screenRows = calculateScreenRows(lines, topLine, topRow, visibleLines);
  const ch = epub.chapters[currentChapter];

  return (
    <Box flexDirection="column" height={size.rows}>
      <Box flexDirection="column" flexGrow={1}>
        {screenRows.map((row, i) => (
          <Text key={i}>{row}</Text>
        ))}
      </Box>
      <Box flexDirection="column">
        {message && (
          <Text color="yellow">{message}</Text>
        )}
        <Text backgroundColor="gray" color="black">
          {`-- ${currentChapter + 1}/${epub.chapters.length}: ${ch?.title || ''} | Line ${topLine + 1}/${lines.length} --`}
        </Text>
        <Text backgroundColor="gray" color="black">
          {`[j/k/↑/↓] scroll  [u/d] half-page  [g/G] top/bottom  [n/p] chapter  [t] toc  [/] search  [m] names  [q] quit`}
        </Text>
      </Box>
    </Box>
  );
}
