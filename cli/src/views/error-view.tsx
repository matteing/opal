import React, { type FC, useMemo } from "react";
import { Text, Box } from "ink";
import type { RpcLogEntry } from "../state/types.js";
import { useOpalStore } from "../state/store.js";

const RpcErrorEntry: FC<{ entry: RpcLogEntry }> = ({ entry }) => (
  <Box flexDirection="column">
    <Box>
      <Text color="red">
        {entry.direction === "incoming" ? "←" : "→"} {entry.method}
      </Text>
    </Box>
    {entry.raw !== undefined && (
      <Box marginLeft={2}>
        <Text color="red" dimColor>
          {JSON.stringify(entry.raw)}
        </Text>
      </Box>
    )}
  </Box>
);

export const ErrorView: FC = () => {
  const error = useOpalStore((s) => s.sessionError);
  const rpcEntries = useOpalStore((s) => s.rpcEntries);
  const stderrLines = useOpalStore((s) => s.stderrLines);

  const errors = useMemo(
    () => rpcEntries.filter((e) => e.kind === "error"),
    [rpcEntries],
  );

  return (
    <Box flexDirection="column" padding={1}>
      <Text bold color="red">
        ✖ {error ?? "Connection failed"}
      </Text>

      {errors.length > 0 && (
        <Box flexDirection="column" marginTop={1}>
          <Text bold dimColor>RPC Errors:</Text>
          {errors.map((entry) => (
            <RpcErrorEntry key={entry.id} entry={entry} />
          ))}
        </Box>
      )}

      {stderrLines.length > 0 && (
        <Box flexDirection="column" marginTop={1}>
          <Text bold dimColor>Server Log:</Text>
          {stderrLines.map((line, i) => (
            <Text key={i} color="red" dimColor>
              {line.text}
            </Text>
          ))}
        </Box>
      )}
    </Box>
  );
};
