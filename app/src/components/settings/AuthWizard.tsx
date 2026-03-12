import { useState, useEffect, useCallback } from "react";
import { bridge } from "../../sdk/bridge.js";
import { CopyButton } from "../tools/CopyButton.js";

/** Device-code OAuth wizard shown when auth is needed. */
export function AuthWizard({ onComplete }: { onComplete: () => void }) {
  const [step, setStep] = useState<"loading" | "device" | "polling" | "done">("loading");
  const [userCode, setUserCode] = useState("");
  const [verificationUri, setVerificationUri] = useState("");
  const [error, setError] = useState<string | null>(null);

  const startFlow = useCallback(async () => {
    try {
      const result = await bridge.authLogin();
      setUserCode(result.userCode);
      setVerificationUri(result.verificationUri);
      setStep("device");

      // Start polling
      const poll = async () => {
        setStep("polling");
        try {
          const pollResult = await bridge.authPoll(result.deviceCode, result.interval);
          if (pollResult.authenticated) {
            setStep("done");
            setTimeout(onComplete, 1000);
          } else {
            setTimeout(poll, result.interval * 1000);
          }
        } catch {
          setTimeout(poll, result.interval * 1000);
        }
      };
      setTimeout(poll, result.interval * 1000);
    } catch (e) {
      setError(`Auth failed: ${e}`);
    }
  }, [onComplete]);

  useEffect(() => {
    bridge.authStatus().then((r) => {
      if (r.authenticated) {
        onComplete();
      } else {
        startFlow();
      }
    }).catch(() => startFlow());
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  if (step === "loading") {
    return (
      <div data-role="auth-wizard">
        <h2>✦ Opal Desktop</h2>
        <p>Checking authentication…</p>
      </div>
    );
  }

  if (step === "done") {
    return (
      <div data-role="auth-wizard">
        <h2>✦ Authenticated!</h2>
        <p>Redirecting…</p>
      </div>
    );
  }

  return (
    <div data-role="auth-wizard">
      <h2>✦ Opal Desktop</h2>
      <p>Authenticate with GitHub Copilot to get started.</p>

      <div data-role="auth-steps">
        <p>1. Go to: <a href={verificationUri} target="_blank" rel="noopener">{verificationUri}</a></p>
        <p>
          2. Enter code: <code>{userCode}</code> <CopyButton text={userCode} />
        </p>
        {step === "polling" && <p>Waiting for authorization… ⏳</p>}
      </div>

      {error && <p data-role="error">{error}</p>}
    </div>
  );
}
