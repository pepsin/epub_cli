/**
 * CJK character width utilities.
 * Fixes: handles 4-byte CJK extension characters correctly.
 */

export function utf8ByteLength(text: string, index: number): number {
  const c = text.charCodeAt(index);
  if (c <= 0x7f) return 1;
  if ((c & 0xe0) === 0xc0) return 2;
  if ((c & 0xf0) === 0xe0) return 3;
  if ((c & 0xf8) === 0xf0) return 4;
  return 1;
}

export function codePointAt(text: string, index: number): { cp: number; len: number } | null {
  const c = text.charCodeAt(index);
  if (index >= text.length) return null;
  if (c <= 0x7f) return { cp: c, len: 1 };

  // Use String.prototype.codePointAt for proper surrogate pair handling
  const cp = text.codePointAt(index);
  if (cp === undefined) return null;
  const len = cp > 0xffff ? 2 : 1;
  return { cp, len };
}

export function isCjkChar(cp: number): boolean {
  // CJK Unified Ideographs
  if (cp >= 0x4e00 && cp <= 0x9fff) return true;
  // CJK Unified Ideographs Extension A
  if (cp >= 0x3400 && cp <= 0x4dbf) return true;
  // CJK Unified Ideographs Extension B (4-byte)
  if (cp >= 0x20000 && cp <= 0x2a6df) return true;
  // CJK Unified Ideographs Extension C (4-byte)
  if (cp >= 0x2a700 && cp <= 0x2b73f) return true;
  // CJK Unified Ideographs Extension D (4-byte)
  if (cp >= 0x2b740 && cp <= 0x2b81f) return true;
  // CJK Unified Ideographs Extension E (4-byte)
  if (cp >= 0x2b820 && cp <= 0x2ceaf) return true;
  // CJK Unified Ideographs Extension F (4-byte)
  if (cp >= 0x2ceb0 && cp <= 0x2ebef) return true;
  // CJK Compatibility Ideographs
  if (cp >= 0xf900 && cp <= 0xfaff) return true;
  // CJK Compatibility Ideographs Supplement (4-byte)
  if (cp >= 0x2f800 && cp <= 0x2fa1f) return true;
  return false;
}

export function isWideChar(cp: number): boolean {
  if (isCjkChar(cp)) return true;

  // CJK Symbols and Punctuation
  if (cp >= 0x3000 && cp <= 0x303f) return true;
  // Halfwidth and Fullwidth Forms
  if (cp >= 0xff01 && cp <= 0xff60) return true;
  if (cp >= 0xffe0 && cp <= 0xffe6) return true;
  // General Punctuation (East Asian Ambiguous / Wide)
  if (cp >= 0x2013 && cp <= 0x2046) return true;
  // Currency Symbols
  if (cp >= 0x20a0 && cp <= 0x20cf) return true;
  // Letterlike Symbols
  if (cp >= 0x2100 && cp <= 0x214f) return true;
  // Arrows
  if (cp >= 0x2190 && cp <= 0x21ff) return true;
  // Mathematical Operators
  if (cp >= 0x2200 && cp <= 0x22ff) return true;
  // Enclosed Alphanumerics
  if (cp >= 0x2460 && cp <= 0x24ff) return true;
  // Geometric Shapes
  if (cp >= 0x25a0 && cp <= 0x25ff) return true;
  // Miscellaneous Symbols
  if (cp >= 0x2600 && cp <= 0x26ff) return true;
  // CJK Radicals Supplement
  if (cp >= 0x2e80 && cp <= 0x2eff) return true;
  // Kangxi Radicals
  if (cp >= 0x2f00 && cp <= 0x2fdf) return true;
  // Ideographic Description Characters
  if (cp >= 0x2ff0 && cp <= 0x2fff) return true;
  // Hiragana
  if (cp >= 0x3040 && cp <= 0x309f) return true;
  // Katakana
  if (cp >= 0x30a0 && cp <= 0x30ff) return true;
  // Bopomofo
  if (cp >= 0x3100 && cp <= 0x312f) return true;
  // CJK Strokes
  if (cp >= 0x31c0 && cp <= 0x31ef) return true;
  // Enclosed CJK Letters and Months
  if (cp >= 0x3200 && cp <= 0x32ff) return true;
  // CJK Compatibility
  if (cp >= 0x3300 && cp <= 0x33ff) return true;
  // Yijing Hexagram Symbols
  if (cp >= 0x4dc0 && cp <= 0x4dff) return true;
  // CJK Compatibility Forms
  if (cp >= 0xfe30 && cp <= 0xfe4f) return true;

  return false;
}

/**
 * Calculate display width of a string, accounting for ANSI escape codes and CJK chars.
 */
export function displayWidth(text: string): number {
  let width = 0;
  let i = 0;
  while (i < text.length) {
    // Skip ANSI escape sequences
    if (text.charCodeAt(i) === 0x1b && i + 1 < text.length && text[i + 1] === '[') {
      i += 2;
      while (i < text.length && /[0-9;?]/.test(text[i])) i++;
      if (i < text.length) i++; // skip command char
      continue;
    }
    const decoded = codePointAt(text, i);
    if (!decoded) {
      i++;
      width++;
      continue;
    }
    width += isWideChar(decoded.cp) ? 2 : 1;
    i += decoded.len;
  }
  return width;
}

/**
 * Calculate how many terminal rows a line takes given column width.
 */
export function physicalRows(line: string, cols: number): number {
  const w = displayWidth(line);
  return w === 0 ? 1 : Math.ceil(w / cols);
}

/**
 * Get the text of a specific terminal row from a logical line.
 * Preserves ANSI codes and limits output to at most `cols` display width.
 */
export function sliceFromRow(line: string, startRow: number, cols: number): string {
  const startWidth = startRow * cols;
  const endWidth = (startRow + 1) * cols;
  let width = 0;
  let i = 0;
  let result = '';

  while (i < line.length && width < endWidth) {
    // Preserve ANSI codes within the visible row
    if (line.charCodeAt(i) === 0x1b && i + 1 < line.length && line[i + 1] === '[') {
      const ansiStart = i;
      i += 2;
      while (i < line.length && /[0-9;?]/.test(line[i])) i++;
      if (i < line.length) i++;
      if (width >= startWidth) {
        result += line.substring(ansiStart, i);
      }
      continue;
    }

    const decoded = codePointAt(line, i);
    if (!decoded) {
      if (width >= startWidth) {
        result += line[i];
      }
      width++;
      i++;
      continue;
    }
    const charWidth = isWideChar(decoded.cp) ? 2 : 1;

    if (width >= startWidth) {
      if (width + charWidth > endWidth) {
        break;
      }
      result += line.substring(i, i + decoded.len);
    } else if (width + charWidth > startWidth) {
      // Wide character straddles the start boundary — include it in this row
      result += line.substring(i, i + decoded.len);
    }

    width += charWidth;
    i += decoded.len;
  }

  return result;
}
