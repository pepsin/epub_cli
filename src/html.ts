/**
 * HTML to ANSI plain-text renderer.
 * Fixes: style stack overflow (now dynamic), proper body tag fallback.
 */

import { isWideChar, codePointAt } from './cjk.js';

const ANSI_RESET = '\x1b[0m';
const ANSI_BOLD = '\x1b[1m';
const ANSI_DIM = '\x1b[2m';
const ANSI_ITALIC = '\x1b[3m';
const ANSI_UNDERLINE = '\x1b[4m';
const ANSI_BLINK = '\x1b[5m';
const ANSI_REVERSE = '\x1b[7m';
const ANSI_STRIKETHROUGH = '\x1b[9m';

const ANSI_BLACK = '\x1b[30m';
const ANSI_RED = '\x1b[31m';
const ANSI_GREEN = '\x1b[32m';
const ANSI_YELLOW = '\x1b[33m';
const ANSI_BLUE = '\x1b[34m';
const ANSI_MAGENTA = '\x1b[35m';
const ANSI_CYAN = '\x1b[36m';
const ANSI_WHITE = '\x1b[37m';

const ANSI_BG_BLACK = '\x1b[40m';
const ANSI_BG_RED = '\x1b[41m';
const ANSI_BG_GREEN = '\x1b[42m';
const ANSI_BG_YELLOW = '\x1b[43m';
const ANSI_BG_BLUE = '\x1b[44m';
const ANSI_BG_MAGENTA = '\x1b[45m';
const ANSI_BG_CYAN = '\x1b[46m';
const ANSI_BG_WHITE = '\x1b[47m';

const NAME_COLORS = [
  ANSI_BOLD + ANSI_RED,
  ANSI_BOLD + ANSI_GREEN,
  ANSI_BOLD + ANSI_YELLOW,
  ANSI_BOLD + ANSI_BLUE,
  ANSI_BOLD + ANSI_MAGENTA,
  ANSI_BOLD + ANSI_CYAN,
  ANSI_BOLD + ANSI_WHITE,
  ANSI_BOLD + ANSI_RED,
];

interface TagStyle {
  open: string;
  close?: boolean;
}

function normalizeTagName(tag: string): string {
  let t = tag.trim().toLowerCase().split(/\s/)[0];
  if (t.endsWith('/')) t = t.slice(0, -1);
  return t;
}

function getTagStyle(tag: string): TagStyle | null {
  const t = normalizeTagName(tag);

  switch (t) {
    case 'h1': return { open: ANSI_BOLD + ANSI_YELLOW };
    case 'h2': return { open: ANSI_BOLD + ANSI_GREEN };
    case 'h3': return { open: ANSI_BOLD + ANSI_CYAN };
    case 'h4': return { open: ANSI_BOLD + ANSI_BLUE };
    case 'h5': return { open: ANSI_BOLD + ANSI_MAGENTA };
    case 'h6': return { open: ANSI_BOLD + ANSI_WHITE };
    case 'b':
    case 'strong': return { open: ANSI_BOLD };
    case 'i':
    case 'em':
    case 'cite': return { open: ANSI_ITALIC };
    case 'u': return { open: ANSI_UNDERLINE };
    case 's':
    case 'strike': return { open: ANSI_STRIKETHROUGH };
    case 'a': return { open: ANSI_UNDERLINE + ANSI_BLUE };
    case 'code': return { open: ANSI_BG_BLACK + ANSI_CYAN };
    case 'pre': return { open: ANSI_BG_BLACK };
    case 'mark': return { open: ANSI_BG_YELLOW + ANSI_BLACK };
    case 'blockquote': return { open: ANSI_DIM };
    case 'sup': return { open: ANSI_BOLD };
    case 'sub': return { open: ANSI_DIM };
    case 'search-match': return { open: ANSI_BG_YELLOW + ANSI_BLACK + ANSI_BOLD };
    default:
      if (t.startsWith('name')) {
        const rest = t.slice(4).trim();
        const num = parseInt(rest, 10);
        if (!isNaN(num) && num < NAME_COLORS.length) {
          return { open: NAME_COLORS[num] };
        }
      }
      return null;
  }
}

function isBlockTag(tag: string): boolean {
  const blockTags = new Set([
    'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'blockquote', 'pre', 'li', 'tr', 'td', 'th',
    'section', 'article', 'nav', 'aside', 'header', 'footer',
    'br', 'hr',
  ]);
  return blockTags.has(normalizeTagName(tag));
}

function isIgnoredTag(tag: string): boolean {
  const ignored = new Set([
    'script', 'style', 'svg', 'math', 'video', 'audio', 'canvas',
    'iframe', 'embed', 'object', 'param', 'source', 'track',
  ]);
  return ignored.has(normalizeTagName(tag));
}

function htmlUnescape(text: string): string {
  const entityMap: Record<string, string> = {
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&apos;': "'",
    '&nbsp;': ' ',
    '&mdash;': '—',
    '&ndash;': '–',
    '&hellip;': '…',
    '&ldquo;': '"',
    '&rdquo;': '"',
    '&lsquo;': "'",
    '&rsquo;': "'",
  };

  return text.replace(/&(?:#[xX]?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/g, (match) => {
    if (entityMap[match]) return entityMap[match];
    if (match.startsWith('&#x') || match.startsWith('&#X')) {
      const hex = match.slice(3, -1);
      const cp = parseInt(hex, 16);
      if (!isNaN(cp)) return String.fromCodePoint(cp);
    }
    if (match.startsWith('&#')) {
      const num = match.slice(2, -1);
      const cp = parseInt(num, 10);
      if (!isNaN(cp)) return String.fromCodePoint(cp);
    }
    return match;
  });
}

export function renderToTerminal(html: string): string {
  const output: string[] = [];
  interface StyleEntry { tag: string; open: string; }
  const styleStack: StyleEntry[] = [];
  let ignoreDepth = 0;
  let lastWasBlock = true;

  let i = 0;
  while (i < html.length) {
    if (html[i] === '<') {
      const tagEnd = html.indexOf('>', i);
      if (tagEnd === -1) {
        i++;
        continue;
      }
      let tag = html.substring(i + 1, tagEnd);
      const isClose = tag.startsWith('/');
      if (isClose) tag = tag.slice(1);
      const tagName = normalizeTagName(tag);

      if (isIgnoredTag(tagName)) {
        if (isClose) {
          if (ignoreDepth > 0) ignoreDepth--;
        } else {
          ignoreDepth++;
        }
        i = tagEnd + 1;
        continue;
      }

      if (ignoreDepth > 0) {
        i = tagEnd + 1;
        continue;
      }

      if (isBlockTag(tagName)) {
        if (!lastWasBlock) {
          output.push('\n');
        }
        lastWasBlock = true;
      }

      if (isClose) {
        if (styleStack.length > 0 && styleStack[styleStack.length - 1].tag === tagName) {
          styleStack.pop();
          output.push(ANSI_RESET);
          for (const entry of styleStack) {
            output.push(entry.open);
          }
        }
      } else {
        const style = getTagStyle(tagName);
        if (style) {
          styleStack.push({ tag: tagName, open: style.open });
          output.push(style.open);
        }
      }

      i = tagEnd + 1;
    } else {
      if (ignoreDepth > 0) {
        i++;
        continue;
      }

      if (lastWasBlock && /\s/.test(html[i])) {
        i++;
        continue;
      }
      lastWasBlock = false;

      const textStart = i;
      while (i < html.length && html[i] !== '<') i++;
      const text = html.substring(textStart, i);

      // Collapse whitespace
      let j = 0;
      while (j < text.length) {
        if (/\s/.test(text[j])) {
          output.push(' ');
          j++;
          while (j < text.length && /\s/.test(text[j])) j++;
        } else {
          output.push(text[j]);
          j++;
        }
      }
    }
  }

  return htmlUnescape(output.join(''));
}

export function renderWithSearchHighlight(html: string, searchTerm: string): string {
  const marked: string[] = [];
  const lowerTerm = searchTerm.toLowerCase();

  let i = 0;
  while (i < html.length) {
    if (html[i] === '<') {
      const tagEnd = html.indexOf('>', i);
      if (tagEnd === -1) {
        marked.push(html[i]);
        i++;
        continue;
      }
      marked.push(html.substring(i, tagEnd + 1));
      i = tagEnd + 1;
    } else {
      const textEnd = html.indexOf('<', i);
      const text = textEnd === -1 ? html.substring(i) : html.substring(i, textEnd);

      let j = 0;
      while (j < text.length) {
        const remaining = text.substring(j);
        const lowerRemaining = remaining.toLowerCase();
        const match = lowerRemaining.indexOf(lowerTerm);
        if (match !== -1) {
          marked.push(text.substring(j, j + match));
          marked.push('<search-match>');
          marked.push(text.substring(j + match, j + match + searchTerm.length));
          marked.push('</search-match>');
          j += match + searchTerm.length;
        } else {
          marked.push(text.substring(j));
          break;
        }
      }

      i = textEnd === -1 ? html.length : textEnd;
    }
  }

  return renderToTerminal(marked.join(''));
}

export function injectNameTags(html: string, nameSet: Map<string, number> | null): string {
  const marked: string[] = [];

  // Build a trie for O(m) matching instead of O(n*m)
  interface TrieNode {
    children: Map<string, TrieNode>;
    isEnd: boolean;
    color: number;
  }

  const root: TrieNode = { children: new Map(), isEnd: false, color: 0 };

  if (nameSet) {
    for (const [name, color] of nameSet) {
      let node = root;
      for (const char of name) {
        if (!node.children.has(char)) {
          node.children.set(char, { children: new Map(), isEnd: false, color: 0 });
        }
        node = node.children.get(char)!;
      }
      node.isEnd = true;
      node.color = color;
    }
  }

  const NAME_OPEN_TAGS = [
    '<name0>', '<name1>', '<name2>', '<name3>',
    '<name4>', '<name5>', '<name6>', '<name7>',
  ];
  const NAME_CLOSE_TAGS = [
    '</name0>', '</name1>', '</name2>', '</name3>',
    '</name4>', '</name5>', '</name6>', '</name7>',
  ];

  let i = 0;
  while (i < html.length) {
    if (html[i] === '<') {
      const tagEnd = html.indexOf('>', i);
      if (tagEnd === -1) {
        marked.push(html[i]);
        i++;
        continue;
      }
      marked.push(html.substring(i, tagEnd + 1));
      i = tagEnd + 1;
    } else {
      const textEnd = html.indexOf('<', i);
      const text = textEnd === -1 ? html.substring(i) : html.substring(i, textEnd);

      let j = 0;
      while (j < text.length) {
        // Try trie match
        let node = root;
        let matchLen = 0;
        let matchColor = 0;
        let k = j;
        while (k < text.length) {
          const char = text[k];
          if (!node.children.has(char)) break;
          node = node.children.get(char)!;
          k += char.length;
          if (node.isEnd) {
            matchLen = k - j;
            matchColor = node.color;
          }
        }

        if (matchLen > 0) {
          marked.push(NAME_OPEN_TAGS[matchColor % NAME_OPEN_TAGS.length]);
          marked.push(text.substring(j, j + matchLen));
          marked.push(NAME_CLOSE_TAGS[matchColor % NAME_CLOSE_TAGS.length]);
          j += matchLen;
        } else {
          marked.push(text[j]);
          j++;
        }
      }

      i = textEnd === -1 ? html.length : textEnd;
    }
  }

  return marked.join('');
}
