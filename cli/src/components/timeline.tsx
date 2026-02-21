import React, { type FC } from "react";
import { Box, Static } from "ink";
import { useOpalStore } from "../state/index.js";
import { selectFocusedAgent } from "../state/selectors.js";
import { TimelineEntry } from "./timeline-entry.js";

/**
 * Number of entries kept in the "live" (yoga-managed) portion of the tree.
 * Everything older is rendered once via `<Static>` and then removed from the
 * yoga layout tree so it no longer costs anything on subsequent renders.
 */
const LIVE_TAIL = 5;

/**
 * Renders the timeline for the currently focused agent.
 *
 * Ink recomputes yoga layout for the **entire** component tree on every
 * render — even when only the input field changed. With hundreds of
 * timeline entries this causes per-keystroke lag.
 *
 * The fix: finalized entries are emitted through `<Static>`, which
 * renders them once into the terminal scrollback and then removes them
 * from the yoga tree. Only the last few "live" entries stay in the
 * layout, keeping the tree small and renders fast.
 */
const TimelineComponent: FC = () => {
  const focusedId = useOpalStore(
    (s) => s.focusStack[s.focusStack.length - 1] ?? "root",
  );
  const entries = useOpalStore((s) => selectFocusedAgent(s).entries);
  const lastIndex = entries.length - 1;

  const staticCount = Math.max(0, entries.length - LIVE_TAIL);
  const staticEntries = entries.slice(0, staticCount);
  const liveEntries = entries.slice(staticCount);

  return (
    // Key resets <Static> when the focused agent changes so stale
    // entries from a different agent aren't stuck in the scrollback.
    <React.Fragment key={focusedId}>
      <Static items={staticEntries}>
        {(entry, i) => (
          <TimelineEntry key={i} entry={entry} isLast={false} />
        )}
      </Static>
      <Box flexDirection="column">
        {liveEntries.map((entry, j) => {
          const globalIdx = staticCount + j;
          return (
            <TimelineEntry
              key={globalIdx}
              entry={entry}
              isLast={globalIdx === lastIndex}
            />
          );
        })}
      </Box>
    </React.Fragment>
  );
};

export const Timeline = React.memo(TimelineComponent);
