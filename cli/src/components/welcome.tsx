import React, { useState, useEffect, useRef, useMemo, type FC } from "react";
import { Box, Text } from "ink";
import { readFileSync } from "fs";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { resolve, dirname } from "path";
import { PALETTE, colors } from "../lib/palette.js";

const CLI_VERSION = (() => {
  try {
    const dir = dirname(fileURLToPath(import.meta.url));
    const pkgPath = resolve(dir, "../../package.json");
    const pkg = JSON.parse(readFileSync(pkgPath, "utf-8")) as { version: string };
    return pkg.version;
  } catch {
    return null;
  }
})();

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

const FADE_MS = 1500;

const ROWS = SHAPE.length;
const COLS = Math.max(...SHAPE.map((l) => l.length));

function parseHex(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
}

function toHex(r: number, g: number, b: number): string {
  return `#${((r << 16) | (g << 8) | b).toString(16).padStart(6, "0")}`;
}

// Desaturate by lerping each channel toward the luminance midpoint.
function desaturate(hex: string, amount: number): string {
  const [r, g, b] = parseHex(hex);
  const lum = Math.round(r * 0.299 + g * 0.587 + b * 0.114);
  return toHex(
    Math.round(r + (lum - r) * amount),
    Math.round(g + (lum - g) * amount),
    Math.round(b + (lum - b) * amount),
  );
}

function opalColor(row: number, col: number, phase: number): string {
  const wave = Math.sin(row * 0.7 + col * 0.4) * 0.1;
  const t = ((row / ROWS) * 0.45 + (col / COLS) * 0.55 + wave + phase + 2) % 1;
  const idx = Math.floor(t * (PALETTE.length - 1));
  return PALETTE[Math.min(idx, PALETTE.length - 1)];
}

// Pre-compute the fully-dimmed color grid once (sat = 0.85, phase frozen at final value).
function computeStaticColors(finalPhase: number): { grid: string[][]; title: string } {
  const sat = 0.85;
  const grid = SHAPE.map((line, row) =>
    [...line].map((ch, col) =>
      ch === " " ? "" : desaturate(opalColor(row, col, finalPhase), sat),
    ),
  );
  return { grid, title: desaturate(colors.title, sat) };
}

export interface WelcomeProps {
  dimmed?: boolean;
  workingDir?: string;
}

const WelcomeInner: FC<WelcomeProps> = ({ dimmed = false, workingDir }) => {
  const shortCwd = workingDir ? workingDir.replace(homedir(), "~") : null;
  const versionLabel = CLI_VERSION ? `v${CLI_VERSION}` : null;
  const infoText = [versionLabel, shortCwd].filter(Boolean).join(" · ");
  const [phase, setPhase] = useState(0);
  const [mute, setMute] = useState(0);
  const fadeStart = useRef<number | null>(null);
  const finalPhaseRef = useRef(0);

  useEffect(() => {
    if (dimmed && fadeStart.current === null) {
      fadeStart.current = Date.now();
    }
  }, [dimmed]);

  // Animation slows exponentially and colors desaturate.
  // Speed: 0.04 → 0 over FADE_MS. Saturation: 1 → 0.15 (keeps a hint of color).
  useEffect(() => {
    if (mute >= 1) return;
    const id = setInterval(() => {
      let speed = 0.04;
      if (fadeStart.current !== null) {
        const t = Math.min(1, (Date.now() - fadeStart.current) / FADE_MS);
        setMute(t);
        speed = 0.04 * (1 - t) * (1 - t); // quadratic ease-out
      }
      setPhase((p) => {
        const next = (p + speed) % 1;
        finalPhaseRef.current = next;
        return next;
      });
    }, 120);
    return () => clearInterval(id);
  }, [mute >= 1]); // eslint-disable-line react-hooks/exhaustive-deps

  // Once fade is complete, pre-compute the static dimmed colors and cache them.
  const staticColors = useMemo(() => {
    if (mute < 1) return null;
    return computeStaticColors(finalPhaseRef.current);
  }, [mute >= 1]); // eslint-disable-line react-hooks/exhaustive-deps

  // Fully-static render path — no interval, no per-character computation.
  if (staticColors) {
    return (
      <Box flexDirection="column" alignItems="center" paddingX={1} marginBottom={1}>
        <Box flexDirection="column">
          {SHAPE.map((line, row) => (
            <Text key={row}>
              {[...line].map((ch, col) =>
                ch === " " ? (
                  " "
                ) : (
                  <Text key={col} color={staticColors.grid[row][col]}>
                    {ch}
                  </Text>
                ),
              )}
            </Text>
          ))}
        </Box>
        <Box marginTop={1}>
          <Text color={staticColors.title}>✦ opal</Text>
        </Box>
        {infoText && (
          <Box marginTop={0}>
            <Text dimColor>{infoText}</Text>
          </Box>
        )}
      </Box>
    );
  }

  // Animated render path — active during fade-in / fade-out.
  const sat = 0.85 * mute; // 0 → 0.85 desaturation (keeps a tint)

  return (
    <Box flexDirection="column" alignItems="center" paddingX={1} marginTop={1} marginBottom={1}>
      <Box flexDirection="column">
        {SHAPE.map((line, row) => (
          <Text key={row}>
            {[...line].map((ch, col) =>
              ch === " " ? (
                " "
              ) : (
                <Text key={col} color={desaturate(opalColor(row, col, phase), sat)}>
                  {ch}
                </Text>
              ),
            )}
          </Text>
        ))}
      </Box>
      <Box marginTop={1}>
        <Text bold={mute < 1} color={desaturate(colors.title, sat)}>
          ✦ opal
        </Text>
      </Box>
      {infoText && (
        <Box marginTop={0}>
          <Text dimColor>{infoText}</Text>
        </Box>
      )}
    </Box>
  );
};

export const Welcome = React.memo(WelcomeInner);
