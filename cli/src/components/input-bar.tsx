import os from "node:os";
import path from "node:path";
import React, { useState, useEffect, useMemo, type FC } from "react";
import { Box, Text, useStdout } from "ink";
import TextInput from "ink-text-input";
import { colors } from "../lib/palette.js";
import { formatTokens } from "../lib/formatting.js";
import { useOpalStore } from "../state/store.js";
import { useActiveAgent } from "../state/selectors.js";
import { ThinkingIndicator } from "./thinking.js";
import { CommandPalette } from "./command-palette.js";
import type { CommandInfo } from "../hooks/use-commands.js";
import type { HotkeyInfo } from "../hooks/use-hotkeys.js";

/** Pick a color based on how close to the context window limit. */
function contextColor(pct: number): string {
  if (pct >= 80) return colors.error;
  if (pct >= 60) return colors.warning;
  return "gray";
}

/** Shorten a path for display: ~/foo or just the basename. */
function shortenPath(dir: string): string {
  const home = os.homedir();
  if (dir === home) return "~";
  if (dir.startsWith(home + path.sep)) {
    return "~" + path.sep + path.relative(home, dir);
  }
  return dir;
}

// Thinking color shades — from dim gray through to full #cc5490
const THINKING_SHADES = [
  "#3a3a3a",
  "#3c3039",
  "#3f2d38",
  "#422b39",
  "#452a3a",
  "#492a3c",
  "#4d2a3d",
  "#512b3e",
  "#562c40",
  "#5a2d42",
  "#5f2e45",
  "#632f48",
  "#6b3050",
  "#713254",
  "#773458",
  "#7e365c",
  "#8a3860",
  "#923a64",
  "#9a3c68",
  "#a13e6c",
  "#a84070",
  "#b04478",
  "#b84880",
  "#c24e88",
  "#cc5490",
  "#c24e88",
  "#b84880",
  "#b04478",
  "#a84070",
  "#a13e6c",
  "#9a3c68",
  "#923a64",
  "#8a3860",
  "#7e365c",
  "#773458",
  "#713254",
  "#6b3050",
  "#632f48",
  "#5f2e45",
  "#5a2d42",
  "#562c40",
  "#512b3e",
  "#4d2a3d",
  "#492a3c",
  "#452a3a",
  "#422b39",
  "#3f2d38",
  "#3c3039",
  "#3a3a3a",
];
const SHIMMER_WIDTH = THINKING_SHADES.length;

/** A horizontal line with a sweeping shimmer ray in the thinking color. */
const ShimmerBorder: FC<{ width: number }> = ({ width }) => {
  const [offset, setOffset] = useState(0);

  useEffect(() => {
    const timer = setInterval(() => {
      setOffset((o) => (o + 1) % (width + SHIMMER_WIDTH));
    }, 40);
    return () => clearInterval(timer);
  }, [width]);

  const chars = Array.from({ length: width }, (_, i) => {
    const dist = i - offset + SHIMMER_WIDTH;
    const shade = dist >= 0 && dist < SHIMMER_WIDTH ? THINKING_SHADES[dist] : "#3a3a3a";
    return (
      <Text key={i} color={shade}>
        ─
      </Text>
    );
  });

  return <Text>{chars}</Text>;
};

interface Props {
  onSubmit?: (value: string) => void;
  focus?: boolean;
  placeholder?: string;
  toast?: string | null;
  /** Slash commands for autocomplete palette. */
  commands?: readonly CommandInfo[];
  /** Keyboard shortcuts for autocomplete palette. */
  hotkeys?: readonly HotkeyInfo[];
}

/** Input bar with a prompt indicator and text input. */
export const InputBar: FC<Props> = ({
  onSubmit,
  focus = true,
  placeholder = "Ask anything...",
  toast,
  commands = [],
  hotkeys = [],
}) => {
  const [value, setValue] = useState("");
  const { isRunning, statusMessage } = useActiveAgent();
  const currentModel = useOpalStore((s) => s.currentModel);
  const tokenUsage = useOpalStore((s) => s.tokenUsage);
  const workingDir = useOpalStore((s) => s.workingDir);
  const shortDir = useMemo(() => (workingDir ? shortenPath(workingDir) : null), [workingDir]);

  const tokenDisplay =
    tokenUsage && tokenUsage.contextWindow > 0
      ? {
          used: formatTokens(tokenUsage.currentContextTokens),
          max: formatTokens(tokenUsage.contextWindow),
          pct: Math.min(
            100,
            Math.round((tokenUsage.currentContextTokens / tokenUsage.contextWindow) * 100),
          ),
        }
      : null;

  const { stdout } = useStdout();
  const termWidth = stdout?.columns ?? 80;

  const handleSubmit = (text: string) => {
    if (!text.trim()) return;
    onSubmit?.(text);
    setValue("");
  };

  const showPalette = value.trimStart().startsWith("/") && commands.length > 0;

  return (
    <Box flexDirection="column" marginBottom={1}>
      {showPalette && <CommandPalette input={value} commands={commands} hotkeys={hotkeys} />}
      {isRunning ? (
        <ShimmerBorder width={termWidth} />
      ) : (
        <Text color={colors.border}>{"─".repeat(termWidth)}</Text>
      )}
      <Box paddingX={1}>
        <Text color={colors.accent}>{"⏣"} </Text>
        <TextInput
          value={value}
          onChange={setValue}
          onSubmit={handleSubmit}
          focus={focus}
          placeholder={placeholder}
          showCursor
        />
      </Box>
      {isRunning ? (
        <ShimmerBorder width={termWidth} />
      ) : (
        <Text color={colors.border}>{"─".repeat(termWidth)}</Text>
      )}
      <Box marginX={2} justifyContent="space-between">
        <Box>
          {toast ? (
            <Text dimColor italic>
              {toast}
            </Text>
          ) : isRunning ? (
            <ThinkingIndicator label={statusMessage ?? undefined} />
          ) : (
            <Text color={colors.muted}>(◡‿◡)✧</Text>
          )}
        </Box>
        <Box gap={2}>
          {shortDir && (
            <Text color="gray">
              {"⌂"} {shortDir}
            </Text>
          )}
          <Text color={tokenDisplay ? contextColor(tokenDisplay.pct) : "gray"}>
            {"≋"}{" "}
            {tokenDisplay
              ? `${tokenDisplay.used}/${tokenDisplay.max}`
              : `0/${tokenUsage ? formatTokens(tokenUsage.contextWindow) : "0"}`}
          </Text>
          {currentModel && (
            <Text color="gray">
              {"⬢"} {currentModel.displayName}
            </Text>
          )}
        </Box>
      </Box>
    </Box>
  );
};
