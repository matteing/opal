/** Parsed model identifier. */
export interface ModelRef {
  provider: string;
  id: string;
}

/** Parse "provider/model-id" into structured form. Returns undefined if the string has no provider prefix. */
export function parseModel(raw: string): ModelRef | undefined {
  const [provider, ...rest] = raw.split("/");
  const id = rest.join("/");
  return provider && id ? { provider, id } : undefined;
}
