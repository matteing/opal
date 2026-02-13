import { existsSync } from "fs";
import { spawn } from "child_process";
import path from "path";

/**
 * Opens the plan.md file in the user's preferred editor.
 * Resolves editor from $VISUAL → $EDITOR → platform default.
 * Spawns detached so the CLI stays responsive.
 */
export function openPlanInEditor(sessionDir: string): void {
  if (!sessionDir) return;

  const planPath = path.join(sessionDir, "plan.md");
  if (!existsSync(planPath)) {
    // Write to stderr so it shows up in logs but doesn't break Ink
    process.stderr.write("No plan.md found yet.\n");
    return;
  }

  const editor =
    process.env.VISUAL ||
    process.env.EDITOR ||
    (process.platform === "win32" ? "notepad" : "code");

  const child = spawn(editor, [planPath], {
    detached: true,
    stdio: "ignore",
    shell: true,
  });
  child.unref();
}
