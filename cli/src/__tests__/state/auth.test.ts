import { describe, it, expect, beforeEach, vi } from "vitest";
import { createStore } from "zustand/vanilla";
import { createAuthSlice, type AuthSlice } from "../../state/auth.js";
import type { Session } from "../../sdk/session.js";

function makeStore() {
  return createStore<AuthSlice>()(createAuthSlice);
}

/** Minimal mock session for auth operations. */
function mockSession(
  overrides: {
    auth?: { status: string; providers: Record<string, unknown>[] };
    auth_?: {
      login?: () => Promise<{
        userCode: string;
        verificationUri: string;
        deviceCode: string;
        interval: number;
      }>;
      poll?: (deviceCode: string, interval: number) => Promise<void>;
      status?: () => Promise<{
        authenticated: boolean;
        auth: { providers: Record<string, unknown>[] };
      }>;
    };
  } = {},
): Session {
  return {
    auth: overrides.auth ?? { status: "ok", providers: [] },
    auth_: {
      login:
        overrides.auth_?.login ??
        vi.fn().mockResolvedValue({
          userCode: "ABCD-1234",
          verificationUri: "https://github.com/login/device",
          deviceCode: "dc_123",
          interval: 5,
        }),
      poll: overrides.auth_?.poll ?? vi.fn().mockResolvedValue(undefined),
      status:
        overrides.auth_?.status ??
        vi.fn().mockResolvedValue({
          authenticated: true,
          auth: { providers: [] },
        }),
    },
  } as unknown as Session;
}

describe("AuthSlice", () => {
  let store: ReturnType<typeof makeStore>;

  beforeEach(() => {
    store = makeStore();
  });

  it("starts in checking status", () => {
    expect(store.getState().authStatus).toBe("checking");
  });

  // ── checkAuth ────────────────────────────────────────────────

  describe("checkAuth", () => {
    it("sets authenticated when no setup required", () => {
      const session = mockSession({ auth: { status: "ok", providers: [] } });
      store.getState().checkAuth(session);
      expect(store.getState().authStatus).toBe("authenticated");
    });

    it("sets needsAuth when setup required", () => {
      const session = mockSession({
        auth: {
          status: "setup_required",
          providers: [
            { id: "copilot", name: "GitHub Copilot", method: "device_code", ready: false },
          ],
        },
      });
      store.getState().checkAuth(session);
      expect(store.getState().authStatus).toBe("needsAuth");
    });
  });

  // ── startDeviceFlow ──────────────────────────────────────────

  describe("startDeviceFlow", () => {
    it("transitions through deviceCode → polling → authenticated", async () => {
      const poll = vi.fn().mockResolvedValue(undefined);
      const session = mockSession({ auth_: { poll } });

      store.getState().startDeviceFlow(session);
      expect(store.getState().authStatus).toBe("deviceCode");

      await vi.waitFor(() => {
        expect(store.getState().authStatus).toBe("authenticated");
      });

      expect(poll).toHaveBeenCalledWith("dc_123", 5);
    });

    it("sets device code and verification URI during polling", async () => {
      const poll = () => new Promise<void>((resolve) => setTimeout(resolve, 50));
      const session = mockSession({ auth_: { poll } });

      store.getState().startDeviceFlow(session);

      await vi.waitFor(() => {
        expect(store.getState().authStatus).toBe("polling");
      });

      expect(store.getState().deviceCode).toBe("ABCD-1234");
      expect(store.getState().verificationUri).toBe("https://github.com/login/device");
    });

    it("sets error on login failure", async () => {
      const session = mockSession({
        auth_: {
          login: () => Promise.reject(new Error("rate limited")),
        },
      });

      store.getState().startDeviceFlow(session);

      await vi.waitFor(() => {
        expect(store.getState().authStatus).toBe("error");
      });
      expect(store.getState().authError).toBe("rate limited");
    });

    it("sets error on poll failure", async () => {
      const session = mockSession({
        auth_: {
          poll: () => Promise.reject(new Error("timed out")),
        },
      });

      store.getState().startDeviceFlow(session);

      await vi.waitFor(() => {
        expect(store.getState().authStatus).toBe("error");
      });
      expect(store.getState().authError).toBe("timed out");
    });
  });

  // ── retryAuth ────────────────────────────────────────────────

  describe("retryAuth", () => {
    it("re-checks and sets authenticated", async () => {
      const session = mockSession();
      store.getState().retryAuth(session);
      expect(store.getState().authStatus).toBe("checking");

      await vi.waitFor(() => {
        expect(store.getState().authStatus).toBe("authenticated");
      });
    });

    it("re-checks and sets needsAuth when not authenticated", async () => {
      const session = mockSession({
        auth_: {
          status: () =>
            Promise.resolve({
              authenticated: false,
              auth: {
                providers: [
                  { id: "copilot", name: "GitHub Copilot", method: "device_code", ready: false },
                ],
              },
            }),
        },
      });

      store.getState().retryAuth(session);

      await vi.waitFor(() => {
        expect(store.getState().authStatus).toBe("needsAuth");
      });
    });

    it("sets error on status check failure", async () => {
      const session = mockSession({
        auth_: {
          status: () => Promise.reject(new Error("offline")),
        },
      });

      store.getState().retryAuth(session);

      await vi.waitFor(() => {
        expect(store.getState().authStatus).toBe("error");
      });
      expect(store.getState().authError).toBe("offline");
    });
  });
});
