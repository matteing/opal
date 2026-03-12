import { useState, useCallback, type KeyboardEvent, type FormEvent } from "react";

export function InputArea({
  isRunning,
  onSubmit,
  onSteer,
  onAbort,
  onCommand,
}: {
  isRunning: boolean;
  onSubmit: (text: string) => void;
  onSteer: (text: string) => void;
  onAbort: () => void;
  onCommand: (input: string) => boolean;
}) {
  const [text, setText] = useState("");

  const handleSubmit = useCallback(
    (e: FormEvent) => {
      e.preventDefault();
      const trimmed = text.trim();
      if (!trimmed) return;

      // Try slash commands first
      if (trimmed.startsWith("/") && onCommand(trimmed)) {
        setText("");
        return;
      }

      if (isRunning) {
        onSteer(trimmed);
      } else {
        onSubmit(trimmed);
      }
      setText("");
    },
    [text, isRunning, onSubmit, onSteer, onCommand],
  );

  const handleKeyDown = useCallback(
    (e: KeyboardEvent<HTMLTextAreaElement>) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        handleSubmit(e as unknown as FormEvent);
      }
    },
    [handleSubmit],
  );

  return (
    <footer>
      <form onSubmit={handleSubmit}>
        <textarea
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={isRunning ? "Steer the agent…" : "Ask Opal anything… (/ for commands)"}
          rows={1}
          autoFocus
        />
        {isRunning ? (
          <button type="button" onClick={onAbort}>
            Stop
          </button>
        ) : (
          <button type="submit" disabled={!text.trim()}>
            Send
          </button>
        )}
      </form>
    </footer>
  );
}
