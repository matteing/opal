import { app, BrowserWindow, ipcMain, dialog } from "electron";
import path from "node:path";
import { SessionManager } from "./session-manager.js";

let mainWindow: BrowserWindow | null = null;
let manager: SessionManager | null = null;

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1100,
    height: 720,
    minWidth: 600,
    minHeight: 400,
    title: "Opal Desktop",
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      preload: path.join(__dirname, "../preload/preload.mjs"),
    },
  });

  if (process.env.ELECTRON_RENDERER_URL) {
    mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL);
  } else {
    mainWindow.loadFile(path.join(__dirname, "../renderer/index.html"));
  }

  mainWindow.on("closed", () => {
    mainWindow = null;
  });

  manager = new SessionManager((channel, ...args) => {
    mainWindow?.webContents.send(channel, ...args);
  });
}

// ── Session lifecycle IPC ────────────────────────────────────

ipcMain.handle("opal:sessions:create", async (_, opts: { workingDir?: string }) => {
  if (!manager) throw new Error("app not ready");
  const workingDir =
    typeof opts?.workingDir === "string" ? opts.workingDir : process.cwd();
  return manager.create({ workingDir });
});

ipcMain.handle("opal:sessions:resume", async (_, id: string, opts: { workingDir?: string }) => {
  if (!manager) throw new Error("app not ready");
  if (typeof id !== "string") throw new Error("session id must be a string");
  return manager.resume(id, opts ?? {});
});

ipcMain.handle("opal:sessions:list", async () => {
  if (!manager) throw new Error("app not ready");
  return manager.list();
});

ipcMain.handle("opal:sessions:delete", async (_, id: string) => {
  if (!manager) throw new Error("app not ready");
  if (typeof id !== "string") throw new Error("session id must be a string");
  return manager.delete(id);
});

ipcMain.handle("opal:sessions:switch", async (_, id: string) => {
  if (!manager) throw new Error("app not ready");
  if (typeof id !== "string") throw new Error("session id must be a string");
  return manager.switchTo(id);
});

ipcMain.handle("opal:session:history", async (_, id: string) => {
  if (!manager) throw new Error("app not ready");
  if (typeof id !== "string") throw new Error("session id must be a string");
  return manager.getHistory(id);
});

ipcMain.handle("opal:session:branch", async (_, id: string, messageId: string) => {
  if (!manager) throw new Error("app not ready");
  if (typeof id !== "string" || typeof messageId !== "string") {
    throw new Error("session id and message id must be strings");
  }
  return manager.branch(id, messageId);
});

ipcMain.handle("opal:dialog:open-directory", async () => {
  if (!mainWindow) return null;
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ["openDirectory"],
  });
  return result.canceled ? null : result.filePaths[0] ?? null;
});

// ── Active session IPC (prompt / steer / abort) ──────────────

ipcMain.handle("opal:session:prompt", async (_, text: unknown) => {
  if (typeof text !== "string" || text.length === 0) {
    throw new Error("prompt text must be a non-empty string");
  }
  if (!manager) throw new Error("app not ready");
  await manager.prompt(text);
});

ipcMain.handle("opal:session:steer", async (_, text: unknown) => {
  if (typeof text !== "string") throw new Error("steer text must be a string");
  if (!manager) throw new Error("app not ready");
  return manager.steer(text);
});

ipcMain.handle("opal:session:abort", async () => {
  if (!manager) return;
  await manager.abort();
});

// ── Confirm / AskUser resolution ─────────────────────────────

ipcMain.handle(
  "opal:session:resolve-confirm",
  async (_, requestId: string, action: string) => {
    manager?.resolveConfirm(requestId, action);
  },
);

ipcMain.handle(
  "opal:session:resolve-ask-user",
  async (_, requestId: string, answer: string) => {
    manager?.resolveAskUser(requestId, answer);
  },
);

// ── Lifecycle ────────────────────────────────────────────────

app.whenReady().then(createWindow);

app.on("window-all-closed", () => {
  manager?.closeAll();
  if (process.platform !== "darwin") app.quit();
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});
