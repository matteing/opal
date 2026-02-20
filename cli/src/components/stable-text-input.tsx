/**
 * StableTextInput — a drop-in replacement for `ink-text-input` that fixes a
 * critical performance bug.
 *
 * ## Why this exists
 *
 * `ink-text-input@6` passes an **inline arrow function** to Ink's `useInput()`
 * hook. Internally `useInput` uses `useEffect([callback, isActive])`, so the
 * effect tears down and re-subscribes stdin listeners on every re-render. During
 * that brief teardown window keystrokes are silently dropped. In a TUI where
 * the parent re-renders frequently (streaming tokens, animations) this causes
 * severe input lag and missed characters.
 *
 * The fix: store `value`, `onChange`, and `onSubmit` in refs and pass a
 * **stable** (ref-based) callback to `useInput` so the stdin effect only
 * re-runs when `focus` changes.
 */

import React, { useState, useEffect, useRef, useCallback, type FC } from "react";
import { Text, useInput } from "ink";
import chalk from "chalk";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface StableTextInputProps {
  value: string;
  onChange: (value: string) => void;
  onSubmit?: (value: string) => void;
  onUpArrow?: () => void;
  onDownArrow?: () => void;
  focus?: boolean;
  placeholder?: string;
  showCursor?: boolean;
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

export const StableTextInput: FC<StableTextInputProps> = ({
  value: originalValue,
  onChange,
  onSubmit,
  onUpArrow,
  onDownArrow,
  focus = true,
  placeholder = "",
  showCursor = true,
}) => {
  // -- Refs: keep latest props available to the stable input handler ---------
  const valueRef = useRef(originalValue);
  const onChangeRef = useRef(onChange);
  const onSubmitRef = useRef(onSubmit);
  const onUpArrowRef = useRef(onUpArrow);
  const onDownArrowRef = useRef(onDownArrow);
  const showCursorRef = useRef(showCursor);

  valueRef.current = originalValue;
  onChangeRef.current = onChange;
  onSubmitRef.current = onSubmit;
  onUpArrowRef.current = onUpArrow;
  onDownArrowRef.current = onDownArrow;
  showCursorRef.current = showCursor;

  // -- Cursor state ----------------------------------------------------------
  // We use a ref for the authoritative cursor offset so the stable callback
  // can read/write it without depending on React state. A companion state
  // variable triggers re-renders when the cursor moves.
  const cursorOffsetRef = useRef((originalValue ?? "").length);
  const [cursorState, setCursorState] = useState({
    cursorOffset: cursorOffsetRef.current,
    cursorWidth: 0,
  });

  // Clamp cursor when value shrinks (e.g. external clear).
  useEffect(() => {
    const len = (originalValue ?? "").length;
    if (cursorOffsetRef.current > len) {
      cursorOffsetRef.current = len;
      setCursorState({ cursorOffset: len, cursorWidth: 0 });
    }
  }, [originalValue]);

  // -- Stable input handler --------------------------------------------------

  const handleInput = useCallback((input: string, key: import("ink").Key) => {
    if (key.upArrow) {
      onUpArrowRef.current?.();
      return;
    }
    if (key.downArrow) {
      onDownArrowRef.current?.();
      return;
    }
    if ((key.ctrl && input === "c") || key.tab || (key.shift && key.tab)) {
      return;
    }

    const value = valueRef.current ?? "";
    const cursorOffset = cursorOffsetRef.current;

    if (key.return) {
      onSubmitRef.current?.(value);
      return;
    }

    let nextCursorOffset = cursorOffset;
    let nextValue = value;
    let nextCursorWidth = 0;

    if (key.leftArrow) {
      if (showCursorRef.current) {
        nextCursorOffset--;
      }
    } else if (key.rightArrow) {
      if (showCursorRef.current) {
        nextCursorOffset++;
      }
    } else if (key.backspace || key.delete) {
      if (cursorOffset > 0) {
        nextValue = value.slice(0, cursorOffset - 1) + value.slice(cursorOffset);
        nextCursorOffset--;
      }
    } else {
      nextValue = value.slice(0, cursorOffset) + input + value.slice(cursorOffset);
      nextCursorOffset += input.length;
      if (input.length > 1) {
        nextCursorWidth = input.length;
      }
    }

    // Clamp
    if (nextCursorOffset < 0) nextCursorOffset = 0;
    if (nextCursorOffset > nextValue.length) nextCursorOffset = nextValue.length;

    // Commit cursor
    cursorOffsetRef.current = nextCursorOffset;
    setCursorState({ cursorOffset: nextCursorOffset, cursorWidth: nextCursorWidth });

    if (nextValue !== value) {
      onChangeRef.current(nextValue);
    }
  }, []);

  useInput(handleInput, { isActive: focus });

  // -- Render ----------------------------------------------------------------
  const { cursorOffset, cursorWidth } = cursorState;
  const value = originalValue ?? "";
  const hasValue = value.length > 0;

  let renderedValue: string;

  if (hasValue) {
    if (showCursor && focus) {
      renderedValue = "";

      let index = 0;
      for (const char of value) {
        // Highlight the cursor position and any pasted-text range behind it
        if (index >= cursorOffset - cursorWidth && index <= cursorOffset) {
          renderedValue += chalk.inverse(char);
        } else {
          renderedValue += char;
        }
        index++;
      }

      // If cursor is at the end, render an inverse space
      if (cursorOffset === value.length) {
        renderedValue += chalk.inverse(" ");
      }
    } else {
      renderedValue = value;
    }
  } else {
    // No value — show placeholder with cursor
    if (showCursor && focus) {
      renderedValue = chalk.inverse(placeholder.length > 0 ? placeholder[0] : " ");
      if (placeholder.length > 1) {
        renderedValue += chalk.dim(placeholder.slice(1));
      }
    } else {
      renderedValue = chalk.dim(placeholder);
    }
  }

  return <Text>{renderedValue}</Text>;
};
