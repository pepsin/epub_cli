/**
 * EPUB loader.
 * Reads ZIP archive, parses container.xml, OPF manifest, spine, and NCX/TOC.
 * Fixes: body tag fallback no longer drops first character.
 */

import * as fs from 'fs';
import { ZipReader, ZipEntry } from './zip.js';
import { SimpleXml } from './xml.js';

export interface Chapter {
  id: string;
  title: string;
  href: string;
  content: string | null;
}

export class Epub {
  private data: Buffer;
  private zip: ZipReader;
  private opfDir: string;
  public title: string | null;
  public author: string | null;
  public chapters: Chapter[];
  private spine: string[];

  constructor(data: Buffer) {
    this.data = data;
    this.zip = new ZipReader(data);
    this.opfDir = '';
    this.title = null;
    this.author = null;
    this.chapters = [];
    this.spine = [];
  }

  static load(filePath: string): Epub {
    const data = fs.readFileSync(filePath);
    const epub = new Epub(data);
    epub.parseContainer();
    epub.parseOpf();
    epub.parseNcxOrNav();
    return epub;
  }

  static loadFromBuffer(data: Buffer): Epub {
    const epub = new Epub(data);
    epub.parseContainer();
    epub.parseOpf();
    epub.parseNcxOrNav();
    return epub;
  }

  private parseContainer(): void {
    const entry = this.zip.findEntry('META-INF/container.xml');
    if (!entry) throw new Error('No container.xml found');

    const content = this.zip.readFile(entry).toString('utf-8');
    const xml = new SimpleXml(content);
    const rootfilePath = xml.getAttrValue('rootfile', 'full-path');
    if (!rootfilePath) throw new Error('No rootfile found');

    const lastSlash = rootfilePath.lastIndexOf('/');
    this.opfDir = lastSlash !== -1 ? rootfilePath.substring(0, lastSlash + 1) : '';
  }

  private parseOpf(): void {
    const opfPath = this.opfDir + 'content.opf';
    let entry: ZipEntry | null = this.zip.findEntry(opfPath);

    if (!entry) {
      // Try to find any .opf file
      for (const e of this.zip.entries) {
        if (e.name.endsWith('.opf')) {
          entry = e;
          break;
        }
      }
    }

    if (!entry) throw new Error('No OPF file found');

    const content = this.zip.readFile(entry).toString('utf-8');
    const xml = new SimpleXml(content);

    // Try to get title
    const title = xml.getTextUntil('dc:title');
    if (title) this.title = title;

    // Try to get author
    xml.pos = 0;
    const author = xml.getTextUntil('dc:creator');
    if (author) this.author = author;

    // Parse manifest items
    const manifestIds = new Map<string, string>();

    let searchPos = 0;
    while (searchPos < content.length) {
      const tagStart = content.indexOf('<item ', searchPos);
      if (tagStart === -1) break;
      const tagEnd = content.indexOf('>', tagStart);
      if (tagEnd === -1) break;
      const tag = content.substring(tagStart, tagEnd);

      const idMatch = tag.match(/id="([^"]+)"/);
      const hrefMatch = tag.match(/href="([^"]+)"/);
      const mediaMatch = tag.match(/media-type="([^"]+)"/);

      if (idMatch && hrefMatch && mediaMatch) {
        const mediaType = mediaMatch[1];
        if (mediaType.startsWith('application/xhtml') || mediaType.startsWith('text/html')) {
          const fullHref = this.opfDir + hrefMatch[1];
          manifestIds.set(idMatch[1], fullHref);
        }
      }
      searchPos = tagEnd + 1;
    }

    // Parse spine
    xml.pos = 0;
    while (xml.pos < content.length) {
      const tagStart = content.indexOf('<itemref ', xml.pos);
      if (tagStart === -1) break;
      const tagEnd = content.indexOf('>', tagStart);
      if (tagEnd === -1) break;
      const tag = content.substring(tagStart, tagEnd);

      const idrefMatch = tag.match(/idref="([^"]+)"/);
      if (idrefMatch) {
        this.spine.push(idrefMatch[1]);
      }
      xml.pos = tagEnd + 1;
    }

    // Create chapters from spine
    for (const idref of this.spine) {
      const href = manifestIds.get(idref);
      if (href) {
        this.chapters.push({
          id: idref,
          title: idref,
          href,
          content: null,
        });
      }
    }
  }

  private parseNcxOrNav(): void {
    const ncxPath = this.opfDir + 'toc.ncx';
    let entry = this.zip.findEntry(ncxPath);

    if (!entry) {
      for (const e of this.zip.entries) {
        if (e.name.endsWith('.ncx')) {
          entry = e;
          break;
        }
      }
    }

    if (!entry) return;

    const content = this.zip.readFile(entry).toString('utf-8');
    this.parseNcx(content);
  }

  private parseNcx(content: string): void {
    interface NavEntry {
      href: string;
      title: string;
    }
    const entries: NavEntry[] = [];

    let searchPos = 0;
    while (searchPos < content.length) {
      const navpointStart = content.indexOf('<navPoint', searchPos);
      if (navpointStart === -1) break;
      const navpointEnd = content.indexOf('>', navpointStart);
      if (navpointEnd === -1) break;

      const navpointClose = content.indexOf('</navPoint>', navpointEnd);
      if (navpointClose === -1) break;
      const navpointContent = content.substring(navpointEnd + 1, navpointClose);

      const textStart = navpointContent.indexOf('<text>');
      if (textStart === -1) {
        searchPos = navpointClose + 1;
        continue;
      }
      const textEnd = navpointContent.indexOf('</text>', textStart);
      if (textEnd === -1) {
        searchPos = navpointClose + 1;
        continue;
      }
      const text = navpointContent.substring(textStart + 6, textEnd).trim();

      const srcMatch = navpointContent.match(/src="([^"]+)"/);
      if (srcMatch) {
        const src = srcMatch[1];
        const hashIdx = src.indexOf('#');
        const srcClean = hashIdx !== -1 ? src.substring(0, hashIdx) : src;
        const fullSrc = this.opfDir + srcClean;
        entries.push({ href: fullSrc, title: text });
      }

      searchPos = navpointClose + 1;
    }

    // Update chapter titles - use last matching entry
    for (const ch of this.chapters) {
      let foundTitle: string | null = null;
      for (const e of entries) {
        if (e.href === ch.href) {
          foundTitle = e.title;
        }
      }
      if (foundTitle) {
        ch.title = foundTitle;
      }
    }
  }

  getChapterContent(chapterIdx: number): string | null {
    if (chapterIdx >= this.chapters.length) return null;

    const ch = this.chapters[chapterIdx];
    if (ch.content !== null) return ch.content;

    const entry = this.zip.findEntry(ch.href);
    if (!entry) return null;

    const rawContent = this.zip.readFile(entry).toString('utf-8');

    // Strip HTML head/body tags, keep body content
    const bodyStart = rawContent.indexOf('<body');
    if (bodyStart !== -1) {
      const bodyTagEnd = rawContent.indexOf('>', bodyStart);
      // Fix: if no > found after <body, use bodyStart instead of 1 (which would skip first char)
      const contentStart = bodyTagEnd !== -1 ? bodyTagEnd + 1 : bodyStart;
      const bodyClose = rawContent.lastIndexOf('</body>');
      const bodyContent = bodyClose !== -1
        ? rawContent.substring(contentStart, bodyClose)
        : rawContent.substring(contentStart);
      ch.content = bodyContent;
    } else {
      ch.content = rawContent;
    }

    return ch.content;
  }

  getChapterByHref(href: string): number | null {
    for (let i = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].href === href) return i;
    }
    return null;
  }
}
