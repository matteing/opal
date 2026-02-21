import React, { type FC } from "react";
import type { TimelineEntry as TimelineEntryType, ToolCall } from "../state/types.js";
import { useOpalStore } from "../state/index.js";
import { TimelineMessage } from "./timeline-message.js";
import { TimelineTool } from "./timeline-tool.js";
import { TimelineThinking } from "./timeline-thinking.js";
import { TimelineSkill, TimelineContext, TimelineStatusItem } from "./timeline-status.js";

interface Props {
  entry: TimelineEntryType;
  isLast?: boolean;
}

/**
 * Subscribes to agents ONLY for sub_agent tool entries. Uses primitive
 * selectors (string/number) so Zustand's default Object.is comparison
 * prevents re-renders when values haven't actually changed.
 */
const SubAgentToolEntry: FC<{ tool: ToolCall; showOutput: boolean }> = ({ tool, showOutput }) => {
  const model = useOpalStore(
    (s) => Object.values(s.agents).find((a) => a.parentCallId === tool.callId)?.model ?? null,
  );
  const toolCount = useOpalStore(
    (s) => Object.values(s.agents).find((a) => a.parentCallId === tool.callId)?.toolCount ?? null,
  );
  const subAgent = model !== null && toolCount !== null ? { model, toolCount } : undefined;
  return <TimelineTool tool={tool} showOutput={showOutput} subAgent={subAgent} />;
};

/** Renders a single timeline entry by dispatching on `kind`. */
const TimelineEntryComponent: FC<Props> = ({ entry, isLast = false }) => {
  const workingDir = useOpalStore((s) => s.workingDir);
  const showToolOutput = useOpalStore((s) => s.showToolOutput);

  switch (entry.kind) {
    case "message":
      return <TimelineMessage message={entry.message} isStreaming={isLast} />;
    case "tool":
      return entry.tool.tool === "sub_agent" ? (
        <SubAgentToolEntry tool={entry.tool} showOutput={showToolOutput} />
      ) : (
        <TimelineTool tool={entry.tool} showOutput={showToolOutput} />
      );
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

export const TimelineEntry = React.memo(TimelineEntryComponent, (prev, next) => {
  // Compare entry by reference — timeline slice creates new objects only when changed
  // Compare isLast by value
  return prev.entry === next.entry && prev.isLast === next.isLast;
});
