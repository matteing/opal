import path from "node:path";

export function formatTokens(tokens: number | undefined): string {
  if (tokens == null) return "0";
  if (tokens >= 1000) {
    return Math.round(tokens / 1000) + "k";
  }
  return tokens.toString();
}

export interface ContextDisplayInput {
  files: string[];
  skills: string[];
  mcpServers: string[];
}

export function toRootRelativePath(filePath: string, rootDir?: string): string {
  if (!filePath || !rootDir || !path.isAbsolute(filePath)) return filePath;

  const resolvedRoot = path.resolve(rootDir);
  const relative = path.relative(resolvedRoot, path.resolve(filePath));

  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
    return filePath;
  }

  return relative.split(path.sep).join("/");
}

export function buildContextLoadedItems(context: ContextDisplayInput, rootDir?: string): string[] {
  const items: string[] = [];

  for (const file of context.files) {
    items.push(toRootRelativePath(file, rootDir));
  }

  if (context.skills.length > 0) {
    items.push(`skill: ${context.skills.join(", ")}`);
  }

  for (const server of context.mcpServers) {
    items.push(`mcp: ${server}`);
  }

  return items;
}
