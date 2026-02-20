import React, { type FC } from "react";
import { Box } from "ink";
import { useActiveAgent } from "../state/selectors.js";
import { TimelineEntry } from "./timeline-entry.js";

/** Renders the full timeline for the currently focused agent. */
export const Timeline: FC = () => {
  const { entries } = useActiveAgent();
  const lastIndex = entries.length - 1;

  return (
    <Box flexDirection="column">
      {entries.map((entry, i) => (
        <TimelineEntry key={i} entry={entry} isLast={i === lastIndex} />
      ))}
    </Box>
  );
};
