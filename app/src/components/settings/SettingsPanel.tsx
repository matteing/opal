import { useState, useEffect } from "react";
import { bridge } from "../../sdk/bridge.js";

export function SettingsPanel({ onClose }: { onClose: () => void }) {
  const [settings, setSettings] = useState<Record<string, unknown>>({});
  const [loading, setLoading] = useState(true);
  const [version, setVersion] = useState<{ serverVersion: string; protocolVersion: string } | null>(null);

  useEffect(() => {
    Promise.all([
      bridge.getSettings().then((r) => setSettings(r.settings ?? {})),
      bridge.getVersion().then(setVersion).catch(() => {}),
    ]).finally(() => setLoading(false));
  }, []);

  const handleSave = () => {
    bridge.saveSettings(settings).then(onClose).catch(() => {});
  };

  const toggle = (key: string) => {
    setSettings((s) => ({ ...s, [key]: !s[key] }));
  };

  if (loading) {
    return (
      <dialog open>
        <p>Loading settings…</p>
      </dialog>
    );
  }

  return (
    <dialog open>
      <h3>Settings</h3>

      <fieldset>
        <legend>Behavior</legend>
        <label>
          <input type="checkbox" checked={!!settings.auto_confirm} onChange={() => toggle("auto_confirm")} />
          Auto-confirm tool executions
        </label>
        <label>
          <input type="checkbox" checked={settings.show_thinking !== false} onChange={() => toggle("show_thinking")} />
          Show thinking text
        </label>
      </fieldset>

      {version && (
        <fieldset>
          <legend>About</legend>
          <p>Opal Server {version.serverVersion}</p>
          <p>Protocol {version.protocolVersion}</p>
        </fieldset>
      )}

      <menu>
        <button onClick={handleSave}>Save</button>
        <button onClick={onClose}>Cancel</button>
      </menu>
    </dialog>
  );
}
