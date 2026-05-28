#!/usr/bin/env node
import React, { useState } from 'react';
import { render } from 'ink';
import * as fs from 'fs';
import * as path from 'path';
import App from './App.js';
import FilePicker from './FilePicker.js';
import { Epub } from './epub.js';
import { Config } from './config.js';
import { renderToTerminal } from './html.js';

interface PickerWrapperProps {
  files: string[];
}

function PickerWrapper({ files }: PickerWrapperProps) {
  const [selectedFile, setSelectedFile] = useState<string | null>(null);

  if (!selectedFile) {
    return <FilePicker files={files} onSelect={setSelectedFile} />;
  }

  let filePathAbs: string;
  try {
    filePathAbs = fs.realpathSync(selectedFile);
  } catch (err) {
    console.error(`\x1b[1;33mWarning: could not resolve full path (${(err as Error).message}), using '${selectedFile}'\x1b[0m`);
    filePathAbs = path.resolve(selectedFile);
  }

  let config: Config;
  try {
    config = new Config();
  } catch (err) {
    console.error(`\x1b[1;33mWarning: config unavailable (${(err as Error).message})\x1b[0m`);
    config = new Config();
  }

  console.error(`\x1b[2mLoading ${selectedFile}...\x1b[0m`);

  let epub: Epub;
  try {
    epub = Epub.load(filePathAbs);
  } catch (err) {
    console.error(`\x1b[1;31mError loading EPUB: ${(err as Error).message}\x1b[0m`);
    process.exit(1);
  }

  console.error(`\x1b[2mLoaded ${epub.chapters.length} chapters.\x1b[0m`);

  return <App epub={epub} bookPath={filePathAbs} config={config} />;
}

function main() {
  const args = process.argv.slice(2);

  if (args.length >= 1) {
    const filePath = args[0];

    try {
      fs.accessSync(filePath);
    } catch {
      console.error(`\x1b[1;31mError: Cannot open file '${filePath}'\x1b[0m`);
      process.exit(1);
    }

    let filePathAbs: string;
    try {
      filePathAbs = fs.realpathSync(filePath);
    } catch (err) {
      console.error(`\x1b[1;33mWarning: could not resolve full path (${(err as Error).message}), using '${filePath}'\x1b[0m`);
      filePathAbs = path.resolve(filePath);
    }

    let config: Config;
    try {
      config = new Config();
    } catch (err) {
      console.error(`\x1b[1;33mWarning: config unavailable (${(err as Error).message})\x1b[0m`);
      config = new Config();
    }

    console.error(`\x1b[2mLoading ${filePath}...\x1b[0m`);

    let epub: Epub;
    try {
      epub = Epub.load(filePathAbs);
    } catch (err) {
      console.error(`\x1b[1;31mError loading EPUB: ${(err as Error).message}\x1b[0m`);
      process.exit(1);
    }

    console.error(`\x1b[2mLoaded ${epub.chapters.length} chapters.\x1b[0m`);

    if (!process.stdin.isTTY) {
      console.error('\x1b[1;33mWarning: stdin is not a TTY. Falling back to plain text output.\x1b[0m');
      const content = epub.getChapterContent(0);
      if (content) {
        const rendered = renderToTerminal(content);
        console.log(rendered);
      }
      process.exit(0);
    }

    render(<App epub={epub} bookPath={filePathAbs} config={config} />);
    return;
  }

  // No argument: scan current directory for EPUB files
  const cwd = process.cwd();
  let files: string[];
  try {
    files = fs.readdirSync(cwd)
      .filter(f => f.toLowerCase().endsWith('.epub'))
      .sort((a, b) => a.localeCompare(b));
  } catch (err) {
    console.error(`\x1b[1;31mError reading directory: ${(err as Error).message}\x1b[0m`);
    process.exit(1);
  }

  if (files.length === 0) {
    console.error('\x1b[1;31mNo EPUB files found in current directory.\x1b[0m');
    console.error(`\x1b[2mDirectory: ${cwd}\x1b[0m`);
    process.exit(1);
  }

  if (!process.stdin.isTTY) {
    console.error('\x1b[1;33mWarning: stdin is not a TTY. Cannot show file picker.\x1b[0m');
    process.exit(1);
  }

  render(<PickerWrapper files={files} />);
}

main();
