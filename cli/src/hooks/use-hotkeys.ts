/**
 * useHotkeys — declarative global hotkey manager.
 *
 * Register hotkeys as data. The hook wires a single `useInput` listener
 * that matches incoming keystrokes against the registry and dispatches
 * the bound handler. Handlers are captured by ref so they always close
 * over current state without causing re-renders.
 *
 * @example
 * ```tsx
 * useHotkeys({
 *   "ctrl+d": {
 *     description: "Copy RPC log",
 *     handler: () => copyToClipboard(json),
 *   },
 *   "ctrl+l": {
 *     description: "Clear debug log",
 *     handler: () => clearDebug(),
 *   },
 * });
 * ```
 *
 * @module
 */

import { useRef, useMemo } from "react";
import { useInput, type Key } from "ink";

// ── Types ────────────────────────────────────────────────────────

/** A single hotkey binding. */
export interface HotkeyDef {
  /** Human-readable description (for help display). */
  readonly description: string;
  /** Handler invoked when the hotkey fires. */
  readonly handler: () => void;
}

/** Map of key combos to their bindings. */
export type HotkeyRegistry = Record<string, HotkeyDef>;

/** Metadata about a registered hotkey (for rendering help). */
export interface HotkeyInfo {
  readonly combo: string;
  readonly description: string;
}

/** Return type of the useHotkeys hook. */
export interface UseHotkeysReturn {
  /** Sorted list of registered hotkeys (for help display). */
  readonly hotkeys: readonly HotkeyInfo[];
}

// ── Key matching ─────────────────────────────────────────────────

interface ParsedCombo {
  ctrl: boolean;
  meta: boolean;
  shift: boolean;
  key: string;
}

const MODIFIER_NAMES = new Set(["ctrl", "meta", "shift"]);

function parseCombo(combo: string): ParsedCombo {
  const parts = combo
    .toLowerCase()
    .split("+")
    .map((s) => s.trim());
  return {
    ctrl: parts.includes("ctrl"),
    meta: parts.includes("meta"),
    shift: parts.includes("shift"),
    key: parts.find((p) => !MODIFIER_NAMES.has(p)) ?? "",
  };
}

/** Named key aliases for Ink's Key object. */
const KEY_ALIASES: Record<string, (key: Key) => boolean> = {
  return: (k) => k.return,
  enter: (k) => k.return,
  escape: (k) => k.escape,
  esc: (k) => k.escape,
  tab: (k) => k.tab,
  backspace: (k) => k.backspace,
  delete: (k) => k.delete,
  up: (k) => k.upArrow,
  down: (k) => k.downArrow,
  left: (k) => k.leftArrow,
  right: (k) => k.rightArrow,
  pageup: (k) => k.pageUp,
  pagedown: (k) => k.pageDown,
};

function matches(input: string, inkKey: Key, parsed: ParsedCombo): boolean {
  if (parsed.ctrl !== inkKey.ctrl) return false;
  if (parsed.meta !== inkKey.meta) return false;
  if (parsed.shift !== inkKey.shift) return false;

  const alias = KEY_ALIASES[parsed.key];
  if (alias) return alias(inkKey);

  return input.toLowerCase() === parsed.key;
}

// ── Hook ─────────────────────────────────────────────────────────

/**
 * Declarative global hotkey manager.
 *
 * Pass a record of `"combo": { description, handler }` bindings.
 * A single `useInput` listener matches keystrokes against all combos.
 *
 * Handlers are stored in a ref — closures are always fresh, and the
 * `useInput` callback is reference-stable so Ink never tears down
 * the stdin listener.
 */
export function useHotkeys(
  registry: HotkeyRegistry,
  opts?: { isActive?: boolean },
): UseHotkeysReturn {
  const registryRef = useRef(registry);
  registryRef.current = registry;

  const combos = useMemo(() => {
    const entries = Object.keys(registry).map((combo) => ({
      combo,
      parsed: parseCombo(combo),
    }));
    return entries;
    // Re-parse only when the set of combos changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [Object.keys(registry).sort().join(",")]);

  const combosRef = useRef(combos);
  combosRef.current = combos;

  useInput(
    (input, key) => {
      for (const { combo, parsed } of combosRef.current) {
        if (matches(input, key, parsed)) {
          registryRef.current[combo]?.handler();
          return;
        }
      }
    },
    { isActive: opts?.isActive ?? true },
  );

  const hotkeys = useMemo<readonly HotkeyInfo[]>(
    () =>
      Object.entries(registry).map(([combo, def]) => ({
        combo,
        description: def.description,
      })),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [Object.keys(registry).sort().join(",")],
  );

  return { hotkeys };
}
