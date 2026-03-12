import { useState, useCallback, useEffect, useRef } from "react";
import type { ConfirmRequest, AskUserRequest } from "../state/types.js";

export function ConfirmDialog({
  request,
  onResolve,
}: {
  request: ConfirmRequest;
  onResolve: (action: string) => void;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    dialogRef.current?.showModal();
  }, []);

  let argsSummary: string;
  try {
    argsSummary = JSON.stringify(request.args, null, 2);
  } catch {
    argsSummary = String(request.args);
  }

  return (
    <dialog ref={dialogRef}>
      <h3>Tool Approval: {request.tool}</h3>
      {request.message && <p>{request.message}</p>}
      <pre>{argsSummary}</pre>
      <menu>
        <button onClick={() => onResolve("allow")}>Allow</button>
        <button onClick={() => onResolve("always_allow")}>Always Allow</button>
        <button onClick={() => onResolve("deny")}>Deny</button>
      </menu>
    </dialog>
  );
}

export function AskUserDialog({
  request,
  onResolve,
}: {
  request: AskUserRequest;
  onResolve: (answer: string) => void;
}) {
  const [answer, setAnswer] = useState("");
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    dialogRef.current?.showModal();
  }, []);

  const handleSubmit = useCallback(() => {
    const value = answer.trim();
    if (value) onResolve(value);
  }, [answer, onResolve]);

  return (
    <dialog ref={dialogRef}>
      <h3>Opal is asking:</h3>
      <p>{request.question}</p>
      {request.choices && request.choices.length > 0 ? (
        <menu>
          {request.choices.map((choice) => (
            <button key={choice} onClick={() => onResolve(choice)}>
              {choice}
            </button>
          ))}
        </menu>
      ) : (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            handleSubmit();
          }}
        >
          <textarea
            value={answer}
            onChange={(e) => setAnswer(e.target.value)}
            placeholder="Type your answer…"
            rows={2}
            autoFocus
          />
          <button type="submit" disabled={!answer.trim()}>
            Submit
          </button>
        </form>
      )}
    </dialog>
  );
}
