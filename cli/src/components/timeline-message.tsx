import React, { type FC, useRef, memo } from "react";
import { Box, Text, useStdout } from "ink";
import type { Message } from "../state/types.js";
import {
  renderMarkdown,
  shouldReuseRenderedMarkdown,
  type MarkdownRenderCache,
} from "../lib/markdown.js";
import { colors } from "../lib/palette.js";

interface Props {
  message: Message;
  isStreaming?: boolean;
}

/** A single user or assistant message bubble. */
export const TimelineMessage: FC<Props> = memo(
  ({ message, isStreaming: _isStreaming = false }) => {
    const { stdout } = useStdout();
    const width = stdout?.columns ?? 80;
    const rowWidth = Math.max(20, width - 2);
    const contentWidth = Math.max(16, rowWidth);
    const cacheRef = useRef<MarkdownRenderCache>({ content: "", width: 0, rendered: "" });

    // Skip empty assistant placeholders (before any deltas arrive)
    if (message.role === "assistant" && !message.content) return null;

    const rendered =
      message.role === "user"
        ? message.content
        : (() => {
            const cached = cacheRef.current;
            if (shouldReuseRenderedMarkdown(cached, message.content, contentWidth)) {
              return cached.rendered;
            }
            const md = renderMarkdown(message.content || "", contentWidth);
            cacheRef.current = { content: message.content, width: contentWidth, rendered: md };
            return md;
          })();

    if (message.role === "user") {
      return (
        <Box marginBottom={1}>
          <Text backgroundColor="black" wrap="wrap">
            {"  "}
            {rendered}
          </Text>
        </Box>
      );
    }

    return (
      <Box flexDirection="row" marginBottom={1}>
        <Box marginRight={1}>
          <Text color={colors.thinking}>{"●"}</Text>
        </Box>
        <Box>
          <Text wrap="wrap">{rendered}</Text>
        </Box>
      </Box>
    );
  },
  (prev, next) =>
    prev.message.content === next.message.content &&
    prev.message.role === next.message.role &&
    prev.isStreaming === next.isStreaming,
);
