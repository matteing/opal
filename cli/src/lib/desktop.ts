import open from "open";
import clipboard from "clipboardy";

/**
 * Opens a URL in the user's default browser.
 * Cross-platform via the `open` package.
 */
export function openUrl(url: string): void {
  void open(url);
}

/**
 * Opens a local file path in the user's default app/editor.
 * Cross-platform via the `open` package.
 */
export async function openPath(targetPath: string): Promise<boolean> {
  try {
    await open(targetPath);
    return true;
  } catch {
    return false;
  }
}

/**
 * Copies text to the system clipboard.
 * Cross-platform via the `clipboardy` package.
 * Returns true on success, false if clipboard access fails.
 */
export function copyToClipboard(text: string): boolean {
  try {
    clipboard.writeSync(text);
    return true;
  } catch {
    return false;
  }
}
