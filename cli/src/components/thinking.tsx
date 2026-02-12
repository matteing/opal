import React, { useState, useEffect, type FC } from "react";
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
  "(◕‿◕)",
  "(◕ᴗ◕)",
  "(◠‿◠)",
  "(◠ᴗ◠)",
  "(◡‿◡)",
  "(◡ᴗ◡)",
  "(●‿●)",
  "(●ᴗ●)",
];

export interface ThinkingIndicatorProps {
  label?: string;
}

export const ThinkingIndicator: FC<ThinkingIndicatorProps> = ({
  label = "thinking…",
}) => {
  const [frame, setFrame] = useState(0);

  useEffect(() => {
    const timer = setInterval(() => {
      setFrame((f) => (f + 1) % KAOMOJI.length);
    }, 150);
    return () => clearInterval(timer);
  }, []);

  return (
    <Text color="#cc5490">
      {KAOMOJI[frame]} {label}
    </Text>
  );
};
