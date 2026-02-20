import React, { useState, type FC } from "react";
import { Box, Text, useInput } from "ink";
import { openUrl, copyToClipboard } from "../lib/desktop.js";
import { colors } from "../lib/palette.js";
import { useOpalStore } from "../state/store.js";

// ── AuthView ─────────────────────────────────────────────────────

export const AuthView: FC = () => {
  const status = useOpalStore((s) => s.authStatus);
  const deviceCode = useOpalStore((s) => s.deviceCode);
  const verificationUri = useOpalStore((s) => s.verificationUri);
  const error = useOpalStore((s) => s.authError);

  switch (status) {
    case "deviceCode":
    case "polling":
      return (
        <DeviceCodeView code={deviceCode} uri={verificationUri} polling={status === "polling"} />
      );

    case "error":
      return <AuthErrorView message={error} />;

    case "needsAuth":
      return <NeedsAuthView />;

    default:
      return null;
  }
};

// ── NeedsAuthView ────────────────────────────────────────────────

const NeedsAuthView: FC = () => {
  const session = useOpalStore((s) => s.session);
  const startDeviceFlow = useOpalStore((s) => s.startDeviceFlow);

  useInput((_input, key) => {
    if (key.return && session) startDeviceFlow(session);
  });

  return (
    <Box flexDirection="column" padding={1} gap={1}>
      <Text bold color={colors.primary}>
        ✦ Welcome to Opal
      </Text>
      <Box flexDirection="column" marginLeft={2} gap={1}>
        <Text>GitHub Copilot sign-in is required to continue.</Text>
        <Text dimColor>
          Press{" "}
          <Text bold color={colors.primary}>
            Enter
          </Text>{" "}
          to open your browser and sign in with your GitHub account.
        </Text>
      </Box>
    </Box>
  );
};

// ── DeviceCodeView ───────────────────────────────────────────────

const DeviceCodeView: FC<{
  code: string | null;
  uri: string | null;
  polling: boolean;
}> = ({ code, uri, polling }) => {
  const [opened, setOpened] = useState(false);

  useInput((_input, key) => {
    if (key.return && !opened && code && uri) {
      copyToClipboard(code);
      openUrl(uri);
      setOpened(true);
    }
  });

  return (
    <Box flexDirection="column" padding={1} gap={1}>
      <Text bold color={colors.primary}>
        ✦ Welcome to Opal
      </Text>
      <Box flexDirection="column" marginLeft={2} gap={1}>
        <Text>
          Your one-time code:{" "}
          <Text bold color={colors.success}>
            {code}
          </Text>
          {opened && <Text dimColor> ✓ copied</Text>}
        </Text>
        {polling ? (
          <Text dimColor>Waiting for authorization — paste the code in your browser…</Text>
        ) : (
          <Text dimColor>
            Press{" "}
            <Text bold color={colors.primary}>
              Enter
            </Text>{" "}
            to copy the code to your clipboard and open the browser
          </Text>
        )}
      </Box>
    </Box>
  );
};

// ── AuthErrorView ────────────────────────────────────────────────

const AuthErrorView: FC<{ message: string | null }> = ({ message }) => {
  const session = useOpalStore((s) => s.session);
  const retryAuth = useOpalStore((s) => s.retryAuth);

  useInput((_input, key) => {
    if (key.return && session) retryAuth(session);
  });

  return (
    <Box flexDirection="column" padding={1} gap={1}>
      <Text bold color={colors.primary}>
        ✦ Welcome to Opal
      </Text>
      <Box flexDirection="column" marginLeft={2} gap={1}>
        <Text color={colors.error}>✖ Authentication failed</Text>
        {message && <Text dimColor>{message}</Text>}
        <Text dimColor>
          Press{" "}
          <Text bold color={colors.primary}>
            Enter
          </Text>{" "}
          to try again
        </Text>
      </Box>
    </Box>
  );
};
