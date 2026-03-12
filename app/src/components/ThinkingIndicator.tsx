export function ThinkingIndicator({
  text,
  statusMessage,
}: {
  text: string;
  statusMessage: string;
}) {
  if (!text && !statusMessage) return null;

  return (
    <output data-role="thinking">
      {statusMessage && <p><strong>{statusMessage}</strong></p>}
      {text && <pre>{text}</pre>}
    </output>
  );
}
