/**
 * CommandPalette — autocomplete overlay for slash commands.
 *
 * Renders a bordered box above the input bar showing matching commands
 * and keyboard shortcuts. Appears when the user types `/` and filters
 * as they refine (e.g. `/mod` → shows `/model`, `/models`).
 *
 * @module
 */

import React, { useMemo, type FC } from "react";
import { Box, Text } from "ink";
import { colors } from "../lib/palette.js";
import type { CommandInfo } from "../hooks/use-commands.js";
import type { HotkeyInfo } from "../hooks/use-hotkeys.js";

export interface CommandPaletteProps {
  /** Current input value (including the leading `/`). */
  readonly input: string;
  /** All registered slash commands. */
  readonly commands: readonly CommandInfo[];
  /** All registered keyboard shortcuts. */
  readonly hotkeys: readonly HotkeyInfo[];
}

/** Filter commands that match the current partial input. */
function filterCommands(commands: readonly CommandInfo[], query: string): readonly CommandInfo[] {
  // Strip leading `/` and lowercase for matching
  const q = query.slice(1).toLowerCase().trim();
  if (!q) return commands; // Show all when just `/`
  return commands.filter((c) => c.name.startsWith(q));
}

export const CommandPalette: FC<CommandPaletteProps> = ({ input, commands, hotkeys }) => {
  const query = input.trim();

  // Show the palette when input is exactly "/" or "/help" or starts with "/"
  const isSlash = query.startsWith("/");
  const isHelp = query === "/help";
  const showHotkeys = isHelp || query === "/";

  const filtered = useMemo(
    () => (isSlash ? filterCommands(commands, query) : []),
    [commands, query, isSlash],
  );

  if (!isSlash) return null;
  if (filtered.length === 0 && !showHotkeys) return null;

  // Compute column widths for alignment
  const maxUsage = Math.max(...filtered.map((c) => c.usage.length), 0);

  return (
    <Box borderStyle="round" borderColor={colors.accent} flexDirection="column" paddingX={1}>
      {/* Header */}
      <Box>
        <Text bold color={colors.accent}>
          Commands
        </Text>
      </Box>

      {/* Matching slash commands */}
      {filtered.length > 0 && (
        <Box marginTop={0} flexDirection="column">
          {filtered.map((cmd) => (
            <Box key={cmd.name}>
              <Box width={maxUsage + 4}>
                <Text bold color={colors.accent}>
                  {cmd.usage}
                </Text>
              </Box>
              <Text dimColor>{cmd.description}</Text>
            </Box>
          ))}
        </Box>
      )}

      {/* Keyboard shortcuts — shown for `/` and `/help` */}
      {showHotkeys && hotkeys.length > 0 && (
        <Box marginTop={1} flexDirection="column">
          <Text bold dimColor>
            Keyboard Shortcuts
          </Text>
          {hotkeys.map((hk) => (
            <Box key={hk.combo}>
              <Box width={16}>
                <Text bold>{hk.combo}</Text>
              </Box>
              <Text dimColor>{hk.description}</Text>
            </Box>
          ))}
        </Box>
      )}
    </Box>
  );
};
