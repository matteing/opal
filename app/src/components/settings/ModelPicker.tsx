import { useState, useEffect, useCallback } from "react";
import { bridge, type ModelInfo } from "../../sdk/bridge.js";

export function ModelPicker({
  currentModel,
  onClose,
}: {
  currentModel: string | null;
  onClose: () => void;
}) {
  const [models, setModels] = useState<ModelInfo[]>([]);
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState(currentModel ?? "");
  const [thinkingLevel, setThinkingLevel] = useState("medium");
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    bridge.listModels().then((r) => {
      setModels(r.models ?? []);
      setLoading(false);
    }).catch(() => setLoading(false));
  }, []);

  const filtered = search
    ? models.filter((m) => m.id.includes(search.toLowerCase()) || m.name.toLowerCase().includes(search.toLowerCase()))
    : models;

  // Group by provider family (first word of name, or provider field)
  const groups = new Map<string, ModelInfo[]>();
  for (const m of filtered) {
    const family = m.name.split(" ")[0] ?? m.provider;
    if (!groups.has(family)) groups.set(family, []);
    groups.get(family)!.push(m);
  }

  const handleSelect = useCallback(() => {
    if (!selected) return;
    bridge.setModel(selected, thinkingLevel).then(onClose).catch(() => {});
  }, [selected, thinkingLevel, onClose]);

  return (
    <dialog open>
      <h3>Select Model</h3>

      <input
        type="search"
        placeholder="Search models…"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        autoFocus
      />

      {loading ? (
        <p>Loading models…</p>
      ) : (
        <div data-role="model-list">
          {[...groups.entries()].map(([family, items]) => (
            <fieldset key={family}>
              <legend>{family}</legend>
              {items.map((m) => (
                <label key={m.id} data-selected={m.id === selected || undefined}>
                  <input
                    type="radio"
                    name="model"
                    value={m.id}
                    checked={m.id === selected}
                    onChange={() => setSelected(m.id)}
                  />
                  <span>{m.id}</span>
                  {m.supportsThinking && <small>thinking ✓</small>}
                </label>
              ))}
            </fieldset>
          ))}
        </div>
      )}

      <fieldset data-role="thinking-level">
        <legend>Thinking level</legend>
        {["off", "low", "medium", "high"].map((level) => (
          <label key={level}>
            <input
              type="radio"
              name="thinking"
              value={level}
              checked={thinkingLevel === level}
              onChange={() => setThinkingLevel(level)}
            />
            {level}
          </label>
        ))}
      </fieldset>

      <menu>
        <button onClick={handleSelect} disabled={!selected}>Select</button>
        <button onClick={onClose}>Cancel</button>
      </menu>
    </dialog>
  );
}
