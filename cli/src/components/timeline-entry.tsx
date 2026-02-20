import React, { type FC } from "react";
import type { TimelineEntry as TimelineEntryType } from "../state/types.js";
import { useOpalStore } from "../state/index.js";
import { TimelineMessage } from "./timeline-message.js";
import { TimelineTool } from "./timeline-tool.js";
import { TimelineThinking } from "./timeline-thinking.js";
import { TimelineSkill, TimelineContext, TimelineStatusItem } from "./timeline-status.js";

interface Props {
  entry: TimelineEntryType;
  isLast?: boolean;
}

/** Renders a single timeline entry by dispatching on `kind`. */
export const TimelineEntry: FC<Props> = ({ entry, isLast = false }) => {
  const workingDir = useOpalStore((s) => s.workingDir);
  const showToolOutput = useOpalStore((s) => s.showToolOutput);
  const agents = useOpalStore((s) => s.agents);

  switch (entry.kind) {
    case "message":
      return <TimelineMessage message={entry.message} isStreaming={isLast} />;
    case "tool": {
      // Find sub-agent metadata for sub_agent tool calls
      const subAgent =
        entry.tool.tool === "sub_agent"
          ? Object.values(agents).find((a) => a.parentCallId === entry.tool.callId)
          : undefined;
      return (
        <TimelineTool
          tool={entry.tool}
          showOutput={showToolOutput}
          subAgent={subAgent ? { model: subAgent.model, toolCount: subAgent.toolCount } : undefined}
        />
      );
    }
    case "thinking":
      return <TimelineThinking text={entry.text} />;
    case "skill":
      return <TimelineSkill skill={entry.skill} />;
    case "context":
      return <TimelineContext context={entry.context} workingDir={workingDir} />;
    case "status":
      return <TimelineStatusItem text={entry.text} level={entry.level} />;
  }
};
