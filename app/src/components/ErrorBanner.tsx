export function ErrorBanner({
  message,
  onDismiss,
}: {
  message: string;
  onDismiss: () => void;
}) {
  return (
    <aside role="alert">
      <span>⚠ {message}</span>
      <button onClick={onDismiss} aria-label="Dismiss">
        ✕
      </button>
    </aside>
  );
}
