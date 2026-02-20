/**
 * Auth slice — Copilot device-code authentication.
 *
 * Simple state machine: checking → needsAuth → deviceCode → polling → authenticated.
 *
 * @module
 */

import type { StateCreator } from "zustand";
import type { Session } from "../sdk/session.js";
import type { AuthStatus } from "./types.js";

// ── Slice state + actions ────────────────────────────────────────

export interface AuthSlice {
  authStatus: AuthStatus;
  deviceCode: string | null;
  verificationUri: string | null;
  authError: string | null;

  /** Probe session auth and determine if login is needed. */
  checkAuth: (session: Session) => void;
  /** Start the GitHub device-code login flow. */
  startDeviceFlow: (session: Session) => void;
  /** Re-check auth from scratch. */
  retryAuth: (session: Session) => void;
}

// ── Initial state ────────────────────────────────────────────────

const AUTH_INITIAL = {
  authStatus: "checking" as AuthStatus,
  deviceCode: null as string | null,
  verificationUri: null as string | null,
  authError: null as string | null,
};

// ── Slice creator ────────────────────────────────────────────────

export const createAuthSlice: StateCreator<AuthSlice, [], [], AuthSlice> = (set) => ({
  ...AUTH_INITIAL,

  checkAuth: (session) => {
    const { auth } = session;
    set({
      ...AUTH_INITIAL,
      authStatus: auth.status === "setup_required" ? "needsAuth" : "authenticated",
    });
  },

  startDeviceFlow: (session) => {
    set({ authStatus: "deviceCode", authError: null });

    void session.auth_
      .login()
      .then((flow) => {
        set({
          authStatus: "polling",
          deviceCode: flow.userCode,
          verificationUri: flow.verificationUri,
        });
        return session.auth_.poll(flow.deviceCode, flow.interval);
      })
      .then(() => {
        set({ ...AUTH_INITIAL, authStatus: "authenticated" });
      })
      .catch((err: unknown) => {
        set({
          authStatus: "error",
          authError: err instanceof Error ? err.message : String(err),
        });
      });
  },

  retryAuth: (session) => {
    set({ ...AUTH_INITIAL, authStatus: "checking" });

    void session.auth_
      .status()
      .then((res) => {
        set({
          ...AUTH_INITIAL,
          authStatus: res.authenticated ? "authenticated" : "needsAuth",
        });
      })
      .catch((err: unknown) => {
        set({
          authStatus: "error",
          authError: err instanceof Error ? err.message : String(err),
        });
      });
  },
});
