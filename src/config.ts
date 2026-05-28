/**
 * JSON persistence layer for reading progress.
 * Fixes: uses os.homedir() instead of $HOME for portability.
 */

import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

export interface BookProgress {
  chapter: number;
  last_opened: number;
  names: boolean;
}

export class Config {
  private path: string;
  private books: Map<string, BookProgress>;
  private detectedNames: Map<string, string[]>;

  constructor() {
    const home = os.homedir();
    this.path = path.join(home, '.epub_repl.json');
    this.books = new Map();
    this.detectedNames = new Map();
    this.load();
  }

  private load(): void {
    try {
      const content = fs.readFileSync(this.path, 'utf-8');
      const data = JSON.parse(content);
      if (typeof data !== 'object' || data === null) return;

      for (const [bookPath, obj] of Object.entries(data)) {
        if (typeof obj !== 'object' || obj === null) continue;
        const o = obj as Record<string, unknown>;

        const chapter = typeof o.chapter === 'number' ? o.chapter : 0;
        const last_opened = typeof o.last_opened === 'number' ? o.last_opened : 0;
        const names = typeof o.names === 'boolean' ? o.names : false;

        this.books.set(bookPath, { chapter, last_opened, names });

        if (Array.isArray(o.detected_names)) {
          const dnList = o.detected_names.filter((n): n is string => typeof n === 'string');
          if (dnList.length > 0) {
            this.detectedNames.set(bookPath, dnList);
          }
        }
      }
    } catch (err) {
      // File not found or parse error - start fresh
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
        console.warn(`Warning: could not read config: ${(err as Error).message}`);
      }
    }
  }

  getProgress(bookPath: string): number | null {
    const entry = this.books.get(bookPath);
    return entry ? entry.chapter : null;
  }

  getNames(bookPath: string): boolean {
    const entry = this.books.get(bookPath);
    return entry ? entry.names : false;
  }

  setProgress(bookPath: string, chapter: number, namesOn: boolean): void {
    this.books.set(bookPath, {
      chapter,
      last_opened: Date.now(),
      names: namesOn,
    });
    this.save();
  }

  setDetectedNames(bookPath: string, nameList: string[]): void {
    if (nameList.length === 0) {
      this.detectedNames.delete(bookPath);
    } else {
      this.detectedNames.set(bookPath, nameList);
    }
    this.save();
  }

  loadNameSet(bookPath: string): Map<string, number> | null {
    const entry = this.detectedNames.get(bookPath);
    if (!entry) return null;

    const set = new Map<string, number>();
    for (let i = 0; i < entry.length; i++) {
      set.set(entry[i], i % 8);
    }
    return set;
  }

  private save(): void {
    const data: Record<string, unknown> = {};
    for (const [bookPath, progress] of this.books) {
      data[bookPath] = {
        chapter: progress.chapter,
        last_opened: progress.last_opened,
        names: progress.names,
        detected_names: this.detectedNames.get(bookPath) || [],
      };
    }

    try {
      fs.writeFileSync(this.path, JSON.stringify(data, null, 2) + '\n');
    } catch (err) {
      // Silently fail
    }
  }
}
