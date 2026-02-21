/**
 * AgentPicker — menu for navigating between root and sub-agents.
 *
 * ↑↓ to navigate, Enter to select, Esc to dismiss.
 *
 * @module
 */

import React, { useState, type FC } from "react";
import { Box, Text, useInput } from "ink";
import { colors } from "../lib/palette.js";
import { useOpalStore } from "../state/store.js";
import { OverlayPanel, Indicator } from "./overlay-panel.js";

export interface AgentPickerProps {
  onSelect: (id: string) => void;
  onDismiss: () => void;
}

export const AgentPicker: FC<AgentPickerProps> = ({ onSelect, onDismiss }) => {
  const agents = useOpalStore((s) => s.agents);
  const focusedId = useOpalStore((s) => s.focusStack[s.focusStack.length - 1] ?? "root");

  const entries = Object.entries(agents);
  const currentIdx = entries.findIndex(([id]) => id === focusedId);
  const [selected, setSelected] = useState(currentIdx >= 0 ? currentIdx : 0);

  useInput((input, key) => {
    if (key.upArrow) {
      setSelected((s) => Math.max(0, s - 1));
    } else if (key.downArrow) {
      setSelected((s) => Math.min(entries.length - 1, s + 1));
    } else if (key.return) {
      onSelect(entries[selected][0]);
    } else if (key.escape || (input === "c" && key.ctrl)) {
      onDismiss();
    }
  });

  if (entries.length <= 1) {
    return <OverlayPanel title="Agents" hint="No sub-agents running. Press esc to close." />;
  }

  return (
    <OverlayPanel title="Agents" hint="↑↓ navigate · enter select · esc cancel">
      <Box flexDirection="column" marginTop={1}>
        {entries.map(([id, agent], i) => {
          const isFocused = id === focusedId;
          const isSelected = i === selected;
          const label = id === "root" ? "Main agent" : agent.label || id.slice(0, 8);
          return (
            <Text key={id}>
              <Indicator active={isSelected} />{" "}
              <Text bold={isSelected} color={isSelected ? colors.primary : undefined}>
                {label}
              </Text>
              {agent.model && <Text dimColor> {agent.model}</Text>}
              {agent.isRunning && <Text color={colors.warning}> running</Text>}
              {isFocused && <Text color={colors.success}> ●</Text>}
            </Text>
          );
        })}
      </Box>
    </OverlayPanel>
  );
};
