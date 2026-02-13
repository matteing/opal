import React, { useState, type FC } from "react";
import { Box, Text, useInput } from "ink";
import TextInput from "ink-text-input";
import type { AuthFlow, AuthProvider, OpalActions } from "../hooks/use-opal.js";
import { openUrl, copyToClipboard } from "../open-url.js";

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

  useInput((_input, key) => {
    if (key.return && !opened && flow.deviceCode) {
      const copied = copyToClipboard(flow.deviceCode.userCode);
      openUrl(flow.deviceCode.verificationUri);
      setOpened(true);
      if (!copied) {
        // Clipboard failed — user will need to copy manually
        process.stderr.write("Could not copy to clipboard.\n");
      }
    }
  });

  return (
    <Box flexDirection="column" padding={1} gap={1}>
      <Text bold color="yellow">
        ✦ GitHub Copilot — Sign In
      </Text>
      <Box flexDirection="column" marginLeft={2}>
        <Text>
          Code:{" "}
          <Text bold color="green">
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

  useInput((_input, key) => {
    if (key.upArrow) setSelected((i) => Math.max(0, i - 1));
    if (key.downArrow) setSelected((i) => Math.min(providers.length - 1, i + 1));
    if (key.return) {
      const provider = providers[selected];
      if (!provider) return;
      if (provider.method === "device_code") {
        actions.authStartDeviceFlow();
      } else if (provider.method === "api_key") {
        // Trigger API key input by updating authFlow state — not ideal,
        // but the action just needs the provider info for the input screen.
        // We'll pass this through the action which updates state.
        actions.authSubmitKey(provider.id, "");
      }
    }
  });

  return (
    <Box flexDirection="column" padding={1} gap={1}>
      <Text bold color="yellow">
        ✦ Welcome to Opal
      </Text>
      <Text>Choose a provider to get started:</Text>
      <Box flexDirection="column" marginLeft={2}>
        {providers.map((p, i) => (
          <Text key={p.id}>
            {i === selected ? <Text color="cyan">❯ </Text> : <Text> </Text>}
            <Text bold={i === selected}>{p.name}</Text>
            <Text dimColor>
              {p.method === "device_code" ? " (sign in with browser)" : ` (${p.envVar})`}
            </Text>
          </Text>
        ))}
      </Box>
      {error && (
        <Text color="red" bold>
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

  return (
    <Box flexDirection="column" padding={1} gap={1}>
      <Text bold color="yellow">
        ✦ {provider.providerName} — Enter API Key
      </Text>
      <Box>
        <Text>API Key: </Text>
        <TextInput
          value={value}
          onChange={setValue}
          onSubmit={(key) => {
            if (key.trim()) {
              actions.authSubmitKey(provider.providerId, key.trim());
            }
          }}
          mask="*"
        />
      </Box>
      {error && (
        <Text color="red" bold>
          {error}
        </Text>
      )}
      <Text dimColor>Paste your key and press Enter</Text>
    </Box>
  );
};
