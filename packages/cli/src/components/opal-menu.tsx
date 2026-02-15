import React, { useState, type FC } from "react";
import { Box, Text, useInput } from "ink";

export interface OpalMenuConfig {
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

export interface OpalMenuProps {
  config: OpalMenuConfig;
  onToggleFeature: (key: "subAgents" | "skills" | "mcp" | "debug", enabled: boolean) => void;
  onToggleTool: (name: string, enabled: boolean) => void;
  onDismiss: () => void;
}

type Section = "features" | "tools";

interface MenuItem {
  section: Section;
  label: string;
  key: string;
  enabled: boolean;
}

const FEATURE_LABELS: Record<string, string> = {
  subAgents: "Sub-agents",
  skills: "Skills",
  mcp: "MCP servers",
  debug: "Debug introspection",
};

function buildItems(config: OpalMenuConfig): MenuItem[] {
  const items: MenuItem[] = [];

  // Features section
  for (const key of ["subAgents", "skills", "mcp", "debug"] as const) {
    items.push({
      section: "features",
      label: FEATURE_LABELS[key] ?? key,
      key,
      enabled: config.features[key],
    });
  }

  // Tools section
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

export const OpalMenu: FC<OpalMenuProps> = ({
  config,
  onToggleFeature,
  onToggleTool,
  onDismiss,
}) => {
  const items = buildItems(config);
  const [selected, setSelected] = useState(0);

  useInput((_input, key) => {
    if (key.upArrow) {
      setSelected((s) => Math.max(0, s - 1));
    } else if (key.downArrow) {
      setSelected((s) => Math.min(items.length - 1, s + 1));
    } else if (key.return || _input === " ") {
      const item = items[selected];
      if (item.section === "features") {
        onToggleFeature(item.key as "subAgents" | "skills" | "mcp" | "debug", !item.enabled);
      } else {
        onToggleTool(item.key, !item.enabled);
      }
    } else if (key.escape || (_input === "c" && key.ctrl)) {
      onDismiss();
    }
  });

  // Find section boundaries
  const featureStart = items.findIndex((i) => i.section === "features");
  const toolStart = items.findIndex((i) => i.section === "tools");

  return (
    <Box flexDirection="column" borderStyle="round" borderColor="magenta" paddingX={2} paddingY={1}>
      <Text bold color="magenta">
        Opal Configuration
      </Text>
      <Text dimColor>↑↓ navigate · space/enter toggle · esc close</Text>

      {/* Features section */}
      {featureStart >= 0 && (
        <Box flexDirection="column" marginTop={1}>
          <Text bold dimColor>
            Features
          </Text>
          {items
            .filter((i) => i.section === "features")
            .map((item, _fi) => {
              const idx = featureStart + _fi;
              const isSelected = idx === selected;
              return (
                <Text key={item.key}>
                  <Text color={isSelected ? "magenta" : undefined}>{isSelected ? "❯" : " "}</Text>{" "}
                  <Text color={item.enabled ? "green" : "red"}>{item.enabled ? "✓" : "✗"}</Text>{" "}
                  <Text bold={isSelected} color={isSelected ? "magenta" : undefined}>
                    {item.label}
                  </Text>
                  <Text dimColor> {item.enabled ? "on" : "off"}</Text>
                </Text>
              );
            })}
        </Box>
      )}

      {/* Tools section */}
      {toolStart >= 0 && (
        <Box flexDirection="column" marginTop={1}>
          <Text bold dimColor>
            Tools
          </Text>
          {items
            .filter((i) => i.section === "tools")
            .map((item, _ti) => {
              const idx = toolStart + _ti;
              const isSelected = idx === selected;
              return (
                <Text key={item.key}>
                  <Text color={isSelected ? "magenta" : undefined}>{isSelected ? "❯" : " "}</Text>{" "}
                  <Text color={item.enabled ? "green" : "red"}>{item.enabled ? "✓" : "✗"}</Text>{" "}
                  <Text bold={isSelected} color={isSelected ? "magenta" : undefined}>
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
