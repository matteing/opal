import { app, BrowserWindow, ipcMain, dialog } from "electron";
import path from "node:path";
import { SessionManager } from "./session-manager.js";
import { Scheduler } from "./scheduler.js";
import type { Schedule } from "./schedule-types.js";

let mainWindow: BrowserWindow | null = null;
let manager: SessionManager | null = null;
let scheduler: Scheduler | null = null;

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
      preload: path.join(__dirname, "../preload/preload.js"),
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

  scheduler = new Scheduler((schedule, execution) => {
    mainWindow?.webContents.send("opal:schedule:executed", { schedule, execution });
  });
  scheduler.start();
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

// ── Models ───────────────────────────────────────────────────

ipcMain.handle("opal:models:list", async () => {
  const session = manager?.active;
  if (!session) throw new Error("no active session");
  return session.models();
});

ipcMain.handle("opal:model:set", async (_, model: string, thinkingLevel?: string) => {
  const session = manager?.active;
  if (!session) throw new Error("no active session");
  const spec = thinkingLevel ? { id: model, thinkingLevel } : model;
  return session.setModel(spec);
});

ipcMain.handle("opal:thinking:set", async (_, level: string) => {
  const session = manager?.active;
  if (!session) throw new Error("no active session");
  return session.setThinking(level);
});

// ── Auth ─────────────────────────────────────────────────────

ipcMain.handle("opal:auth:status", async () => {
  const session = manager?.active;
  if (!session) throw new Error("no active session");
  return session.auth_.status();
});

ipcMain.handle("opal:auth:login", async () => {
  const session = manager?.active;
  if (!session) throw new Error("no active session");
  return session.auth_.login();
});

ipcMain.handle("opal:auth:poll", async (_, deviceCode: string, interval: number) => {
  const session = manager?.active;
  if (!session) throw new Error("no active session");
  return session.auth_.poll(deviceCode, interval);
});

// ── Settings & Config ────────────────────────────────────────

ipcMain.handle("opal:settings:get", async () => {
  const session = manager?.active;
  if (!session) throw new Error("no active session");
  return session.config.getSettings();
});

ipcMain.handle("opal:settings:save", async (_, settings: Record<string, unknown>) => {
  const session = manager?.active;
  if (!session) throw new Error("no active session");
  return session.config.saveSettings(settings);
});

ipcMain.handle("opal:config:get", async () => {
  const session = manager?.active;
  if (!session) throw new Error("no active session");
  return session.config.getRuntime();
});

ipcMain.handle("opal:config:set", async (_, config: Record<string, unknown>) => {
  const session = manager?.active;
  if (!session) throw new Error("no active session");
  return session.config.setRuntime(config);
});

// ── Compact & Version ────────────────────────────────────────

ipcMain.handle("opal:session:compact", async () => {
  const session = manager?.active;
  if (!session) throw new Error("no active session");
  return session.compact();
});

ipcMain.handle("opal:version", async () => {
  const session = manager?.active;
  if (!session) throw new Error("no active session");
  return session.version();
});

// ── Plan (open in external editor) ───────────────────────────

ipcMain.handle("opal:plan:open", async () => {
  const session = manager?.active;
  if (!session) return { opened: false, reason: "no session" };

  const planPath = path.join(session.dir, "plan.md");
  try {
    await import("node:fs/promises").then((fs) => fs.access(planPath));
  } catch {
    return { opened: false, reason: "no plan" };
  }

  const { shell } = await import("electron");
  shell.openPath(planPath);
  return { opened: true };
});

// ── Schedules ────────────────────────────────────────────────

ipcMain.handle("opal:schedules:list", () => {
  return scheduler?.list() ?? [];
});

ipcMain.handle("opal:schedules:get", (_, id: string) => {
  return scheduler?.get(id) ?? null;
});

ipcMain.handle("opal:schedules:save", (_, schedule: Schedule) => {
  if (!scheduler) throw new Error("app not ready");
  if (!schedule.id) {
    schedule.id = `sched_${Date.now().toString(36)}`;
    schedule.createdAt = new Date().toISOString();
    schedule.executionHistory = [];
  }
  scheduler.save(schedule);
  return schedule;
});

ipcMain.handle("opal:schedules:delete", (_, id: string) => {
  scheduler?.delete(id);
});

ipcMain.handle("opal:schedules:toggle", (_, id: string, enabled: boolean) => {
  scheduler?.toggle(id, enabled);
});

ipcMain.handle("opal:schedules:test", async (_, id: string) => {
  if (!scheduler) throw new Error("app not ready");
  await scheduler.testNow(id);
});

// ── Lifecycle ────────────────────────────────────────────────

app.whenReady().then(createWindow);

app.on("window-all-closed", () => {
  scheduler?.stop();
  manager?.closeAll();
  if (process.platform !== "darwin") app.quit();
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});
