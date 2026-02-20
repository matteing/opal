import os from "node:os";
import path from "node:path";
import React, { useState, useEffect, useMemo, useCallback, memo, type FC } from "react";
import { Box, Text, useStdout } from "ink";
import { StableTextInput } from "./stable-text-input.js";
import { colors, PRIMARY_SHADES } from "../lib/palette.js";
import { formatTokens } from "../lib/formatting.js";
import { useOpalStore } from "../state/store.js";
import { selectFocusedAgent } from "../state/selectors.js";
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

const SHIMMER_WIDTH = PRIMARY_SHADES.length;

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
    const shade = dist >= 0 && dist < SHIMMER_WIDTH ? PRIMARY_SHADES[dist] : "#3a3a3a";
    return (
      <Text key={i} color={shade}>
        ─
      </Text>
    );
  });

  return <Text>{chars}</Text>;
};

// ── Isolated prompt input ────────────────────────────────────────
// Memo boundary: ShimmerBorder ticks 25fps and InputBar's status
// section changes during streaming. Neither should force the text
// input to re-render and risk dropping keystrokes.

interface PromptInputProps {
  value: string;
  onChange: (value: string) => void;
  onSubmit: (value: string) => void;
  onUpArrow?: () => void;
  onDownArrow?: () => void;
  focus: boolean;
  placeholder: string;
}

const PromptInput: FC<PromptInputProps> = memo(
  ({ value, onChange, onSubmit, onUpArrow, onDownArrow, focus, placeholder }) => (
    <Box paddingX={1}>
      <Text color={colors.primary}>{"⏣"} </Text>
      <StableTextInput
        value={value}
        onChange={onChange}
        onSubmit={onSubmit}
        onUpArrow={onUpArrow}
        onDownArrow={onDownArrow}
        focus={focus}
        placeholder={placeholder}
        showCursor
      />
    </Box>
  ),
);

// ── Main InputBar ────────────────────────────────────────────────

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
  // Stash the current input when first pressing up, so we can restore it on down.
  const savedInputRef = React.useRef<string | null>(null);
  // Fine-grained selectors: subscribe to primitives, not the whole AgentView.
  // This prevents re-renders when only entries change (every streamed token).
  const isRunning = useOpalStore((s) => selectFocusedAgent(s).isRunning);
  const statusMessage = useOpalStore((s) => selectFocusedAgent(s).statusMessage);
  const currentModel = useOpalStore((s) => s.currentModel);
  const tokenUsage = useOpalStore((s) => s.tokenUsage);
  const workingDir = useOpalStore((s) => s.workingDir);
  const getPreviousCommand = useOpalStore((s) => s.getPreviousCommand);
  const getNextCommand = useOpalStore((s) => s.getNextCommand);
  const resetHistoryNavigation = useOpalStore((s) => s.resetHistoryNavigation);
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

  const handleSubmit = useCallback(
    (text: string) => {
      if (!text.trim()) return;
      savedInputRef.current = null;
      resetHistoryNavigation();
      onSubmit?.(text);
      setValue("");
    },
    [onSubmit, resetHistoryNavigation],
  );

  const handleUpArrow = useCallback(() => {
    // Save current input on first press so we can restore it
    if (savedInputRef.current === null) {
      savedInputRef.current = value;
    }
    const cmd = getPreviousCommand();
    if (cmd !== null) setValue(cmd);
  }, [value, getPreviousCommand]);

  const handleDownArrow = useCallback(() => {
    const cmd = getNextCommand();
    if (cmd !== null) {
      setValue(cmd);
    } else if (savedInputRef.current !== null) {
      // Restore the original input when we go past the end
      setValue(savedInputRef.current);
      savedInputRef.current = null;
    }
  }, [getNextCommand]);

  const showPalette = value.trimStart().startsWith("/") && commands.length > 0;

  return (
    <Box flexDirection="column" marginBottom={1}>
      {showPalette && <CommandPalette input={value} commands={commands} hotkeys={hotkeys} />}
      {isRunning ? (
        <ShimmerBorder width={termWidth} />
      ) : (
        <Text color={colors.border}>{"─".repeat(termWidth)}</Text>
      )}
      <PromptInput
        value={value}
        onChange={setValue}
        onSubmit={handleSubmit}
        onUpArrow={handleUpArrow}
        onDownArrow={handleDownArrow}
        focus={focus}
        placeholder={placeholder}
      />
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
