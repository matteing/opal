import React, { useState, useEffect, useRef, memo, type FC } from "react";
import { Text } from "ink";
import { colors } from "../lib/palette.js";

const KAOMOJI = [
  "(◕‿◕)",
  "(◕ᴗ◕)",
  "(◠‿◠)",
  "(◠ᴗ◠)",
  "(◡‿◡)",
  "(◡ᴗ◡)",
  "(●‿●)",
  "(●ᴗ●)",
  "(◕‿◕✿)",
  "(✿◕‿◕)",
  "(◕◡◕)",
  "(◠◡◠)",
];

/** Labels shown when no status message is provided.
 *  Strings are singles; arrays are sequences played in order. */
const IDLE_POOL: ReadonlyArray<string | readonly string[]> = [
  "On it...",
  "Hold on...",
  "You got this!",
  "I got this!",
  "Hmm...",
  "Let me think...",
  "Working on it...",
  "Almost there...",
  "Bear with me...",
  ["Idaho!", "You da ho!", "We da ho!"],
  "Sippin' tea...",
  "I'm on the case!",
  "Thinking about the beach...",
];

/** Pick a random entry from the pool, excluding sequential groups. */
function pickRandom(pool: ReadonlyArray<string | readonly string[]>): string | readonly string[] {
  return pool[Math.floor(Math.random() * pool.length)];
}

const LABEL_INTERVAL = 3000;

export interface ThinkingIndicatorProps {
  label?: string;
}

const ThinkingIndicatorBase: FC<ThinkingIndicatorProps> = ({ label }) => {
  const [frame, setFrame] = useState(0);
  const [displayLabel, setDisplayLabel] = useState(() => {
    const first = pickRandom(IDLE_POOL);
    return typeof first === "string" ? first : first[0];
  });
  const seqRef = useRef<{ items: readonly string[]; index: number } | null>(null);

  useEffect(() => {
    const timer = setInterval(() => {
      setFrame((f) => (f + 1) % KAOMOJI.length);
    }, 400);
    return () => clearInterval(timer);
  }, []);

  useEffect(() => {
    if (label) return; // external label provided, skip cycling

    const timer = setInterval(() => {
      const seq = seqRef.current;
      if (seq && seq.index < seq.items.length - 1) {
        // Continue playing a sequential group
        seq.index++;
        setDisplayLabel(seq.items[seq.index]);
      } else {
        // Pick a new entry
        seqRef.current = null;
        const pick = pickRandom(IDLE_POOL);
        if (typeof pick === "string") {
          setDisplayLabel(pick);
        } else {
          seqRef.current = { items: pick, index: 0 };
          setDisplayLabel(pick[0]);
        }
      }
    }, LABEL_INTERVAL);
    return () => clearInterval(timer);
  }, [label]);

  return (
    <Text color={colors.thinking}>
      {KAOMOJI[frame]} {label ?? displayLabel}
    </Text>
  );
};

export const ThinkingIndicator = memo(ThinkingIndicatorBase);
