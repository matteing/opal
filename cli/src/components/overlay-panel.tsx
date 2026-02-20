/**
 * Shared overlay primitives used across picker and panel components.
 *
 * @module
 */

import React, { type FC, type ReactNode } from "react";
import { Box, Text } from "ink";
import { colors } from "../lib/palette.js";

// ── OverlayPanel ─────────────────────────────────────────────────

export interface OverlayPanelProps {
  title?: string;
  hint?: string;
  borderColor?: string;
  children?: ReactNode;
}

/** Bordered overlay panel with optional title and hint line. */
export const OverlayPanel: FC<OverlayPanelProps> = ({
  title,
  hint,
  borderColor = colors.primary,
  children,
}) => (
  <Box
    flexDirection="column"
    borderStyle="round"
    borderColor={borderColor}
    paddingX={2}
    paddingY={1}
  >
    {title && (
      <Text bold color={borderColor}>
        {title}
      </Text>
    )}
    {hint && <Text dimColor>{hint}</Text>}
    {children}
  </Box>
);

// ── Indicator ────────────────────────────────────────────────────

/** Selection indicator (❯ / space) used in picker lists. */
export const Indicator: FC<{ active: boolean }> = ({ active }) => (
  <Text color={active ? colors.primary : undefined}>{active ? "❯" : " "}</Text>
);
