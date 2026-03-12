import { useMemo } from "react";
import { marked } from "marked";

/**
 * Streaming-aware markdown renderer.
 *
 * Handles the tricky case of rendering partial markdown while the model is
 * still streaming. The key challenge is unclosed code fences — a single
 * backtick-triple without a closing one causes the rest of the document to
 * render as a code block. We detect this and temporarily close the fence.
 */
export function MarkdownRenderer({
  text,
  isStreaming,
}: {
  text: string;
  isStreaming: boolean;
}) {
  const html = useMemo(() => {
    if (!text) return "";

    let input = text;

    // If streaming, temporarily close any unclosed code fence so the
    // markdown parser doesn't treat the rest of the document as code.
    if (isStreaming) {
      const fenceCount = (input.match(/```/g) || []).length;
      if (fenceCount % 2 !== 0) {
        input += "\n```";
      }
    }

    return marked.parse(input, { async: false, breaks: true }) as string;
  }, [text, isStreaming]);

  if (!text && isStreaming) return null;
  if (!text) return <p data-role="empty-response">(empty response)</p>;

  return (
    <div
      data-role="markdown"
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}
