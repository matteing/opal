import React, { type FC } from "react";
import { Box, Text } from "ink";
import type { Skill, ContextInfo, StatusLevel } from "../state/types.js";
import { colors } from "../lib/palette.js";
import { toRootRelativePath } from "../lib/formatting.js";

// ── Inline status ─────────────────────────────────────────────────

const LEVEL_STYLE: Record<StatusLevel, { icon: string; color: string }> = {
  info: { icon: "◦", color: colors.info },
  success: { icon: "●", color: colors.success },
  error: { icon: "✕", color: colors.error },
};

interface StatusProps {
  text: string;
  level: StatusLevel;
}

/** A system status entry (e.g. compaction started/finished). */
export const TimelineStatusItem: FC<StatusProps> = ({ text, level }) => {
  const { icon, color } = LEVEL_STYLE[level];
  return (
    <Box marginBottom={1}>
      <Text>
        <Text color={color}>{icon}</Text> <Text dimColor>{text}</Text>
      </Text>
    </Box>
  );
};

// ── Skill loaded ─────────────────────────────────────────────────

interface SkillProps {
  skill: Skill;
}

/** A loaded skill indicator. */
export const TimelineSkill: FC<SkillProps> = ({ skill }) => (
  <Box marginBottom={1}>
    <Text>
      <Text color={colors.success}>●</Text>{" "}
      <Text dimColor>Loaded skill: {skill.name}</Text>
    </Text>
  </Box>
);

// ── Context discovered ───────────────────────────────────────────

interface ContextProps {
  context: ContextInfo;
  workingDir: string;
}

/** Discovered context files shown as a bullet list. */
export const TimelineContext: FC<ContextProps> = ({ context, workingDir }) => (
  <Box flexDirection="column" marginBottom={1}>
    {context.files.map((file, i) => (
      <Box key={i}>
        <Text>
          <Text color={colors.success}>●</Text>{" "}
          <Text dimColor>{toRootRelativePath(file, workingDir)}</Text>
        </Text>
      </Box>
    ))}
  </Box>
);
