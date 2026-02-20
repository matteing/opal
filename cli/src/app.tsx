import { FC, useEffect, useMemo } from "react";
import { SessionOptions } from "./sdk/index.js";
import { ViewportProvider } from "./hooks/use-viewport.js";
import { StartingView } from "./views/starting-view.js";
import { ErrorView } from "./views/error-view.js";
import { AuthView } from "./views/auth-view.js";
import { OpalView } from "./views/opal-view.js";
import { useOpalStore } from "./state/store.js";
export type { ViewportSize } from "./hooks/use-viewport.js";

// Flat props: SessionOptions (which extends SessionStartParams) + a required sessionId.
// The TUI host is responsible for generating the session ID.
export type AppProps = SessionOptions & {
  sessionId: string;
};

export const App: FC<AppProps> = (opts) => {
  const connect = useOpalStore((s) => s.connect);
  const status = useOpalStore((s) => s.sessionStatus);
  const authStatus = useOpalStore((s) => s.authStatus);

  useEffect(() => {
    connect(opts);
  }, [connect, opts]);

  const scene = useMemo(() => {
    switch (status) {
      case "connecting":
        return <StartingView />;
      case "error":
        return <ErrorView />;
      case "ready":
        if (authStatus !== "authenticated") return <AuthView />;
        return <OpalView />;
      default:
        return null;
    }
  }, [status, authStatus]);

  return <ViewportProvider>{scene}</ViewportProvider>;
};
