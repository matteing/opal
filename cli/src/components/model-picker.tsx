import React, { useState, type FC } from "react";
import { Box, Text, useInput } from "ink";

export interface ModelPickerProps {
  models: { id: string; name: string }[];
  current: string;
  onSelect: (modelId: string) => void;
  onDismiss: () => void;
}

export const ModelPicker: FC<ModelPickerProps> = ({
  models,
  current,
  onSelect,
  onDismiss,
}) => {
  const currentIdx = models.findIndex((m) => m.id === current);
  const [selected, setSelected] = useState(currentIdx >= 0 ? currentIdx : 0);

  useInput((input, key) => {
    if (key.upArrow) {
      setSelected((s) => Math.max(0, s - 1));
    } else if (key.downArrow) {
      setSelected((s) => Math.min(models.length - 1, s + 1));
    } else if (key.return) {
      onSelect(models[selected]!.id);
    } else if (key.escape || (input === "c" && key.ctrl)) {
      onDismiss();
    }
  });

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor="magenta"
      paddingX={2}
      paddingY={1}
    >
      <Text bold color="magenta">
        Select a model
      </Text>
      <Text dimColor>↑↓ navigate · enter select · esc cancel</Text>
      <Box flexDirection="column" marginTop={1}>
        {models.map((model, i) => {
          const isCurrent = model.id === current;
          const isSelected = i === selected;
          return (
            <Text key={model.id}>
              <Text color={isSelected ? "magenta" : undefined}>
                {isSelected ? "❯" : " "}
              </Text>
              {" "}
              <Text bold={isSelected} color={isSelected ? "magenta" : undefined}>
                {model.id}
              </Text>
              {" "}
              <Text dimColor>{model.name}</Text>
              {isCurrent && <Text color="green"> ●</Text>}
            </Text>
          );
        })}
      </Box>
    </Box>
  );
};
