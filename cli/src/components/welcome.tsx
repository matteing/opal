import React, { useState, useEffect, type FC } from "react";
import { Box, Text } from "ink";

// Polished opal cabochon — smooth oval with ±2 char transitions per side.
const SHAPE = [
  "      ▄▄████▄▄",
  "    ▄██████████▄",
  "  ████████████████",
  "████████████████████",
  "████████████████████",
  "  ▀██████████████▀",
  "    ▀██████████▀",
  "      ▀▀████▀▀",
];

// Iridescent opal palette — loops back to start for seamless wrap.
const PALETTE = [
  "#818cf8", "#7678f4", "#6b6af0", "#6366f1",
  "#5a75f7", "#4e8bfd", "#38a5f5", "#22bde8",
  "#22d3ee", "#28dcd8", "#2dd4bf", "#34d399",
  "#56dc84", "#84e365", "#a3e635", "#c4de22",
  "#e2d31e", "#fbbf24", "#fba030", "#fb923c",
  "#f87c50", "#f47272", "#f26492", "#f472b6",
  "#e46cc8", "#d46ede", "#c084fc", "#ae86fa",
  "#9b89f9", "#818cf8",
];

const ROWS = SHAPE.length;
const COLS = Math.max(...SHAPE.map((l) => l.length));

function opalColor(row: number, col: number, phase: number): string {
  const wave = Math.sin(row * 0.7 + col * 0.4) * 0.1;
  const t = ((row / ROWS) * 0.45 + (col / COLS) * 0.55 + wave + phase + 2) % 1;
  const idx = Math.floor(t * (PALETTE.length - 1));
  return PALETTE[Math.min(idx, PALETTE.length - 1)]!;
}

export const Welcome: FC = () => {
  const [phase, setPhase] = useState(0);

  useEffect(() => {
    const id = setInterval(() => {
      setPhase((p) => (p + 0.04) % 1);
    }, 80);
    return () => clearInterval(id);
  }, []);

  return (
    <Box flexDirection="column" alignItems="center" paddingX={1} marginBottom={1}>
      <Box flexDirection="column">
        {SHAPE.map((line, row) => (
          <Text key={row}>
            {[...line].map((ch, col) =>
              ch === " " ? (
                " "
              ) : (
                <Text key={col} color={opalColor(row, col, phase)}>
                  {ch}
                </Text>
              ),
            )}
          </Text>
        ))}
      </Box>
      <Box marginTop={1}>
        <Text bold color="magenta">
          ✦ opal
        </Text>
      </Box>
      <Box marginTop={1}>
        <Text>What can I help you with?</Text>
      </Box>
    </Box>
  );
};
