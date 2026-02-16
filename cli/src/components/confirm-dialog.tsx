import React, { type FC } from "react";
import { Box, Text, useInput } from "ink";
import type { ConfirmRequest } from "../sdk/protocol.js";
import { colors } from "../lib/palette.js";

export interface ConfirmDialogProps {
  request: ConfirmRequest;
  onResolve: (action: string) => void;
}

export const ConfirmDialog: FC<ConfirmDialogProps> = ({ request, onResolve }) => {
  const [selected, setSelected] = React.useState(0);

  useInput((input, key) => {
    if (key.leftArrow || key.upArrow) {
      setSelected((s) => Math.max(0, s - 1));
    } else if (key.rightArrow || key.downArrow) {
      setSelected((s) => Math.min(request.actions.length - 1, s + 1));
    } else if (key.return) {
      onResolve(request.actions[selected]);
    } else if (input === "y") {
      const allow = request.actions.find((a) => a.includes("allow"));
      if (allow) onResolve(allow);
    } else if (input === "n") {
      const deny = request.actions.find((a) => a.includes("deny"));
      if (deny) onResolve(deny);
    }
  });

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor={colors.accent}
      paddingX={2}
      paddingY={1}
    >
      <Text bold color={colors.accent}>
        {request.title}
      </Text>
      <Text>{request.message}</Text>
      <Box marginTop={1} gap={2}>
        {request.actions.map((action, i) => (
          <Text
            key={action}
            bold={i === selected}
            color={i === selected ? colors.accent : undefined}
            inverse={i === selected}
          >
            {" "}
            {action}{" "}
          </Text>
        ))}
      </Box>
      <Text dimColor>↑↓ navigate · enter select · y/n shortcut</Text>
    </Box>
  );
};
