import React, { type FC } from "react";
import { Box, Text, useStdout } from "ink";

export interface HeaderProps {
  workingDir: string;
  nodeName: string;
}

export const Header: FC<HeaderProps> = ({ workingDir, nodeName }) => {
  const { stdout } = useStdout();
  const width = stdout?.columns ?? 80;
  const shortCwd = workingDir.replace(process.env["HOME"] ?? "", "~");
  const left = "✦ opal";
  const middle = shortCwd;
  const right = nodeName;
  // left + dot separator + middle + dot separator + right
  const contentLen = left.length + 3 + middle.length + 3 + right.length;
  const pad = Math.max(0, width - contentLen);

  return (
    <Box marginBottom={1} paddingX={1}>
      <Text bold color="magenta">
        {left}
      </Text>
      <Text dimColor> · </Text>
      <Text>{middle}</Text>
      <Text>{" ".repeat(pad)}</Text>
      <Text dimColor>{right}</Text>
    </Box>
  );
};
