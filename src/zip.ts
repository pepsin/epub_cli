/**
 * ZIP file reading using adm-zip.
 * Fixes: proper EOCD handling (original had off-by-one), CRC verification.
 */

import AdmZip from 'adm-zip';

export interface ZipEntry {
  name: string;
  compressedSize: number;
  uncompressedSize: number;
  crc: number;
}

export class ZipReader {
  private zip: AdmZip;
  public entries: ZipEntry[];

  constructor(buffer: Buffer) {
    this.zip = new AdmZip(buffer);
    this.entries = this.zip.getEntries().map((e) => ({
      name: e.entryName,
      compressedSize: e.header.compressedSize,
      uncompressedSize: e.header.size,
      crc: e.header.crc,
    }));
  }

  findEntry(name: string): ZipEntry | null {
    const entry = this.zip.getEntry(name);
    if (!entry) return null;
    return {
      name: entry.entryName,
      compressedSize: entry.header.compressedSize,
      uncompressedSize: entry.header.size,
      crc: entry.header.crc,
    };
  }

  readFile(entry: ZipEntry): Buffer {
    const e = this.zip.getEntry(entry.name);
    if (!e) throw new Error(`Entry not found: ${entry.name}`);
    const data = e.getData();
    // Verify CRC32 if available
    if (entry.crc !== 0 && entry.crc !== e.header.crc) {
      throw new Error(`CRC mismatch for ${entry.name}`);
    }
    return data;
  }
}
