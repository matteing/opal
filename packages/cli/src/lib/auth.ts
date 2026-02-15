// Extracted from hooks/use-opal.ts for testability

export interface AuthProvider {
  id: string;
  name: string;
  method: "device_code" | "api_key";
  envVar?: string;
  ready: boolean;
}

export interface AuthFlow {
  providers: AuthProvider[];
  deviceCode?: { userCode: string; verificationUri: string };
  apiKeyInput?: { providerId: string; providerName: string };
}

/** Build an AuthFlow from a list of providers, filtering out ready ones. */
export function buildAuthFlowState(providers: AuthProvider[]): AuthFlow {
  return { providers: providers.filter((p) => !p.ready) };
}

/** Apply a device code response to an existing auth flow. Returns null if flow is null. */
export function applyDeviceCode(
  flow: AuthFlow | null,
  code: { userCode: string; verificationUri: string },
): AuthFlow | null {
  if (!flow) return null;
  return { ...flow, deviceCode: code };
}

/** Apply an API key input selection to an existing auth flow. */
export function applyApiKeyInput(
  flow: AuthFlow | null,
  providerId: string,
  providerName?: string,
): AuthFlow | null {
  if (!flow) return null;
  const provider = flow.providers.find((p) => p.id === providerId);
  return {
    ...flow,
    apiKeyInput: {
      providerId,
      providerName: providerName ?? provider?.name ?? providerId,
    },
  };
}
