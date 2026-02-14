export function formatTokens(tokens: number | undefined): string {
  if (tokens == null) return "0";
  if (tokens >= 1000) {
    return Math.round(tokens / 1000) + "k";
  }
  return tokens.toString();
}
