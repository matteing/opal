import React, { useState, type FC } from "react";
import { Box, Text, useInput } from "ink";
import { colors } from "../lib/palette.js";

export interface ModelPickerProps {
  models: {
    id: string;
    name: string;
    provider?: string;
    supportsThinking?: boolean;
    thinkingLevels?: string[];
  }[];
  current: string;
  currentThinkingLevel?: string;
  onSelect: (modelId: string, thinkingLevel?: string) => void;
  onDismiss: () => void;
}

type PickerPhase = "model" | "thinking";

function capitalize(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

export const ModelPicker: FC<ModelPickerProps> = ({
  models,
  current,
  currentThinkingLevel,
  onSelect,
  onDismiss,
}) => {
  const currentIdx = models.findIndex((m) => m.id === current);
  const [selected, setSelected] = useState(currentIdx >= 0 ? currentIdx : 0);
  const [phase, setPhase] = useState<PickerPhase>("model");
  const [pendingModel, setPendingModel] = useState<string | null>(null);
  const [thinkingLevels, setThinkingLevels] = useState<string[]>([]);
  const [thinkingSelected, setThinkingSelected] = useState(0);

  useInput((input, key) => {
    if (phase === "model") {
      if (key.upArrow) {
        setSelected((s) => Math.max(0, s - 1));
      } else if (key.downArrow) {
        setSelected((s) => Math.min(models.length - 1, s + 1));
      } else if (key.return) {
        const m = models[selected];
        const spec = m.provider && m.provider !== "copilot" ? `${m.provider}:${m.id}` : m.id;
        const levels = m.thinkingLevels ?? [];
        if (m.supportsThinking && levels.length > 0) {
          const allLevels = ["off", ...levels];
          setPendingModel(spec);
          setThinkingLevels(allLevels);
          const curIdx = allLevels.indexOf(currentThinkingLevel || "off");
          setThinkingSelected(curIdx >= 0 ? curIdx : 0);
          setPhase("thinking");
        } else {
          onSelect(spec, "off");
        }
      } else if (key.escape || (input === "c" && key.ctrl)) {
        onDismiss();
      }
    } else {
      if (key.upArrow) {
        setThinkingSelected((s) => Math.max(0, s - 1));
      } else if (key.downArrow) {
        setThinkingSelected((s) => Math.min(thinkingLevels.length - 1, s + 1));
      } else if (key.return) {
        onSelect(pendingModel!, thinkingLevels[thinkingSelected]);
      } else if (key.escape || (input === "c" && key.ctrl)) {
        setPhase("model");
        setPendingModel(null);
      }
    }
  });

  if (phase === "thinking") {
    return (
      <Box
        flexDirection="column"
        borderStyle="round"
        borderColor={colors.accentAlt}
        paddingX={2}
        paddingY={1}
      >
        <Text bold color={colors.accentAlt}>
          Thinking level
        </Text>
        <Text dimColor>↑↓ navigate · enter select · esc back</Text>
        <Box flexDirection="column" marginTop={1}>
          {thinkingLevels.map((level, i) => {
            const isCurrent = level === (currentThinkingLevel || "off");
            const isSelected = i === thinkingSelected;
            return (
              <Text key={level}>
                <Text color={isSelected ? colors.accentAlt : undefined}>
                  {isSelected ? "❯" : " "}
                </Text>{" "}
                <Text bold={isSelected} color={isSelected ? colors.accentAlt : undefined}>
                  {capitalize(level)}
                </Text>
                {isCurrent && <Text color={colors.success}> ●</Text>}
              </Text>
            );
          })}
        </Box>
      </Box>
    );
  }

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor={colors.accent}
      paddingX={2}
      paddingY={1}
    >
      <Text bold color={colors.accent}>
        Select a model
      </Text>
      <Text dimColor>↑↓ navigate · enter select · esc cancel</Text>
      <Box flexDirection="column" marginTop={1}>
        {models.map((model, i) => {
          const isCurrent = model.id === current;
          const isSelected = i === selected;
          const providerLabel =
            model.provider && model.provider !== "copilot" ? `${model.provider}/` : "";
          return (
            <Text key={`${model.provider ?? ""}:${model.id}`}>
              <Text color={isSelected ? colors.accent : undefined}>{isSelected ? "❯" : " "}</Text>{" "}
              {providerLabel && <Text dimColor>{providerLabel}</Text>}
              <Text bold={isSelected} color={isSelected ? colors.accent : undefined}>
                {model.id}
              </Text>{" "}
              <Text dimColor>{model.name}</Text>
              {isCurrent && <Text color={colors.success}> ●</Text>}
            </Text>
          );
        })}
      </Box>
    </Box>
  );
};
