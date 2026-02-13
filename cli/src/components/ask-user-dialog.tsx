import React, { useState, type FC } from "react";
import { Box, Text, useInput } from "ink";
import TextInput from "ink-text-input";

export interface AskUserDialogProps {
  question: string;
  choices: string[];
  onResolve: (answer: string) => void;
}

export const AskUserDialog: FC<AskUserDialogProps> = ({
  question,
  choices,
  onResolve,
}) => {
  const [selected, setSelected] = useState(0);
  const [freeform, setFreeform] = useState("");
  const hasChoices = choices.length > 0;

  useInput((input, key) => {
    if (hasChoices) {
      if (key.upArrow) {
        setSelected((s) => Math.max(0, s - 1));
      } else if (key.downArrow) {
        setSelected((s) => Math.min(choices.length - 1, s + 1));
      } else if (key.return && !freeform) {
        onResolve(choices[selected]!);
      }
    }
  });

  const handleFreeformSubmit = (text: string) => {
    if (text.trim()) {
      onResolve(text.trim());
    }
  };

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor="cyan"
      paddingX={2}
      paddingY={1}
    >
      <Text bold color="cyan">
        Agent Question
      </Text>
      <Box marginTop={1}>
        <Text>{question}</Text>
      </Box>

      {hasChoices && (
        <Box flexDirection="column" marginTop={1}>
          {choices.map((choice, i) => (
            <Text
              key={choice}
              bold={i === selected}
              color={i === selected ? "cyan" : undefined}
            >
              {i === selected ? "▸ " : "  "}
              {choice}
            </Text>
          ))}
        </Box>
      )}

      <Box marginTop={1}>
        {hasChoices && <Text dimColor>Or type a custom answer: </Text>}
        <Text color="cyan">❯ </Text>
        <TextInput
          value={freeform}
          onChange={setFreeform}
          onSubmit={handleFreeformSubmit}
          placeholder={hasChoices ? "" : "Type your answer…"}
        />
      </Box>

      <Text dimColor>
        {hasChoices
          ? "↑↓ navigate · enter select · type custom answer"
          : "type answer · enter submit"}
      </Text>
    </Box>
  );
};
