import React, { useState, useRef, useMemo, type FC } from "react";
import { Box, Text } from "ink";
import { PALETTE } from "../lib/palette.js";
import { useViewport } from "../hooks/use-viewport.js";
import { useOpalStore } from "../state/store.js";

// ── Colour helpers ───────────────────────────────────────────────

function shimmerColor(i: number, len: number, phase: number): string {
  const t = ((i / Math.max(len, 1)) * 0.6 + phase + 2) % 1;
  const idx = Math.floor(t * (PALETTE.length - 1));
  return PALETTE[Math.min(idx, PALETTE.length - 1)];
}

// ── StartingView ─────────────────────────────────────────────────

export const StartingView: FC = () => {
  const { width, height } = useViewport();
  const [phase, setPhase] = useState(0);
  const [elapsed, setElapsed] = useState(0);
  const startTime = useRef(Date.now());
  const sessionError = useOpalStore((s) => s.sessionError);

  React.useEffect(() => {
    const id = setInterval(() => {
      setPhase((p) => (p + 0.05) % 1);
      setElapsed(Math.floor((Date.now() - startTime.current) / 1000));
    }, 110);
    return () => clearInterval(id);
  }, []);

  const label = "Starting Opal…";

  const chars = useMemo(
    () =>
      label.split("").map((ch, i) => ({
        ch,
        color: shimmerColor(i, label.length, phase),
      })),
    [phase],
  );

  return (
    <Box
      flexDirection="column"
      alignItems="center"
      justifyContent="center"
      minWidth={width}
      minHeight={height}
    >
      <Text bold>
        {chars.map(({ ch, color }, i) =>
          ch === " " ? (
            <Text key={i}> </Text>
          ) : (
            <Text key={i} color={color}>
              {ch}
            </Text>
          ),
        )}
      </Text>
      {elapsed >= 5 && !sessionError && (
        <Box marginTop={1}>
          <Text dimColor>{elapsed}s — waiting for server…</Text>
        </Box>
      )}
      {sessionError && (
        <Box marginTop={1}>
          <Text color="red">✖ {sessionError}</Text>
        </Box>
      )}
    </Box>
  );
};
