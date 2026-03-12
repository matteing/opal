import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("opal", {
  // ── Session lifecycle ──────────────────────────────────────
  createSession: (opts: { workingDir?: string }) =>
    ipcRenderer.invoke("opal:sessions:create", opts),

  resumeSession: (id: string, opts?: { workingDir?: string }) =>
    ipcRenderer.invoke("opal:sessions:resume", id, opts ?? {}),

  listSessions: () => ipcRenderer.invoke("opal:sessions:list"),

  deleteSession: (id: string) => ipcRenderer.invoke("opal:sessions:delete", id),

  switchSession: (id: string) => ipcRenderer.invoke("opal:sessions:switch", id),

  getHistory: (id: string) => ipcRenderer.invoke("opal:session:history", id),

  branchSession: (id: string, messageId: string) =>
    ipcRenderer.invoke("opal:session:branch", id, messageId),

  openDirectoryPicker: () => ipcRenderer.invoke("opal:dialog:open-directory"),

  // ── Active session actions ─────────────────────────────────
  prompt: (text: string) => ipcRenderer.invoke("opal:session:prompt", text),

  abort: () => ipcRenderer.invoke("opal:session:abort"),

  steer: (text: string) => ipcRenderer.invoke("opal:session:steer", text),

  // ── Events (main → renderer) ──────────────────────────────
  onEvent: (cb: (event: unknown) => void) => {
    const handler = (_: unknown, event: unknown) => cb(event);
    ipcRenderer.on("opal:agent:event", handler);
    return () => {
      ipcRenderer.removeListener("opal:agent:event", handler);
    };
  },

  onConfirm: (cb: (params: unknown) => void) => {
    const handler = (_: unknown, params: unknown) => cb(params);
    ipcRenderer.on("opal:agent:confirm", handler);
    return () => {
      ipcRenderer.removeListener("opal:agent:confirm", handler);
    };
  },

  resolveConfirm: (requestId: string, action: string) =>
    ipcRenderer.invoke("opal:session:resolve-confirm", requestId, action),

  onAskUser: (cb: (params: unknown) => void) => {
    const handler = (_: unknown, params: unknown) => cb(params);
    ipcRenderer.on("opal:agent:ask-user", handler);
    return () => {
      ipcRenderer.removeListener("opal:agent:ask-user", handler);
    };
  },

  resolveAskUser: (requestId: string, answer: string) =>
    ipcRenderer.invoke("opal:session:resolve-ask-user", requestId, answer),
});
