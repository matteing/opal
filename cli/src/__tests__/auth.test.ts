import { describe, it, expect } from "vitest";
import {
  buildAuthFlowState,
  applyDeviceCode,
  applyApiKeyInput,
  type AuthProvider,
} from "../lib/auth.js";

const copilot: AuthProvider = {
  id: "copilot",
  name: "GitHub Copilot",
  method: "device_code",
  ready: false,
};
const anthropic: AuthProvider = {
  id: "anthropic",
  name: "Anthropic",
  method: "api_key",
  envVar: "ANTHROPIC_API_KEY",
  ready: true,
};
const openai: AuthProvider = {
  id: "openai",
  name: "OpenAI",
  method: "api_key",
  envVar: "OPENAI_API_KEY",
  ready: false,
};

describe("buildAuthFlowState", () => {
  it("filters out ready providers", () => {
    const flow = buildAuthFlowState([copilot, anthropic, openai]);
    expect(flow.providers).toHaveLength(2);
    expect(flow.providers.map((p) => p.id)).toEqual(["copilot", "openai"]);
  });

  it("returns empty providers when all ready", () => {
    const flow = buildAuthFlowState([anthropic]);
    expect(flow.providers).toHaveLength(0);
  });

  it("returns all when none ready", () => {
    const flow = buildAuthFlowState([copilot, openai]);
    expect(flow.providers).toHaveLength(2);
  });
});

describe("applyDeviceCode", () => {
  it("sets deviceCode on existing flow", () => {
    const flow = buildAuthFlowState([copilot]);
    const result = applyDeviceCode(flow, {
      userCode: "ABCD-1234",
      verificationUri: "https://github.com/login/device",
    });
    expect(result?.deviceCode?.userCode).toBe("ABCD-1234");
    expect(result?.deviceCode?.verificationUri).toBe("https://github.com/login/device");
  });

  it("returns null when flow is null", () => {
    expect(applyDeviceCode(null, { userCode: "X", verificationUri: "Y" })).toBeNull();
  });

  it("preserves existing providers", () => {
    const flow = buildAuthFlowState([copilot, openai]);
    const result = applyDeviceCode(flow, { userCode: "X", verificationUri: "Y" });
    expect(result?.providers).toHaveLength(2);
  });
});

describe("applyApiKeyInput", () => {
  it("sets apiKeyInput with provider info", () => {
    const flow = buildAuthFlowState([copilot, openai]);
    const result = applyApiKeyInput(flow, "openai", "OpenAI");
    expect(result?.apiKeyInput?.providerId).toBe("openai");
    expect(result?.apiKeyInput?.providerName).toBe("OpenAI");
  });

  it("looks up provider name from flow when not provided", () => {
    const flow = buildAuthFlowState([copilot, openai]);
    const result = applyApiKeyInput(flow, "openai");
    expect(result?.apiKeyInput?.providerName).toBe("OpenAI");
  });

  it("uses providerId as fallback name", () => {
    const flow = buildAuthFlowState([copilot]);
    const result = applyApiKeyInput(flow, "unknown");
    expect(result?.apiKeyInput?.providerName).toBe("unknown");
  });

  it("returns null when flow is null", () => {
    expect(applyApiKeyInput(null, "openai")).toBeNull();
  });
});
