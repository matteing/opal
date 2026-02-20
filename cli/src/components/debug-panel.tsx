/**
 * Debug panel — interleaved RPC log and server stderr.
 *
 * Shows a chronological view of all JSON-RPC traffic and
 * server stderr output. Auto-scrolls to the latest entries.
 *
 * @module
 */

import React, { useMemo, type FC } from "react";
import { Box, Text, useStdout } from "ink";
import type { RpcLogEntry, StderrEntry } from "../state/types.js";
import { colors } from "../lib/palette.js";
import { truncate } from "../lib/formatting.js";

// ── Layout constants ─────────────────────────────────────────

const MIN_HEIGHT = 8;
const MAX_HEIGHT = 20;
const PANEL_RATIO = 0.3;

// ── Formatting helpers ───────────────────────────────────────

function formatTime(ts: number): string {
  const d = new Date(ts);
  const h = String(d.getHours()).padStart(2, "0");
  const m = String(d.getMinutes()).padStart(2, "0");
  const s = String(d.getSeconds()).padStart(2, "0");
  const ms = String(d.getMilliseconds()).padStart(3, "0");
  return `${h}:${m}:${s}.${ms}`;
}

function kindStyle(kind: string): { badge: string; color: string } {
  switch (kind) {
    case "request":
      return { badge: "REQ", color: colors.rpcRequest };
    case "response":
      return { badge: "RES", color: colors.rpcResponse };
    case "notification":
      return { badge: "EVT", color: colors.rpcNotification };
    case "error":
      return { badge: "ERR", color: colors.rpcError };
    default:
      return { badge: kind.slice(0, 3).toUpperCase(), color: colors.muted };
  }
}

/** Extract a compact summary from an RPC entry's payload. */
function summarizeRpc(entry: RpcLogEntry, maxLen: number): string {
  const raw = entry.raw as Record<string, unknown>;

  // For notifications, try to show the event type
  if (entry.kind === "notification") {
    const params = raw.params as Record<string, unknown> | undefined;
    if (params?.type) {
      const rest = { ...params };
      delete rest.type;
      delete rest.session_id;
      const extra = Object.keys(rest).length > 0 ? ` ${JSON.stringify(rest)}` : "";
      return truncate(`${String(params.type as string)}${extra}`, maxLen);
    }
  }

  if (entry.kind === "response" || entry.kind === "error") {
    const payload = raw.error ?? raw.result;
    return truncate(JSON.stringify(payload ?? null), maxLen);
  }

  if (raw.params !== undefined) {
    return truncate(JSON.stringify(raw.params), maxLen);
  }

  return "";
}

// ── Unified entry type ───────────────────────────────────────

type UnifiedEntry =
  | { type: "rpc"; ts: number; entry: RpcLogEntry }
  | { type: "stderr"; ts: number; entry: StderrEntry };

// ── Row components ───────────────────────────────────────────

const RpcRow: FC<{ entry: RpcLogEntry; bodyWidth: number }> = ({ entry, bodyWidth }) => {
  const arrow = entry.direction === "outgoing" ? "→" : "←";
  const arrowColor = entry.direction === "outgoing" ? colors.rpcOutgoing : colors.rpcIncoming;
  const { badge, color } = kindStyle(entry.kind);
  const method = entry.method ?? "";

  // Reserve space: time(12) + space + arrow(1) + space + badge(3) + space + method(~20) + space
  const fixedWidth = 12 + 1 + 1 + 1 + 3 + 1 + 22 + 1;
  const payloadWidth = Math.max(10, bodyWidth - fixedWidth);
  const body = summarizeRpc(entry, payloadWidth);

  return (
    <Box>
      <Text dimColor>{formatTime(entry.timestamp)}</Text>
      <Text> </Text>
      <Text color={arrowColor}>{arrow}</Text>
      <Text> </Text>
      <Text color={color} bold>
        {badge}
      </Text>
      <Text> </Text>
      <Text color={color}>{method ? method.padEnd(20) : "".padEnd(20)}</Text>
      <Text> </Text>
      <Text dimColor>{body}</Text>
    </Box>
  );
};

const StderrRow: FC<{ entry: StderrEntry }> = ({ entry }) => (
  <Box>
    <Text dimColor>{formatTime(entry.timestamp)}</Text>
    <Text> </Text>
    <Text color={colors.warning}>{"⚠"}</Text>
    <Text> </Text>
    <Text color={colors.warning}>{entry.text}</Text>
  </Box>
);

// ── Main component ───────────────────────────────────────────

export interface DebugPanelProps {
  rpcEntries: readonly RpcLogEntry[];
  stderrLines: readonly StderrEntry[];
  onClear?: () => void;
}

export const DebugPanel: FC<DebugPanelProps> = ({ rpcEntries, stderrLines }) => {
  const { stdout } = useStdout();
  const termHeight = stdout?.rows ?? 24;
  const termWidth = stdout?.columns ?? 80;

  const panelHeight = Math.min(
    MAX_HEIGHT,
    Math.max(MIN_HEIGHT, Math.round(termHeight * PANEL_RATIO)),
  );
  // Reserve 2 lines for header + footer
  const bodyHeight = panelHeight - 2;

  const unified = useMemo<UnifiedEntry[]>(() => {
    const all: UnifiedEntry[] = [
      ...rpcEntries.map((e) => ({ type: "rpc" as const, ts: e.timestamp, entry: e })),
      ...stderrLines.map((e) => ({ type: "stderr" as const, ts: e.timestamp, entry: e })),
    ];
    all.sort((a, b) => a.ts - b.ts);
    return all;
  }, [rpcEntries, stderrLines]);

  const visible = unified.slice(-bodyHeight);
  const bodyWidth = termWidth - 4; // account for border + padding

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor={colors.muted}
      height={panelHeight}
      overflow="hidden"
      marginX={1}
    >
      {/* Header */}
      <Box paddingX={1} justifyContent="space-between">
        <Box gap={1}>
          <Text bold color={colors.primary}>
            ◇ Debug
          </Text>
        </Box>
        <Box gap={2}>
          <Text dimColor>
            <Text color={colors.rpcRequest}>{rpcEntries.length}</Text> rpc
          </Text>
          {stderrLines.length > 0 && (
            <Text dimColor>
              <Text color={colors.warning}>{stderrLines.length}</Text> stderr
            </Text>
          )}
          <Text dimColor>Ctrl+D copy</Text>
        </Box>
      </Box>

      {/* Body */}
      <Box flexDirection="column" height={bodyHeight} overflow="hidden" paddingX={1}>
        {visible.length === 0 ? (
          <Box justifyContent="center">
            <Text dimColor italic>
              No messages yet
            </Text>
          </Box>
        ) : (
          visible.map((item, i) =>
            item.type === "rpc" ? (
              <RpcRow key={`r-${item.entry.id}`} entry={item.entry} bodyWidth={bodyWidth} />
            ) : (
              <StderrRow key={`s-${i}`} entry={item.entry} />
            ),
          )
        )}
      </Box>
    </Box>
  );
};
