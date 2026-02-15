/**
 * A drop-in replacement for ink-text-input that keeps the `useInput` callback
 * reference-stable across re-renders.
 *
 * The upstream `ink-text-input` v6 passes an **inline** arrow function to
 * Ink's `useInput`.  Ink's `useInput` puts `inputHandler` in its `useEffect`
 * dependency array, so every time TextInput re-renders the effect tears down
 * the old `stdin` listener and adds a new one — any keystroke that arrives in
 * that gap is lost.  During streaming (30 renders/sec) this causes constant
 * dropped / duplicated characters.
 *
 * This version stores `value`, `onChange`, `onSubmit`, `cursorOffset`, and
 * `showCursor` in refs, then passes a single **stable** function to
 * `useInput`.  The effect never re-runs, so the listener is never torn down
 * mid-session.
 */
import React, { useState, useEffect, useCallback, useRef, type FC } from "react";
import { Text, useInput, type Key } from "ink";
import chalk from "chalk";

export interface StableTextInputProps {
  value: string;
  onChange: (value: string) => void;
  onSubmit?: (value: string) => void;
  placeholder?: string;
  focus?: boolean;
  showCursor?: boolean;
  mask?: string;
}

export const StableTextInput: FC<StableTextInputProps> = ({
  value: originalValue,
  onChange,
  onSubmit,
  placeholder = "",
  focus = true,
  showCursor = true,
  mask,
}) => {
  const [cursorOffset, setCursorOffset] = useState(originalValue.length);

  // Keep latest values in refs so the stable useInput handler always sees them
  const valueRef = useRef(originalValue);
  const onChangeRef = useRef(onChange);
  const onSubmitRef = useRef(onSubmit);
  const cursorRef = useRef(cursorOffset);
  const showCursorRef = useRef(showCursor);

  valueRef.current = originalValue;
  onChangeRef.current = onChange;
  onSubmitRef.current = onSubmit;
  cursorRef.current = cursorOffset;
  showCursorRef.current = showCursor;

  // Sync cursor when value changes externally (e.g. cleared on submit)
  useEffect(() => {
    setCursorOffset((prev) => {
      if (!focus || !showCursor) return prev;
      const len = originalValue.length;
      return prev > len ? len : prev;
    });
  }, [originalValue, focus, showCursor]);

  // Stable handler — never changes identity, reads everything from refs
  const handler = useCallback((input: string, key: Key) => {
    if (
      key.upArrow ||
      key.downArrow ||
      (key.ctrl && input === "c") ||
      key.tab ||
      (key.shift && key.tab)
    ) {
      return;
    }

    const value = valueRef.current;
    const cursor = cursorRef.current;

    if (key.return) {
      onSubmitRef.current?.(value);
      return;
    }

    let nextCursor = cursor;
    let nextValue = value;

    if (key.leftArrow) {
      if (showCursorRef.current) nextCursor--;
    } else if (key.rightArrow) {
      if (showCursorRef.current) nextCursor++;
    } else if (key.backspace || key.delete) {
      if (cursor > 0) {
        nextValue = value.slice(0, cursor - 1) + value.slice(cursor);
        nextCursor--;
      }
    } else {
      nextValue = value.slice(0, cursor) + input + value.slice(cursor);
      nextCursor += input.length;
    }

    // Clamp
    if (nextCursor < 0) nextCursor = 0;
    if (nextCursor > nextValue.length) nextCursor = nextValue.length;

    setCursorOffset(nextCursor);
    cursorRef.current = nextCursor;

    if (nextValue !== value) {
      onChangeRef.current(nextValue);
    }
  }, []);

  useInput(handler, { isActive: focus });

  // --- Render ---
  const displayValue = mask ? mask.repeat(originalValue.length) : originalValue;
  let rendered: string;
  const renderedPlaceholder =
    placeholder.length > 0
      ? chalk.inverse(placeholder[0]) + chalk.grey(placeholder.slice(1))
      : chalk.inverse(" ");

  if (showCursor && focus) {
    if (displayValue.length === 0) {
      rendered = placeholder ? renderedPlaceholder : chalk.inverse(" ");
    } else {
      rendered = "";
      let i = 0;
      for (const char of displayValue) {
        rendered += i === cursorOffset ? chalk.inverse(char) : char;
        i++;
      }
      if (cursorOffset === displayValue.length) {
        rendered += chalk.inverse(" ");
      }
    }
  } else {
    rendered = displayValue.length > 0 ? displayValue : placeholder ? chalk.grey(placeholder) : "";
  }

  return <Text>{rendered}</Text>;
};
