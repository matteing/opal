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
  compact: () => ipcRenderer.invoke("opal:session:compact"),

  // ── Models ─────────────────────────────────────────────────
  listModels: () => ipcRenderer.invoke("opal:models:list"),
  setModel: (id: string, thinkingLevel?: string) =>
    ipcRenderer.invoke("opal:model:set", id, thinkingLevel),
  setThinking: (level: string) => ipcRenderer.invoke("opal:thinking:set", level),

  // ── Auth ───────────────────────────────────────────────────
  authStatus: () => ipcRenderer.invoke("opal:auth:status"),
  authLogin: () => ipcRenderer.invoke("opal:auth:login"),
  authPoll: (deviceCode: string, interval: number) =>
    ipcRenderer.invoke("opal:auth:poll", deviceCode, interval),

  // ── Settings & Config ──────────────────────────────────────
  getSettings: () => ipcRenderer.invoke("opal:settings:get"),
  saveSettings: (settings: Record<string, unknown>) =>
    ipcRenderer.invoke("opal:settings:save", settings),
  getConfig: () => ipcRenderer.invoke("opal:config:get"),
  setConfig: (config: Record<string, unknown>) =>
    ipcRenderer.invoke("opal:config:set", config),

  // ── Version & Plan ─────────────────────────────────────────
  getVersion: () => ipcRenderer.invoke("opal:version"),
  openPlan: () => ipcRenderer.invoke("opal:plan:open"),

  // ── Schedules ──────────────────────────────────────────────
  listSchedules: () => ipcRenderer.invoke("opal:schedules:list"),
  getSchedule: (id: string) => ipcRenderer.invoke("opal:schedules:get", id),
  saveSchedule: (schedule: unknown) => ipcRenderer.invoke("opal:schedules:save", schedule),
  deleteSchedule: (id: string) => ipcRenderer.invoke("opal:schedules:delete", id),
  toggleSchedule: (id: string, enabled: boolean) =>
    ipcRenderer.invoke("opal:schedules:toggle", id, enabled),
  testSchedule: (id: string) => ipcRenderer.invoke("opal:schedules:test", id),
  onScheduleExecuted: (cb: (data: unknown) => void) => {
    const handler = (_: unknown, data: unknown) => cb(data);
    ipcRenderer.on("opal:schedule:executed", handler);
    return () => { ipcRenderer.removeListener("opal:schedule:executed", handler); };
  },

  // ── Events (main → renderer) ──────────────────────────────
  onEvent: (cb: (event: unknown) => void) => {
    const handler = (_: unknown, event: unknown) => cb(event);
    ipcRenderer.on("opal:agent:event", handler);
    return () => { ipcRenderer.removeListener("opal:agent:event", handler); };
  },
  onConfirm: (cb: (params: unknown) => void) => {
    const handler = (_: unknown, params: unknown) => cb(params);
    ipcRenderer.on("opal:agent:confirm", handler);
    return () => { ipcRenderer.removeListener("opal:agent:confirm", handler); };
  },
  resolveConfirm: (requestId: string, action: string) =>
    ipcRenderer.invoke("opal:session:resolve-confirm", requestId, action),
  onAskUser: (cb: (params: unknown) => void) => {
    const handler = (_: unknown, params: unknown) => cb(params);
    ipcRenderer.on("opal:agent:ask-user", handler);
    return () => { ipcRenderer.removeListener("opal:agent:ask-user", handler); };
  },
  resolveAskUser: (requestId: string, answer: string) =>
    ipcRenderer.invoke("opal:session:resolve-ask-user", requestId, answer),
});
