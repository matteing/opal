/**
 * Opal configuration overlay — self-contained config panel.
 *
 * Fetches runtime config on mount, lets the user toggle features
 * and tools with optimistic updates, and persists via session RPC.
 *
 * @module
 */

import React, { useState, useEffect, useCallback, type FC } from "react";
import { Box, Text, useInput } from "ink";
import { colors } from "../lib/palette.js";
import type {
  OpalConfigGetResult,
  OpalConfigSetParams,
  OpalConfigSetResult,
} from "../sdk/protocol.js";

// ── Types ────────────────────────────────────────────────────

type FeatureKey = "subAgents" | "skills" | "mcp" | "debug";
type Section = "features" | "tools";

interface MenuItem {
  section: Section;
  label: string;
  key: string;
  enabled: boolean;
}

const FEATURE_LABELS: Record<FeatureKey, string> = {
  subAgents: "Sub-agents",
  skills: "Skills",
  mcp: "MCP servers",
  debug: "Debug introspection",
};

const FEATURE_KEYS: FeatureKey[] = ["subAgents", "skills", "mcp", "debug"];

// ── Props ────────────────────────────────────────────────────

export interface ConfigPanelProps {
  /** Fetch current runtime config from the session. */
  getConfig: () => Promise<OpalConfigGetResult>;
  /** Persist a config patch to the session. */
  setConfig: (patch: Omit<OpalConfigSetParams, "sessionId">) => Promise<OpalConfigSetResult>;
  onDismiss: () => void;
}

// ── Helpers ──────────────────────────────────────────────────

function buildItems(config: OpalConfigGetResult): MenuItem[] {
  const items: MenuItem[] = [];
  for (const key of FEATURE_KEYS) {
    items.push({
      section: "features",
      label: FEATURE_LABELS[key],
      key,
      enabled: config.features[key],
    });
  }
  for (const name of config.tools.all) {
    items.push({
      section: "tools",
      label: name,
      key: name,
      enabled: config.tools.enabled.includes(name),
    });
  }
  return items;
}

// ── Component ────────────────────────────────────────────────

export const ConfigPanel: FC<ConfigPanelProps> = ({
  getConfig,
  setConfig,
  onDismiss,
}) => {
  const [config, setLocalConfig] = useState<OpalConfigGetResult | null>(null);
  const [selected, setSelected] = useState(0);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void getConfig()
      .then(setLocalConfig)
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
      });
  }, [getConfig]);

  const items = config ? buildItems(config) : [];

  const toggleItem = useCallback(
    (item: MenuItem) => {
      if (!config) return;
      const newEnabled = !item.enabled;

      if (item.section === "features") {
        const features = { ...config.features, [item.key]: newEnabled };
        setLocalConfig({ ...config, features });
        void setConfig({ features }).then(setLocalConfig).catch(() => {
          setLocalConfig(config);
        });
      } else {
        const enabled = newEnabled
          ? [...config.tools.enabled, item.key]
          : config.tools.enabled.filter((t) => t !== item.key);
        const disabled = newEnabled
          ? config.tools.disabled.filter((t) => t !== item.key)
          : [...config.tools.disabled, item.key];
        setLocalConfig({ ...config, tools: { ...config.tools, enabled, disabled } });
        void setConfig({ tools: enabled }).then(setLocalConfig).catch(() => {
          setLocalConfig(config);
        });
      }
    },
    [config, setConfig],
  );

  useInput((_input, key) => {
    if (!config) {
      if (key.escape || (_input === "c" && key.ctrl)) onDismiss();
      return;
    }
    if (key.upArrow) {
      setSelected((s) => Math.max(0, s - 1));
    } else if (key.downArrow) {
      setSelected((s) => Math.min(items.length - 1, s + 1));
    } else if (key.return || _input === " ") {
      const item = items[selected];
      if (item) toggleItem(item);
    } else if (key.escape || (_input === "c" && key.ctrl)) {
      onDismiss();
    }
  });

  if (!config && !error) {
    return (
      <Box borderStyle="round" borderColor={colors.accent} paddingX={2} paddingY={1}>
        <Text dimColor italic>
          Loading configuration…
        </Text>
      </Box>
    );
  }

  if (error) {
    return (
      <Box
        flexDirection="column"
        borderStyle="round"
        borderColor={colors.error}
        paddingX={2}
        paddingY={1}
      >
        <Text color={colors.error}>Failed to load config: {error}</Text>
        <Text dimColor>esc to close</Text>
      </Box>
    );
  }

  const featureStart = items.findIndex((i) => i.section === "features");
  const toolStart = items.findIndex((i) => i.section === "tools");

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor={colors.accent}
      paddingX={2}
      paddingY={1}
    >
      <Text bold color={colors.accent}>
        Opal Configuration
      </Text>
      <Text dimColor>↑↓ navigate · space toggle · esc close</Text>

      {featureStart >= 0 && (
        <Box flexDirection="column" marginTop={1}>
          <Text bold dimColor>
            Features
          </Text>
          {items
            .filter((i) => i.section === "features")
            .map((item, fi) => {
              const idx = featureStart + fi;
              const isSelected = idx === selected;
              return (
                <Text key={item.key}>
                  <Text color={isSelected ? colors.accent : undefined}>
                    {isSelected ? "❯" : " "}
                  </Text>{" "}
                  <Text color={item.enabled ? colors.success : colors.error}>
                    {item.enabled ? "✓" : "✗"}
                  </Text>{" "}
                  <Text bold={isSelected} color={isSelected ? colors.accent : undefined}>
                    {item.label}
                  </Text>
                  <Text dimColor> {item.enabled ? "on" : "off"}</Text>
                </Text>
              );
            })}
        </Box>
      )}

      {toolStart >= 0 && (
        <Box flexDirection="column" marginTop={1}>
          <Text bold dimColor>
            Tools
          </Text>
          {items
            .filter((i) => i.section === "tools")
            .map((item, ti) => {
              const idx = toolStart + ti;
              const isSelected = idx === selected;
              return (
                <Text key={item.key}>
                  <Text color={isSelected ? colors.accent : undefined}>
                    {isSelected ? "❯" : " "}
                  </Text>{" "}
                  <Text color={item.enabled ? colors.success : colors.error}>
                    {item.enabled ? "✓" : "✗"}
                  </Text>{" "}
                  <Text bold={isSelected} color={isSelected ? colors.accent : undefined}>
                    {item.label}
                  </Text>
                  <Text dimColor> {item.enabled ? "on" : "off"}</Text>
                </Text>
              );
            })}
        </Box>
      )}
    </Box>
  );
};
