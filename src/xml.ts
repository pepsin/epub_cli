/**
 * Lightweight XML string-scanning utilities.
 * Mirrors the original Zig xml.zig behavior.
 */

export class SimpleXml {
  private content: string;
  public pos: number;

  constructor(content: string) {
    this.content = content;
    this.pos = 0;
  }

  /**
   * Find the first occurrence of an attribute value in a tag.
   * e.g. getAttrValue("rootfile", "full-path") finds <rootfile full-path="...">.
   * Uses word boundary to avoid matching <rootfiles> when looking for <rootfile>.
   */
  getAttrValue(tagName: string, attrName: string): string | null {
    // Search with word boundary: tag must be followed by space, >, />, tab, newline, or \r
    const searchStart = this.pos;
    let tagStart = -1;
    let pos = searchStart;
    while (true) {
      const found = this.content.indexOf(`<${tagName}`, pos);
      if (found === -1) break;
      const afterTag = found + 1 + tagName.length;
      if (afterTag < this.content.length) {
        const ch = this.content[afterTag];
        if (ch === ' ' || ch === '>' || ch === '/' || ch === '\t' || ch === '\n' || ch === '\r') {
          tagStart = found;
          break;
        }
      } else {
        tagStart = found;
        break;
      }
      pos = found + 1;
    }
    if (tagStart === -1) return null;

    const tagEnd = this.content.indexOf('>', tagStart);
    if (tagEnd === -1) return null;

    const attrPrefix = `${attrName}="`;
    const attrStart = this.content.indexOf(attrPrefix, tagStart);
    if (attrStart === -1 || attrStart > tagEnd) return null;

    const valStart = attrStart + attrPrefix.length;
    const valEnd = this.content.indexOf('"', valStart);
    if (valEnd === -1) return null;

    return this.content.substring(valStart, valEnd);
  }

  /**
   * Get text content until a closing tag is found.
   * Uses word boundary to avoid matching similar tag names.
   */
  getTextUntil(tagName: string): string | null {
    const closeTag = `</${tagName}>`;

    let tagStart = -1;
    let pos = this.pos;
    while (true) {
      const found = this.content.indexOf(`<${tagName}`, pos);
      if (found === -1) break;
      const afterTag = found + 1 + tagName.length;
      if (afterTag < this.content.length) {
        const ch = this.content[afterTag];
        if (ch === ' ' || ch === '>' || ch === '/' || ch === '\t' || ch === '\n' || ch === '\r') {
          tagStart = found;
          break;
        }
      } else {
        tagStart = found;
        break;
      }
      pos = found + 1;
    }
    if (tagStart === -1) return null;

    const contentStart = this.content.indexOf('>', tagStart);
    if (contentStart === -1) return null;

    const contentEnd = this.content.indexOf(closeTag, contentStart);
    if (contentEnd === -1) return null;

    this.pos = contentEnd + closeTag.length;
    return this.content.substring(contentStart + 1, contentEnd).trim();
  }
}
