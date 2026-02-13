import React, { useState, useEffect, type FC } from "react";
import { Text } from "ink";

const PALETTE = [
  "#818cf8",
  "#7678f4",
  "#6b6af0",
  "#6366f1",
  "#5a75f7",
  "#4e8bfd",
  "#38a5f5",
  "#22bde8",
  "#22d3ee",
  "#28dcd8",
  "#2dd4bf",
  "#34d399",
  "#56dc84",
  "#84e365",
  "#a3e635",
  "#c4de22",
  "#e2d31e",
  "#fbbf24",
  "#fba030",
  "#fb923c",
  "#f87c50",
  "#f47272",
  "#f26492",
  "#f472b6",
  "#e46cc8",
  "#d46ede",
  "#c084fc",
  "#ae86fa",
  "#9b89f9",
  "#818cf8",
];

export interface ShimmerTextProps {
  children: string;
}

export const ShimmerText: FC<ShimmerTextProps> = React.memo(({ children }) => {
  const [phase, setPhase] = useState(0);

  useEffect(() => {
    const id = setInterval(() => {
      setPhase((p) => (p + 0.06) % 1);
    }, 150);
    return () => clearInterval(id);
  }, []);

  const chars = [...children];
  const len = chars.length || 1;

  return (
    <Text bold>
      {chars.map((ch, i) => {
        if (ch === " ") return " ";
        const t = ((i / len) * 0.6 + phase + 2) % 1;
        const idx = Math.floor(t * (PALETTE.length - 1));
        const color = PALETTE[Math.min(idx, PALETTE.length - 1)];
        return (
          <Text key={i} color={color}>
            {ch}
          </Text>
        );
      })}
    </Text>
  );
});
