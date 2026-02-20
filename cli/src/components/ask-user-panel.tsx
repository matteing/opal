/**
 * AskUserPanel — overlay for the ask_user tool.
 *
 * Shows the agent's question with optional choices. The user can pick a
 * choice or type a freeform response. The overlay cannot be dismissed
 * without answering — the agent is blocked waiting for a reply.
 *
 * @module
 */

import React, { useState, type FC } from "react";
import { Box, Text, useInput } from "ink";
import { colors } from "../lib/palette.js";
import { OverlayPanel, Indicator } from "./overlay-panel.js";
import { StableTextInput } from "./stable-text-input.js";

export interface AskUserPanelProps {
  question: string;
  choices?: readonly string[];
  onRespond: (answer: string) => void;
}

type Phase = "choices" | "custom";

export const AskUserPanel: FC<AskUserPanelProps> = ({ question, choices, onRespond }) => {
  const hasChoices = choices !== undefined && choices.length > 0;

  // Items = choices + "Custom response..." option
  const items = hasChoices ? [...choices, null] : [];
  const [selected, setSelected] = useState(0);
  const [phase, setPhase] = useState<Phase>(hasChoices ? "choices" : "custom");
  const [customValue, setCustomValue] = useState("");

  useInput(
    (_input, key) => {
      if (phase === "choices") {
        if (key.upArrow) {
          setSelected((s) => Math.max(0, s - 1));
        } else if (key.downArrow) {
          setSelected((s) => Math.min(items.length - 1, s + 1));
        } else if (key.return) {
          const item = items[selected];
          if (item === null) {
            // "Custom response..." selected
            setPhase("custom");
          } else {
            onRespond(item);
          }
        }
      }
    },
    { isActive: phase === "choices" },
  );

  const handleCustomSubmit = (value: string) => {
    if (!value.trim()) return;
    onRespond(value.trim());
  };

  const handleCustomInput = (_input: string, key: import("ink").Key) => {
    if (key.escape && hasChoices) {
      setPhase("choices");
      setCustomValue("");
    }
  };

  // In custom input phase, we need useInput for Esc handling
  useInput(handleCustomInput, { isActive: phase === "custom" && hasChoices });

  const hint =
    phase === "choices"
      ? "↑↓ navigate · enter select"
      : hasChoices
        ? "enter submit · esc back"
        : "enter submit";

  return (
    <OverlayPanel title="Agent is asking" hint={hint}>
      <Box flexDirection="column" marginTop={1}>
        <Text wrap="wrap">{question}</Text>

        {phase === "choices" && (
          <Box flexDirection="column" marginTop={1}>
            {items.map((item, i) => {
              const isSelected = i === selected;
              if (item === null) {
                return (
                  <Text key="__custom__">
                    <Indicator active={isSelected} />{" "}
                    <Text
                      bold={isSelected}
                      color={isSelected ? colors.primary : undefined}
                      dimColor={!isSelected}
                      italic
                    >
                      Custom response…
                    </Text>
                  </Text>
                );
              }
              return (
                <Text key={`choice:${i}:${item}`}>
                  <Indicator active={isSelected} />{" "}
                  <Text bold={isSelected} color={isSelected ? colors.primary : undefined}>
                    {item}
                  </Text>
                </Text>
              );
            })}
          </Box>
        )}

        {phase === "custom" && (
          <Box marginTop={1}>
            <Text color={colors.primary}>{"❯"} </Text>
            <StableTextInput
              value={customValue}
              onChange={setCustomValue}
              onSubmit={handleCustomSubmit}
              focus
              placeholder="Type your response..."
              showCursor
            />
          </Box>
        )}
      </Box>
    </OverlayPanel>
  );
};
