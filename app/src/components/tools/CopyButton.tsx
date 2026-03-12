import { useCallback } from "react";

/** Copy text to clipboard. Shows a brief "Copied!" flash via CSS. */
export function CopyButton({ text }: { text: string }) {
  const handleCopy = useCallback(() => {
    navigator.clipboard.writeText(text).catch(() => {});
  }, [text]);

  return (
    <button onClick={handleCopy} data-role="copy" aria-label="Copy to clipboard">
      Copy
    </button>
  );
}
