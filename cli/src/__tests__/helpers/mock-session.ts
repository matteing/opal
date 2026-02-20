/**
 * Mock Session factory for testing useOpal hook.
 * Provides a controllable Session instance with all methods as vi.fn().
 */
import { vi } from "vitest";
import { EventEmitter } from "node:events";
import type { AgentEvent } from "../../sdk/protocol.js";

export interface MockSession {
  sessionId: string;
  sessionDir: string;
  contextFiles: string[];
  availableSkills: string[];
  mcpServers: string[];
  nodeName: string;
  auth: { provider: string; providers: unknown[]; status: string };
  prompt: ReturnType<typeof vi.fn>;
  sendPrompt: ReturnType<typeof vi.fn>;
  abort: ReturnType<typeof vi.fn>;
  getState: ReturnType<typeof vi.fn>;
  compact: ReturnType<typeof vi.fn>;
  listModels: ReturnType<typeof vi.fn>;
  setModel: ReturnType<typeof vi.fn>;
  setThinkingLevel: ReturnType<typeof vi.fn>;
  getSettings: ReturnType<typeof vi.fn>;
  saveSettings: ReturnType<typeof vi.fn>;
  getOpalConfig: ReturnType<typeof vi.fn>;
  setOpalConfig: ReturnType<typeof vi.fn>;
  authStatus: ReturnType<typeof vi.fn>;
  authLogin: ReturnType<typeof vi.fn>;
  authPoll: ReturnType<typeof vi.fn>;
  ping: ReturnType<typeof vi.fn>;
  close: ReturnType<typeof vi.fn>;
  on: ReturnType<typeof vi.fn>;
  // Test helpers
  _emitter: EventEmitter;
  _emitEvent: (event: AgentEvent) => void;
}

export function createMockSession(overrides: Partial<MockSession> = {}): MockSession {
  const emitter = new EventEmitter();

  const session: MockSession = {
    sessionId: "test-session",
    sessionDir: "/tmp/test-session",
    contextFiles: [],
    availableSkills: [],
    mcpServers: [],
    nodeName: "opal@test",
    auth: { provider: "copilot", providers: [], status: "ready" },
    prompt: vi.fn(),
    sendPrompt: vi.fn().mockResolvedValue({ queued: true }),
    abort: vi.fn().mockResolvedValue(undefined),
    getState: vi.fn().mockResolvedValue({
      model: { id: "gpt-4", provider: "copilot", thinkingLevel: "off" },
      status: "idle",
      messageCount: 0,
      tools: [],
    }),
    compact: vi.fn().mockResolvedValue(undefined),
    listModels: vi.fn().mockResolvedValue({ models: [] }),
    setModel: vi.fn().mockResolvedValue({
      model: { id: "gpt-4", provider: "copilot", thinkingLevel: "off" },
    }),
    setThinkingLevel: vi.fn().mockResolvedValue({ thinkingLevel: "high" }),
    getSettings: vi.fn().mockResolvedValue({ settings: {} }),
    saveSettings: vi.fn().mockResolvedValue({ settings: {} }),
    getOpalConfig: vi.fn().mockResolvedValue({
      features: { subAgents: true, skills: true, mcp: true, debug: false },
      tools: { all: ["read_file", "shell"], enabled: ["read_file", "shell"], disabled: [] },
    }),
    setOpalConfig: vi.fn().mockResolvedValue({
      features: { subAgents: true, skills: true, mcp: true, debug: false },
      tools: { all: ["read_file", "shell"], enabled: ["read_file", "shell"], disabled: [] },
    }),
    authStatus: vi.fn().mockResolvedValue({ authenticated: true }),
    authLogin: vi.fn().mockResolvedValue({
      userCode: "ABCD-1234",
      verificationUri: "https://github.com/login/device",
      deviceCode: "dc-123",
      interval: 5,
    }),
    authPoll: vi.fn().mockResolvedValue({ authenticated: true }),
    ping: vi.fn().mockResolvedValue(undefined),
    close: vi.fn(),
    on: vi.fn(),
    _emitter: emitter,
    _emitEvent: (event: AgentEvent) => emitter.emit("event", event),
    ...overrides,
  };

  return session;
}

/**
 * Create an async iterable that yields events, useful for mocking session.prompt().
 */
export function createEventStream(events: AgentEvent[]): AsyncIterable<AgentEvent> {
  return {
    [Symbol.asyncIterator]() {
      let index = 0;
      return {
        async next() {
          if (index < events.length) {
            return { value: events[index++], done: false };
          }
          return { value: undefined as never, done: true };
        },
      };
    },
  };
}
