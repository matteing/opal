import path from "node:path";

export function formatTokens(tokens: number | undefined): string {
  if (tokens == null) return "0";
  if (tokens >= 1000) {
    return Math.round(tokens / 1000) + "k";
  }
  return tokens.toString();
}

export function toRootRelativePath(filePath: string, rootDir?: string): string {
  if (!filePath || !rootDir || !path.isAbsolute(filePath)) return filePath;

  const resolvedRoot = path.resolve(rootDir);
  const relative = path.relative(resolvedRoot, path.resolve(filePath));

  if (!relative || path.isAbsolute(relative)) {
    return filePath;
  }

  return relative.split(path.sep).join("/");
}
