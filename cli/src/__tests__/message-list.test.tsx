import { describe, it, expect } from "vitest";
import React from "react";
import { render } from "ink-testing-library";
import { MessageList } from "../components/message-list.js";
import type { AgentView, TimelineEntry } from "../hooks/use-opal.js";
import { colors } from "../lib/palette.js";

function viewWithTimeline(timeline: TimelineEntry[]): AgentView {
  return {
    timeline,
    thinking: null,
    statusMessage: null,
    isRunning: false,
  };
}

describe("MessageList visuals", () => {
  it("renders user messages without legacy role badges", () => {
    const view = viewWithTimeline([
      { kind: "message", message: { role: "user", content: "My prompt line" } },
    ]);

    const { lastFrame, unmount } = render(
      React.createElement(MessageList, {
        view,
        subAgents: {},
        workingDir: "/tmp",
      }),
    );

    const frame = lastFrame() ?? "";
    expect(frame).toContain("My prompt line");
    expect(frame).not.toContain("❯ You");
    unmount();
  });

  it("renders assistant responses without a dot marker", () => {
    const view = viewWithTimeline([
      { kind: "message", message: { role: "assistant", content: "Agent reply" } },
      {
        kind: "tool",
        task: {
          tool: "shell",
          callId: "c1",
          args: {},
          meta: "Running command",
          status: "done",
          result: { ok: true, output: "ok" },
        },
      },
    ]);

    const { lastFrame, unmount } = render(
      React.createElement(MessageList, {
        view,
        subAgents: {},
        workingDir: "/tmp",
      }),
    );

    const frame = lastFrame() ?? "";
    expect(frame).toContain("Agent reply");
    expect(frame).toContain("shell");
    expect(frame).toContain("●");
    const replyLine = frame.split("\n").find((line) => line.includes("Agent reply")) ?? "";
    expect(replyLine).not.toContain("◉");
    unmount();
  });
});

describe("message theme contrast defaults", () => {
  it("uses a subtle dark user tint with high-contrast text", () => {
    expect(colors.userBg).toBe("#161616");
    expect(colors.userText).toBe("#e0e0e0");
  });
});
