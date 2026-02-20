import React, { useState, useEffect, useMemo, useRef, type FC } from "react";
import { Box, Text } from "ink";
import { PALETTE } from "../lib/palette.js";
import { useViewport } from "../hooks/use-viewport.js";

// ── Character sets ───────────────────────────────────────────────

const GLYPHS =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@#$%&*+=<>~^|/\\:.";

function randomGlyph(): string {
  return GLYPHS[Math.floor(Math.random() * GLYPHS.length)]!;
}

// ── Colour helpers ───────────────────────────────────────────────

const BG_COLOR = "#1e2040";

function shimmerColor(i: number, len: number, phase: number): string {
  const t = ((i / Math.max(len, 1)) * 0.6 + phase + 2) % 1;
  const idx = Math.floor(t * (PALETTE.length - 1));
  return PALETTE[Math.min(idx, PALETTE.length - 1)]!;
}

// ── Burst system ─────────────────────────────────────────────────
//
// Each burst is a radial sparkle animation: a bright core appears,
// expands outward as a ring of decorative characters, then fades.

interface Burst {
  cx: number;
  cy: number;
  age: number;
  maxAge: number;
  hue: number; // 0..1 position in PALETTE
}

const CORE_CHARS = ["✦", "✧", "◆", "⟡", "∗", "◇"];
const RING_CHARS = ["·", "∘", "°", "•", "⋅", "╌", "╍"];

interface CellOverride {
  char: string;
  color: string;
  bold: boolean;
  dim: boolean;
}

function burstCell(burst: Burst, dx: number, dy: number): CellOverride | null {
  const dist = Math.sqrt(dx * dx + (dy * 2) * (dy * 2)); // stretch Y for terminal aspect
  const t = burst.age / burst.maxAge; // 0..1 progress
  const radius = t * 4;

  if (dist > radius + 0.8) return null;

  // Hue shifts as the burst ages — trails through the opal palette
  const hue = (burst.hue + t * 0.4) % 1;
  const palIdx = Math.floor(hue * (PALETTE.length - 1));
  const color = PALETTE[Math.min(palIdx, PALETTE.length - 1)]!;

  // Bright core — shrinks as burst expands
  if (dist < 1.0 - t * 0.6) {
    if (t > 0.75) return { char: "·", color, bold: false, dim: true };
    return {
      char: CORE_CHARS[Math.floor(Math.random() * CORE_CHARS.length)]!,
      color,
      bold: true,
      dim: false,
    };
  }

  // Expanding wavefront ring
  const waveDist = Math.abs(dist - radius);
  if (waveDist < 1.2) {
    const fading = t > 0.5;
    // Pick char based on angle for variety
    const angle = Math.atan2(dy, dx);
    const charIdx = Math.abs(Math.floor(angle * 3)) % RING_CHARS.length;
    return {
      char: fading
        ? (RING_CHARS[charIdx] ?? "·")
        : (CORE_CHARS[charIdx % CORE_CHARS.length] ?? "✧"),
      color,
      bold: !fading,
      dim: fading,
    };
  }

  // Inner glow — faint trail behind the wavefront
  if (dist < radius - 0.5 && t < 0.7) {
    return { char: "·", color, bold: false, dim: true };
  }

  return null;
}

// ── StartingView ─────────────────────────────────────────────────

export const StartingView: FC = () => {
  const { width, height } = useViewport();
  const [phase, setPhase] = useState(0);
  const [bursts, setBursts] = useState<Burst[]>([]);

  // Static background grid — generated once
  const bgGrid = useMemo(
    () => Array.from({ length: width * height }, randomGlyph),
    [width, height],
  );

  const sizeRef = useRef({ width, height });
  sizeRef.current = { width, height };

  useEffect(() => {
    const id = setInterval(() => {
      setPhase((p) => (p + 0.05) % 1);

      setBursts((prev) => {
        const { width: w, height: h } = sizeRef.current;

        // Age and cull
        const alive = prev
          .map((b) => ({ ...b, age: b.age + 1 }))
          .filter((b) => b.age < b.maxAge);

        // Spawn new burst — ~60% chance per tick, max 6 concurrent
        if (Math.random() < 0.6 && alive.length < 6) {
          alive.push({
            cx: 3 + Math.floor(Math.random() * (w - 6)),
            cy: 1 + Math.floor(Math.random() * (h - 2)),
            age: 0,
            maxAge: 8 + Math.floor(Math.random() * 8), // 8-15 ticks
            hue: Math.random(),
          });
        }

        return alive;
      });
    }, 110);
    return () => clearInterval(id);
  }, []);

  // Build override map from all active bursts
  const overrides = useMemo(() => {
    const map = new Map<number, CellOverride>();
    for (const burst of bursts) {
      const r = 5;
      for (let dy = -r; dy <= r; dy++) {
        for (let dx = -r; dx <= r; dx++) {
          const x = burst.cx + dx;
          const y = burst.cy + dy;
          if (x < 0 || x >= width || y < 0 || y >= height) continue;
          const cell = burstCell(burst, dx, dy);
          if (cell) map.set(y * width + x, cell);
        }
      }
    }
    return map;
  }, [bursts, width, height]);

  const label = "Starting Opal…";
  const boxW = label.length + 6;
  const boxH = 3;
  const boxY = Math.max(0, Math.floor((height - boxH) / 2));
  const boxX = Math.max(0, Math.floor((width - boxW) / 2));

  return (
    <Box flexDirection="column" minWidth={width} minHeight={height}>
      {Array.from({ length: height }, (_, y) => (
        <Text key={y}>
          {Array.from({ length: width }, (_, x) => {
            // Centre box — label or clear space
            if (
              y >= boxY &&
              y < boxY + boxH &&
              x >= boxX &&
              x < boxX + boxW
            ) {
              const isLabelRow = y === boxY + 1;
              const charIdx = x - boxX - 3;

              if (isLabelRow && charIdx >= 0 && charIdx < label.length) {
                const ch = label[charIdx]!;
                if (ch === " ") return <Text key={x}> </Text>;
                return (
                  <Text
                    key={x}
                    bold
                    color={shimmerColor(charIdx, label.length, phase)}
                  >
                    {ch}
                  </Text>
                );
              }
              return <Text key={x}> </Text>;
            }

            const idx = y * width + x;
            const ov = overrides.get(idx);

            if (ov) {
              return (
                <Text key={x} bold={ov.bold} dimColor={ov.dim} color={ov.color}>
                  {ov.char}
                </Text>
              );
            }

            return (
              <Text key={x} color={BG_COLOR}>
                {bgGrid[idx] ?? "."}
              </Text>
            );
          })}
        </Text>
      ))}
    </Box>
  );
};
