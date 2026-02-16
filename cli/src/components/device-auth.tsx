import React, { useState, useCallback, useRef, type FC } from "react";
import { Box, Text, useInput, type Key } from "ink";
import { StableTextInput } from "./stable-text-input.js";
import type { AuthFlow, AuthProvider, OpalActions } from "../hooks/use-opal.js";
import { openUrl, copyToClipboard } from "../open-url.js";
import { colors } from "../lib/palette.js";

export interface SetupWizardProps {
  flow: AuthFlow;
  actions: OpalActions;
  error: string | null;
}

export const SetupWizard: FC<SetupWizardProps> = ({ flow, actions, error }) => {
  // Device-code flow is active — show code and wait
  if (flow.deviceCode) {
    return <DeviceCodeScreen flow={flow} />;
  }

  // API key input is active
  if (flow.apiKeyInput) {
    return <ApiKeyInput provider={flow.apiKeyInput} actions={actions} error={error} />;
  }

  // Default: show provider picker
  return <ProviderPicker providers={flow.providers} actions={actions} error={error} />;
};

// --- Device code screen ---

const DeviceCodeScreen: FC<{ flow: AuthFlow }> = ({ flow }) => {
  const [opened, setOpened] = useState(false);

  const openedRef = useRef(opened);
  openedRef.current = opened;
  const flowRef = useRef(flow);
  flowRef.current = flow;

  const deviceCodeHandler = useCallback((_input: string, key: Key) => {
    if (key.return && !openedRef.current && flowRef.current.deviceCode) {
      const copied = copyToClipboard(flowRef.current.deviceCode.userCode);
      openUrl(flowRef.current.deviceCode.verificationUri);
      setOpened(true);
      if (!copied) {
        process.stderr.write("Could not copy to clipboard.\n");
      }
    }
  }, []);

  useInput(deviceCodeHandler);

  return (
    <Box flexDirection="column" padding={1} gap={1}>
      <Text bold color={colors.warning}>
        ✦ GitHub Copilot — Sign In
      </Text>
      <Box flexDirection="column" marginLeft={2}>
        <Text>
          Code:{" "}
          <Text bold color={colors.success}>
            {flow.deviceCode?.userCode}
          </Text>
          {opened && <Text dimColor> (copied)</Text>}
        </Text>
      </Box>
      {opened ? (
        <Text dimColor>Browser opened — paste the code and authorize…</Text>
      ) : (
        <Text dimColor>Press Enter to copy code and open browser</Text>
      )}
    </Box>
  );
};

// --- Provider picker ---

const ProviderPicker: FC<{
  providers: AuthProvider[];
  actions: OpalActions;
  error: string | null;
}> = ({ providers, actions, error }) => {
  const [selected, setSelected] = useState(0);

  const selectedRef = useRef(selected);
  selectedRef.current = selected;
  const actionsRef = useRef(actions);
  actionsRef.current = actions;
  const providersRef = useRef(providers);
  providersRef.current = providers;

  const pickerHandler = useCallback((_input: string, key: Key) => {
    if (key.upArrow) setSelected((i) => Math.max(0, i - 1));
    if (key.downArrow) setSelected((i) => Math.min(providersRef.current.length - 1, i + 1));
    if (key.return) {
      const provider = providersRef.current[selectedRef.current];
      if (!provider) return;
      if (provider.method === "device_code") {
        actionsRef.current.authStartDeviceFlow();
      } else if (provider.method === "api_key") {
        actionsRef.current.authSubmitKey(provider.id, "");
      }
    }
  }, []);

  useInput(pickerHandler);

  return (
    <Box flexDirection="column" padding={1} gap={1}>
      <Text bold color={colors.warning}>
        ✦ Welcome to Opal
      </Text>
      <Text>Choose a provider to get started:</Text>
      <Box flexDirection="column" marginLeft={2}>
        {providers.map((p, i) => (
          <Text key={p.id}>
            {i === selected ? <Text color={colors.accentAlt}>❯ </Text> : <Text> </Text>}
            <Text bold={i === selected}>{p.name}</Text>
            <Text dimColor>
              {p.method === "device_code" ? " (sign in with browser)" : ` (${p.envVar})`}
            </Text>
          </Text>
        ))}
      </Box>
      {error && (
        <Text color={colors.error} bold>
          {error}
        </Text>
      )}
      <Text dimColor>↑↓ to select, Enter to continue</Text>
    </Box>
  );
};

// --- API key input ---

const ApiKeyInput: FC<{
  provider: { providerId: string; providerName: string };
  actions: OpalActions;
  error: string | null;
}> = ({ provider, actions, error }) => {
  const [value, setValue] = useState("");
  const actionsRef = useRef(actions);
  actionsRef.current = actions;
  const providerRef = useRef(provider);
  providerRef.current = provider;

  const handleSubmit = useCallback((key: string) => {
    if (key.trim()) {
      actionsRef.current.authSubmitKey(providerRef.current.providerId, key.trim());
    }
  }, []);

  return (
    <Box flexDirection="column" padding={1} gap={1}>
      <Text bold color={colors.warning}>
        ✦ {provider.providerName} — Enter API Key
      </Text>
      <Box>
        <Text>API Key: </Text>
        <StableTextInput value={value} onChange={setValue} onSubmit={handleSubmit} mask="*" />
      </Box>
      {error && (
        <Text color={colors.error} bold>
          {error}
        </Text>
      )}
      <Text dimColor>Paste your key and press Enter</Text>
    </Box>
  );
};
