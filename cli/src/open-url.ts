import { spawn, execSync } from "node:child_process";

/**
 * Opens a URL in the user's default browser.
 * Cross-platform: macOS (open), Linux (xdg-open), Windows (start).
 */
export function openUrl(url: string): void {
  const cmd =
    process.platform === "darwin"
      ? "open"
      : process.platform === "win32"
        ? "start"
        : "xdg-open";

  const child = spawn(cmd, [url], {
    detached: true,
    stdio: "ignore",
    shell: process.platform === "win32",
  });
  child.unref();
}

/**
 * Copies text to the system clipboard.
 * Cross-platform: macOS (pbcopy), Linux (xclip/xsel), Windows (clip).
 * Returns true on success, false if no clipboard tool is available.
 */
export function copyToClipboard(text: string): boolean {
  try {
    if (process.platform === "darwin") {
      execSync("pbcopy", { input: text, stdio: ["pipe", "ignore", "ignore"] });
    } else if (process.platform === "win32") {
      execSync("clip", { input: text, stdio: ["pipe", "ignore", "ignore"] });
    } else {
      // Try xclip first, fall back to xsel
      try {
        execSync("xclip -selection clipboard", {
          input: text,
          stdio: ["pipe", "ignore", "ignore"],
        });
      } catch {
        execSync("xsel --clipboard --input", {
          input: text,
          stdio: ["pipe", "ignore", "ignore"],
        });
      }
    }
    return true;
  } catch {
    return false;
  }
}
