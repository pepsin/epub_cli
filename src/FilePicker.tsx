import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';

interface FilePickerProps {
  files: string[];
  onSelect: (file: string) => void;
}

export default function FilePicker({ files, onSelect }: FilePickerProps) {
  const [selected, setSelected] = useState(0);

  useInput((input, key) => {
    if (key.upArrow || input === 'k') {
      setSelected(prev => Math.max(0, prev - 1));
    } else if (key.downArrow || input === 'j') {
      setSelected(prev => Math.min(files.length - 1, prev + 1));
    } else if (key.return) {
      onSelect(files[selected]);
    } else if (input === 'q') {
      process.exit(0);
    }
  });

  return (
    <Box flexDirection="column" padding={1}>
      <Text bold color="magenta">{'╔══════════════════════════════════════╗'}</Text>
      <Text bold color="magenta">{'║      📚 Select an EPUB to read       ║'}</Text>
      <Text bold color="magenta">{'╚══════════════════════════════════════╝'}</Text>
      <Box marginTop={1} flexDirection="column">
        {files.map((file, idx) => {
          const marker = idx === selected ? '▶' : ' ';
          return (
            <Text key={file}>
              <Text color="cyan">{marker}</Text>
              <Text bold>{` ${String(idx + 1).padStart(3)}.`}</Text>
              {` ${file}`}
            </Text>
          );
        })}
      </Box>
      <Box marginTop={1}>
        <Text dimColor>[↑/↓/j/k] move  [Enter] select  [q] quit</Text>
      </Box>
    </Box>
  );
}
