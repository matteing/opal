// Extracted from hooks/use-opal.ts for testability

export interface OpalRuntimeConfig {
  features: {
    subAgents: boolean;
    skills: boolean;
    mcp: boolean;
    debug: boolean;
  };
  tools: {
    all: string[];
    enabled: string[];
    disabled: string[];
  };
}

/** Toggle a feature flag, returning a new config. */
export function toggleFeature(
  config: OpalRuntimeConfig,
  key: keyof OpalRuntimeConfig["features"],
  enabled: boolean,
): OpalRuntimeConfig {
  return {
    ...config,
    features: { ...config.features, [key]: enabled },
  };
}

/** Toggle a tool, returning a new config with correct enabled/disabled sets. */
export function toggleTool(
  config: OpalRuntimeConfig,
  name: string,
  enabled: boolean,
): OpalRuntimeConfig {
  const next = new Set(config.tools.enabled);
  if (enabled) next.add(name);
  else next.delete(name);
  const ordered = config.tools.all.filter((t) => next.has(t));
  return {
    ...config,
    tools: {
      ...config.tools,
      enabled: ordered,
      disabled: config.tools.all.filter((t) => !next.has(t)),
    },
  };
}
