import React, { useState, useEffect, type FC } from "react";
import { Text } from "ink";
import { PALETTE } from "../lib/palette.js";

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
