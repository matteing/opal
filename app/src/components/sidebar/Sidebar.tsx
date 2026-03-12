import { useState } from "react";
import type { SessionListEntry } from "../../state/store.js";
import { SessionList } from "./SessionList.js";

export function Sidebar({
  sessions,
  activeSessionId,
  onCreateSession,
  onResumeSession,
  onSwitchSession,
  onDeleteSession,
}: {
  sessions: SessionListEntry[];
  activeSessionId: string | null;
  onCreateSession: () => void;
  onResumeSession: (id: string) => void;
  onSwitchSession: (id: string) => void;
  onDeleteSession: (id: string) => void;
}) {
  const [search, setSearch] = useState("");
  const [pendingDelete, setPendingDelete] = useState<string | null>(null);

  const filtered = search
    ? sessions.filter(
        (s) =>
          s.title.toLowerCase().includes(search.toLowerCase()) ||
          s.workingDir.toLowerCase().includes(search.toLowerCase()),
      )
    : sessions;

  return (
    <nav aria-label="Sessions">
      <button onClick={onCreateSession}>+ New Session</button>

      <input
        type="search"
        placeholder="Search sessions…"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        aria-label="Search sessions"
      />

      {filtered.length === 0 ? (
        <p data-role="empty">
          {sessions.length === 0
            ? "No sessions yet. Create one to get started."
            : "No matching sessions."}
        </p>
      ) : (
        <SessionList
          sessions={filtered}
          activeSessionId={activeSessionId}
          onSelect={(id, active) => (active ? onSwitchSession(id) : onResumeSession(id))}
          onDelete={(id) => setPendingDelete(id)}
        />
      )}

      {pendingDelete && (
        <dialog open>
          <p>Delete this session?</p>
          <menu>
            <button
              onClick={() => {
                onDeleteSession(pendingDelete);
                setPendingDelete(null);
              }}
            >
              Delete
            </button>
            <button onClick={() => setPendingDelete(null)}>Cancel</button>
          </menu>
        </dialog>
      )}
    </nav>
  );
}
