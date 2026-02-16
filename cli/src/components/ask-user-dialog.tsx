import React, { useState, useCallback, useRef, type FC } from "react";
import { Box, Text, useInput, type Key } from "ink";
import { StableTextInput } from "./stable-text-input.js";
import { colors } from "../lib/palette.js";

export interface AskUserDialogProps {
  question: string;
  choices: string[];
  onResolve: (answer: string) => void;
}

export const AskUserDialog: FC<AskUserDialogProps> = ({ question, choices, onResolve }) => {
  const [selected, setSelected] = useState(0);
  const [freeform, setFreeform] = useState("");
  const hasChoices = choices.length > 0;

  // Refs for stable useInput handler
  const selectedRef = useRef(selected);
  selectedRef.current = selected;
  const freeformRef = useRef(freeform);
  freeformRef.current = freeform;
  const onResolveRef = useRef(onResolve);
  onResolveRef.current = onResolve;
  const choicesRef = useRef(choices);
  choicesRef.current = choices;

  const inputHandler = useCallback(
    (_input: string, key: Key) => {
      if (hasChoices) {
        if (key.upArrow) {
          setSelected((s) => Math.max(0, s - 1));
        } else if (key.downArrow) {
          setSelected((s) => Math.min(choicesRef.current.length - 1, s + 1));
        } else if (key.return && !freeformRef.current) {
          onResolveRef.current(choicesRef.current[selectedRef.current]);
        }
      }
    },
    [hasChoices],
  );

  useInput(inputHandler);

  const handleFreeformSubmit = useCallback((text: string) => {
    if (text.trim()) {
      onResolveRef.current(text.trim());
    }
  }, []);

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor={colors.accentAlt}
      paddingX={2}
      paddingY={1}
    >
      <Text bold color={colors.accentAlt}>
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
              color={i === selected ? colors.accentAlt : undefined}
            >
              {i === selected ? "▸ " : "  "}
              {choice}
            </Text>
          ))}
        </Box>
      )}

      <Box marginTop={1}>
        {hasChoices && <Text dimColor>Or type a custom answer: </Text>}
        <Text color={colors.accentAlt}>❯ </Text>
        <StableTextInput
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
