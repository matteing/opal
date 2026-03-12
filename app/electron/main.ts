import { app, BrowserWindow, ipcMain } from "electron";
import path from "node:path";
import { createSession, type Session, type AgentEvent } from "@unfinite/opal-sdk";

let mainWindow: BrowserWindow | null = null;
let session: Session | null = null;

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 960,
    height: 720,
    minWidth: 480,
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
}

// ── IPC handlers ─────────────────────────────────────────────

function send(channel: string, ...args: unknown[]): void {
  mainWindow?.webContents.send(channel, ...args);
}

ipcMain.handle("opal:session:start", async (_, opts: { workingDir?: string }) => {
  const workingDir =
    typeof opts?.workingDir === "string" ? opts.workingDir : process.cwd();

  session = await createSession({
    workingDir,
    callbacks: {
      onConfirm: async (params) => {
        send("opal:agent:confirm", params);
        return new Promise((resolve) => {
          ipcMain.handleOnce("opal:session:resolve-confirm", (_, _id, action) => {
            resolve({ action });
          });
        });
      },
      onAskUser: async (params) => {
        send("opal:agent:ask-user", params);
        return new Promise((resolve) => {
          ipcMain.handleOnce("opal:session:resolve-ask-user", (_, _id, answer) => {
            resolve(answer);
          });
        });
      },
    },
  });

  session.onEvent((event: AgentEvent) => {
    send("opal:agent:event", event);
  });

  return { sessionId: session.id, workingDir };
});

ipcMain.handle("opal:session:prompt", async (_, text: unknown) => {
  if (typeof text !== "string" || text.length === 0) {
    throw new Error("prompt text must be a non-empty string");
  }
  if (!session) throw new Error("no active session");

  for await (const _event of session.prompt(text)) {
    // events forwarded by onEvent handler above
  }
});

ipcMain.handle("opal:session:steer", async (_, text: unknown) => {
  if (typeof text !== "string") throw new Error("steer text must be a string");
  if (!session) throw new Error("no active session");
  return session.steer(text);
});

ipcMain.handle("opal:session:abort", async () => {
  if (!session) return;
  await session.abort();
});

ipcMain.handle("opal:session:state", async () => {
  if (!session) return null;
  return session.state();
});

// ── Lifecycle ────────────────────────────────────────────────

app.whenReady().then(createWindow);

app.on("window-all-closed", () => {
  session?.close();
  if (process.platform !== "darwin") app.quit();
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});
