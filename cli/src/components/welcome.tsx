import React, { useState, useEffect, useRef, useMemo, type FC } from "react";
import { Box, Text } from "ink";
import { readFileSync } from "fs";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { resolve, dirname } from "path";
import { PALETTE, colors } from "../lib/palette.js";
import { toRootRelativePath } from "../lib/formatting.js";

// ── Constants ────────────────────────────────────────────────────

const CLI_VERSION = (() => {
  try {
    const dir = dirname(fileURLToPath(import.meta.url));
    const pkg = JSON.parse(readFileSync(resolve(dir, "../../package.json"), "utf-8")) as {
      version: string;
    };
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

const ROWS = SHAPE.length;
const COLS = Math.max(...SHAPE.map((l) => l.length));
const FADE_MS = 1500;

// ── Color helpers ────────────────────────────────────────────────

function parseHex(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
}

function toHex(r: number, g: number, b: number): string {
  return `#${((r << 16) | (g << 8) | b).toString(16).padStart(6, "0")}`;
}

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

function computeStaticColors(finalPhase: number): { grid: string[][]; title: string } {
  const sat = 0.85;
  const grid = SHAPE.map((line, row) =>
    [...line].map((ch, col) =>
      ch === " " ? "" : desaturate(opalColor(row, col, finalPhase), sat),
    ),
  );
  return { grid, title: desaturate(colors.title, sat) };
}

// ── Gem renderer ─────────────────────────────────────────────────

const Gem: FC<{ colorAt: (row: number, col: number) => string }> = ({ colorAt }) => (
  <Box flexDirection="column">
    {SHAPE.map((line, row) => (
      <Text key={row}>
        {[...line].map((ch, col) =>
          ch === " " ? (
            " "
          ) : (
            <Text key={col} color={colorAt(row, col)}>
              {ch}
            </Text>
          ),
        )}
      </Text>
    ))}
  </Box>
);

// ── Subtitle lines ───────────────────────────────────────────────

const Subtitle: FC<{ text: string; color?: string; dimColor?: boolean }> = ({
  text,
  color,
  dimColor,
}) => (
  <Box>
    <Text color={color} dimColor={dimColor}>
      {text}
    </Text>
  </Box>
);

// ── Main component ───────────────────────────────────────────────

export interface WelcomeProps {
  dimmed?: boolean;
  workingDir?: string;
  contextFiles?: readonly string[];
  skills?: readonly string[];
}

const WelcomeInner: FC<WelcomeProps> = ({
  dimmed = false,
  workingDir,
  contextFiles = [],
  skills = [],
}) => {
  // Build subtitle strings
  const shortCwd = workingDir?.replace(homedir(), "~");
  const infoText = [CLI_VERSION ? `v${CLI_VERSION}` : null, shortCwd].filter(Boolean).join(" · ");

  const discoveryParts: string[] = [];
  if (contextFiles.length > 0) {
    discoveryParts.push(contextFiles.map((f) => toRootRelativePath(f, workingDir)).join(", "));
  }
  if (skills.length > 0) {
    discoveryParts.push(`${skills.length} skill${skills.length > 1 ? "s" : ""}`);
  }
  const discoveryText = discoveryParts.join(" · ") || null;

  // Animation state
  const [phase, setPhase] = useState(0);
  const [mute, setMute] = useState(0);
  const fadeStart = useRef<number | null>(null);
  const finalPhaseRef = useRef(0);

  useEffect(() => {
    if (dimmed && fadeStart.current === null) fadeStart.current = Date.now();
  }, [dimmed]);

  // Iridescent animation — slows exponentially and desaturates during fade.
  useEffect(() => {
    if (mute >= 1) return;
    const id = setInterval(() => {
      let speed = 0.04;
      if (fadeStart.current !== null) {
        const t = Math.min(1, (Date.now() - fadeStart.current) / FADE_MS);
        setMute(t);
        speed *= (1 - t) * (1 - t);
      }
      setPhase((p) => {
        const next = (p + speed) % 1;
        finalPhaseRef.current = next;
        return next;
      });
    }, 120);
    return () => clearInterval(id);
  }, [mute >= 1]); // eslint-disable-line react-hooks/exhaustive-deps

  // Once fully dimmed, freeze into a static color grid.
  const staticColors = useMemo(() => {
    if (mute < 1) return null;
    return computeStaticColors(finalPhaseRef.current);
  }, [mute >= 1]); // eslint-disable-line react-hooks/exhaustive-deps

  // Color functions for the two render modes
  const sat = 0.85 * mute;
  const colorAt = staticColors
    ? (row: number, col: number) => staticColors.grid[row][col]
    : (row: number, col: number) => desaturate(opalColor(row, col, phase), sat);
  const titleColor = staticColors ? staticColors.title : desaturate(colors.title, sat);
  const isAnimating = !staticColors;

  return (
    <Box flexDirection="column" alignItems="center" paddingX={1} marginY={1} marginX={1}>
      <Gem colorAt={colorAt} />
      <Box marginTop={1}>
        <Text bold={isAnimating} color={titleColor}>
          ✦ opal
        </Text>
      </Box>
      {infoText && <Subtitle text={infoText} dimColor />}
      {discoveryText && <Subtitle text={discoveryText} color="#555" />}
    </Box>
  );
};;

export const Welcome = React.memo(WelcomeInner);
