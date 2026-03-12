import type { SessionListEntry } from "../../state/store.js";

export function SessionList({
  sessions,
  activeSessionId,
  onSelect,
  onDelete,
}: {
  sessions: SessionListEntry[];
  activeSessionId: string | null;
  onSelect: (id: string, active: boolean) => void;
  onDelete: (id: string) => void;
}) {
  return (
    <ul>
      {sessions.map((session) => (
        <SessionItem
          key={session.id}
          session={session}
          isActive={session.id === activeSessionId}
          onSelect={() => onSelect(session.id, session.active)}
          onDelete={() => onDelete(session.id)}
        />
      ))}
    </ul>
  );
}

function SessionItem({
  session,
  isActive,
  onSelect,
  onDelete,
}: {
  session: SessionListEntry;
  isActive: boolean;
  onSelect: () => void;
  onDelete: () => void;
}) {
  const icon = session.active ? (isActive ? "●" : "○") : "◇";

  // Shorten workingDir for display
  const dir = session.workingDir.replace(/^\/Users\/[^/]+/, "~");

  return (
    <li
      data-active={isActive || undefined}
      data-loaded={session.active || undefined}
    >
      <button onClick={onSelect} aria-current={isActive ? "true" : undefined}>
        <span data-role="icon">{icon}</span>
        <span data-role="title">{session.title}</span>
        <span data-role="dir">{dir}</span>
      </button>
      <button
        onClick={(e) => {
          e.stopPropagation();
          onDelete();
        }}
        aria-label={`Delete ${session.title}`}
        data-role="delete"
      >
        ✕
      </button>
    </li>
  );
}
