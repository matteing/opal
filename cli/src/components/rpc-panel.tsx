import React, { type FC } from "react";
import { Box, Text } from "ink";
import type { RpcMessageEntry } from "../sdk/client.js";
import { colors } from "../lib/palette.js";

const MAX_VISIBLE = 50;
const MAX_BODY_LEN = 120;

function formatTime(ts: number): string {
  const d = new Date(ts);
  const h = String(d.getHours()).padStart(2, "0");
  const m = String(d.getMinutes()).padStart(2, "0");
  const s = String(d.getSeconds()).padStart(2, "0");
  const ms = String(d.getMilliseconds()).padStart(3, "0");
  return `${h}:${m}:${s}.${ms}`;
}

function kindColor(entry: RpcMessageEntry): string {
  switch (entry.kind) {
    case "request":
      return colors.rpcRequest;
    case "response":
      return colors.rpcResponse;
    case "notification":
      return colors.rpcNotification;
    case "error":
      return colors.rpcError;
  }
}

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) + "…" : s;
}

function summarize(entry: RpcMessageEntry, maxLen: number): string {
  const raw = entry.raw as Record<string, unknown>;
  if (entry.kind === "response" || entry.kind === "error") {
    const payload = raw.error ?? raw.result;
    return truncate(JSON.stringify(payload ?? null), maxLen);
  }
  if (raw.params !== undefined) {
    return truncate(JSON.stringify(raw.params), maxLen);
  }
  return "";
}

export interface RpcPanelProps {
  messages: RpcMessageEntry[];
  height: number;
}

export const RpcPanel: FC<RpcPanelProps> = ({ messages, height }) => {
  const visible = messages.slice(-MAX_VISIBLE);
  // Reserve 2 lines for the header and bottom border
  const bodyHeight = Math.max(1, height - 2);

  return (
    <Box
      flexDirection="column"
      borderStyle="single"
      borderColor={colors.border}
      height={height}
      overflow="hidden"
    >
      <Box paddingX={1}>
        <Text bold color={colors.accent}>
          RPC Messages
        </Text>
        <Text dimColor> ({messages.length})</Text>
      </Box>

      <Box flexDirection="column" height={bodyHeight} overflow="hidden">
        {visible.slice(-bodyHeight).map((entry) => {
          const arrow = entry.direction === "outgoing" ? "→" : "←";
          const arrowColor =
            entry.direction === "outgoing" ? colors.rpcOutgoing : colors.rpcIncoming;
          const method = entry.method ?? `#${(entry.raw as { id?: number }).id ?? "?"}`;
          const body = summarize(entry, MAX_BODY_LEN);

          return (
            <Box key={entry.id} paddingX={1} gap={1}>
              <Text dimColor>{formatTime(entry.timestamp)}</Text>
              <Text color={arrowColor}>{arrow}</Text>
              <Text color={kindColor(entry)} bold>
                {method}
              </Text>
              {body && <Text dimColor>{body}</Text>}
            </Box>
          );
        })}
      </Box>
    </Box>
  );
};
