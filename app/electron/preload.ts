import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("opal", {
  startSession: (opts: { workingDir?: string }) =>
    ipcRenderer.invoke("opal:session:start", opts),

  prompt: (text: string) => ipcRenderer.invoke("opal:session:prompt", text),

  abort: () => ipcRenderer.invoke("opal:session:abort"),

  steer: (text: string) => ipcRenderer.invoke("opal:session:steer", text),

  getState: () => ipcRenderer.invoke("opal:session:state"),

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

  resolveConfirm: (id: string, action: string) =>
    ipcRenderer.invoke("opal:session:resolve-confirm", id, action),

  onAskUser: (cb: (params: unknown) => void) => {
    const handler = (_: unknown, params: unknown) => cb(params);
    ipcRenderer.on("opal:agent:ask-user", handler);
    return () => {
      ipcRenderer.removeListener("opal:agent:ask-user", handler);
    };
  },

  resolveAskUser: (id: string, answer: string) =>
    ipcRenderer.invoke("opal:session:resolve-ask-user", id, answer),
});
