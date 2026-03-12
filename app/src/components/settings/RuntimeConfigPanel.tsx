import { useState, useEffect } from "react";
import { bridge, type RuntimeConfig } from "../../sdk/bridge.js";

/** Runtime feature/tool toggles — matches CLI's /opal command. */
export function RuntimeConfigPanel({ onClose }: { onClose: () => void }) {
  const [config, setConfig] = useState<RuntimeConfig | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    bridge.getConfig().then((c) => {
      setConfig(c);
      setLoading(false);
    }).catch(() => setLoading(false));
  }, []);

  const toggleFeature = (key: keyof RuntimeConfig["features"]) => {
    if (!config) return;
    setConfig({
      ...config,
      features: { ...config.features, [key]: !config.features[key] },
    });
  };

  const toggleTool = (tool: string) => {
    if (!config) return;
    const isEnabled = config.tools.enabled.includes(tool);
    const enabled = isEnabled
      ? config.tools.enabled.filter((t) => t !== tool)
      : [...config.tools.enabled, tool];
    const disabled = isEnabled
      ? [...config.tools.disabled, tool]
      : config.tools.disabled.filter((t) => t !== tool);
    setConfig({ ...config, tools: { ...config.tools, enabled, disabled } });
  };

  const handleApply = () => {
    if (!config) return;
    bridge.setConfig({
      features: config.features,
      tools: config.tools.enabled,
    }).then(onClose).catch(() => {});
  };

  if (loading || !config) {
    return <dialog open><p>Loading configuration…</p></dialog>;
  }

  return (
    <dialog open>
      <h3>Runtime Configuration</h3>

      <fieldset>
        <legend>Features</legend>
        {(["subAgents", "skills", "debug"] as const).map((key) => (
          <label key={key}>
            <input
              type="checkbox"
              checked={config.features[key]}
              onChange={() => toggleFeature(key)}
            />
            {key === "subAgents" ? "Sub-agents" : key === "skills" ? "Skills" : "Debug introspection"}
          </label>
        ))}
      </fieldset>

      <fieldset>
        <legend>Tools</legend>
        {config.tools.all.map((tool) => (
          <label key={tool}>
            <input
              type="checkbox"
              checked={config.tools.enabled.includes(tool)}
              onChange={() => toggleTool(tool)}
            />
            {tool}
          </label>
        ))}
      </fieldset>

      <menu>
        <button onClick={handleApply}>Apply</button>
        <button onClick={onClose}>Cancel</button>
      </menu>
    </dialog>
  );
}
