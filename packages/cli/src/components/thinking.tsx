import React, { useState, useEffect, memo, type FC } from "react";
import { Text } from "ink";

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

export interface ThinkingIndicatorProps {
  label?: string;
}

const ThinkingIndicatorBase: FC<ThinkingIndicatorProps> = ({ label = "thinking…" }) => {
  const [frame, setFrame] = useState(0);

  useEffect(() => {
    const timer = setInterval(() => {
      setFrame((f) => (f + 1) % KAOMOJI.length);
    }, 400);
    return () => clearInterval(timer);
  }, []);

  return (
    <Text color="#cc5490">
      {KAOMOJI[frame]} {label}
    </Text>
  );
};

export const ThinkingIndicator = memo(ThinkingIndicatorBase);
