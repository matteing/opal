import React, { type FC } from "react";
import { Box } from "ink";
import { useOpalStore } from "../state/index.js";
import { selectFocusedAgent } from "../state/selectors.js";
import { TimelineEntry } from "./timeline-entry.js";

/** Renders the full timeline for the currently focused agent. */
const TimelineComponent: FC = () => {
  const entries = useOpalStore((s) => selectFocusedAgent(s).entries);
  const lastIndex = entries.length - 1;

  return (
    <Box flexDirection="column">
      {entries.map((entry, i) => (
        <TimelineEntry key={i} entry={entry} isLast={i === lastIndex} />
      ))}
    </Box>
  );
};

export const Timeline = React.memo(TimelineComponent);
