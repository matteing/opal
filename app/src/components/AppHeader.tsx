import type { TokenUsage } from "../state/types.js";

export function AppHeader({
  workingDir,
  model,
  tokenUsage,
}: {
  workingDir: string;
  model: string | null;
  tokenUsage: TokenUsage | null;
}) {
  const pct = tokenUsage
    ? Math.round((tokenUsage.current / tokenUsage.contextWindow) * 100)
    : 0;

  return (
    <header>
      <strong>✦ Opal Desktop</strong>
      <span>{workingDir}</span>
      {model && <span>{model}</span>}
      {tokenUsage && (
        <span>
          <meter
            min={0}
            max={tokenUsage.contextWindow}
            value={tokenUsage.current}
            low={tokenUsage.contextWindow * 0.6}
            high={tokenUsage.contextWindow * 0.8}
            optimum={tokenUsage.contextWindow * 0.3}
          />
          {" "}
          {pct}%
        </span>
      )}
    </header>
  );
}
