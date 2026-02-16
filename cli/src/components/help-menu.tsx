import React, { type FC } from "react";
import { Box, Text, useInput } from "ink";
import { colors } from "../lib/palette.js";

export interface HelpMenuProps {
  onDismiss: () => void;
}

function ShortcutRow({ shortcut, desc }: { shortcut: string; desc: string }) {
  return (
    <Box>
      <Box width={14}>
        <Text bold>{shortcut}</Text>
      </Box>
      <Text>{desc}</Text>
    </Box>
  );
}

function CommandRow({ command, desc }: { command: string; desc: string }) {
  return (
    <Box>
      <Box width={24}>
        <Text bold color={colors.accent}>
          {command}
        </Text>
      </Box>
      <Text dimColor>{desc}</Text>
    </Box>
  );
}

export const HelpMenu: FC<HelpMenuProps> = ({ onDismiss }) => {
  useInput((_input, key) => {
    if (key.escape) {
      onDismiss();
    }
  });

  return (
    <Box
      borderStyle="round"
      borderColor={colors.accent}
      flexDirection="column"
      paddingX={2}
      paddingY={1}
    >
      {/* Header */}
      <Box justifyContent="space-between">
        <Text bold color={colors.accent}>
          Help
        </Text>
        <Text dimColor>esc close</Text>
      </Box>

      {/* Keyboard Shortcuts */}
      <Box marginTop={1} flexDirection="column">
        <Text bold dimColor>
          Keyboard Shortcuts
        </Text>
        <ShortcutRow shortcut="ctrl+c" desc="exit (interrupt if running)" />
        <ShortcutRow shortcut="ctrl+o" desc="toggle tool output" />
        <ShortcutRow shortcut="ctrl+y" desc="open plan in editor" />
        <ShortcutRow shortcut="ctrl+j" desc="newline in input" />
      </Box>

      {/* Slash Commands */}
      <Box marginTop={1} flexDirection="column">
        <Text bold dimColor>
          Slash Commands
        </Text>
        <CommandRow command="/help" desc="show this help" />
        <CommandRow command="/model" desc="show current model" />
        <CommandRow command="/model <spec>" desc="switch model (e.g. anthropic:claude-sonnet-4)" />
        <CommandRow command="/models" desc="select model interactively" />
        <CommandRow command="/agents" desc="list active sub-agents" />
        <CommandRow command="/agents <n|main>" desc="switch view to sub-agent or main" />
        <CommandRow command="/compact" desc="compact conversation history" />
        <CommandRow command="/opal" desc="open configuration menu" />
        <CommandRow command="/debug" desc="toggle RPC debug panel" />
      </Box>
    </Box>
  );
};
