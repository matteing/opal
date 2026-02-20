import React, { type FC } from "react";
import { Box, Text } from "ink";

// ── Types ────────────────────────────────────────────────────────

interface DiffLine {
  readonly op: "eq" | "del" | "ins";
  readonly text: string;
  readonly old_no?: number;
  readonly new_no?: number;
}

interface DiffHunk {
  readonly old_start: number;
  readonly new_start: number;
  readonly lines: readonly DiffLine[];
}

export interface DiffPayload {
  readonly path: string;
  readonly lines_removed: number;
  readonly lines_added: number;
  readonly hunks: readonly DiffHunk[];
}

// ── Helpers ──────────────────────────────────────────────────────

/** Format a line number to a fixed-width gutter. */
function gutter(num: number | undefined, width: number): string {
  if (num == null) return " ".repeat(width);
  return String(num).padStart(width, " ");
}

/** Compute the gutter width from a hunk's line numbers. */
function gutterWidth(hunks: readonly DiffHunk[]): number {
  let max = 0;
  for (const hunk of hunks) {
    for (const line of hunk.lines) {
      if (line.old_no != null && line.old_no > max) max = line.old_no;
      if (line.new_no != null && line.new_no > max) max = line.new_no;
    }
  }
  return Math.max(String(max).length, 1);
}

// ── Component ────────────────────────────────────────────────────

interface Props {
  diff: DiffPayload;
  maxWidth: number;
}

/** Renders a structured diff as a colored, terminal-friendly block. */
export const DiffBlock: FC<Props> = ({ diff, maxWidth }) => {
  if (diff.hunks.length === 0) {
    return (
      <Box marginLeft={2}>
        <Text dimColor>No changes.</Text>
      </Box>
    );
  }

  const gw = gutterWidth(diff.hunks);
  // Gutter takes: old_gutter + "│" + new_gutter + " " + prefix + " " = gw*2 + 4
  const gutterTotal = gw * 2 + 4;
  const textWidth = Math.max(maxWidth - gutterTotal - 4, 20); // 4 for marginLeft+padding

  return (
    <Box flexDirection="column" marginLeft={1}>
      {/* Header */}
      <Text>
        <Text dimColor>{"─── "}</Text>
        <Text bold>{diff.path}</Text>
        <Text dimColor>{" ─── "}</Text>
        {diff.lines_removed > 0 && <Text color="red">−{diff.lines_removed}</Text>}
        {diff.lines_removed > 0 && diff.lines_added > 0 && <Text dimColor> / </Text>}
        {diff.lines_added > 0 && <Text color="green">+{diff.lines_added}</Text>}
      </Text>

      {/* Hunks */}
      {diff.hunks.map((hunk, i) => (
        <Box key={i} flexDirection="column">
          {i > 0 && <Text dimColor>{"  ···"}</Text>}
          {hunk.lines.map((line, j) => (
            <DiffLine key={j} line={line} gutterWidth={gw} textWidth={textWidth} />
          ))}
        </Box>
      ))}
    </Box>
  );
};

// ── Line component ───────────────────────────────────────────────

interface DiffLineProps {
  line: DiffLine;
  gutterWidth: number;
  textWidth: number;
}

const OP_STYLE = {
  eq: { prefix: " ", color: undefined, dimColor: true },
  del: { prefix: "-", color: "red" as const, dimColor: false },
  ins: { prefix: "+", color: "green" as const, dimColor: false },
} as const;

const DiffLine: FC<DiffLineProps> = ({ line, gutterWidth: gw, textWidth }) => {
  const style = OP_STYLE[line.op];
  const oldG = gutter(line.old_no, gw);
  const newG = gutter(line.new_no, gw);
  const text = line.text.slice(0, textWidth);

  return (
    <Text color={style.color} dimColor={style.dimColor} wrap="truncate-end">
      <Text dimColor>
        {oldG}│{newG}
      </Text>{" "}
      {style.prefix} {text}
    </Text>
  );
};
