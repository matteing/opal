/**
 * Opal JSON-RPC 2.0 protocol schemas.
 *
 * Hand-written Zod schemas matching the Elixir protocol definition in
 * opal/lib/opal/rpc/protocol.ex. Protocol version: 0.2.0.
 *
 * Transport: spawn the `opal` binary, write newline-delimited JSON to stdin,
 * read newline-delimited JSON from stdout.
 *
 * @example
 * import { AgentEventSchema, RpcResponseSchema } from "@opal/types";
 * const event = AgentEventSchema.parse(JSON.parse(line));
 */

import { z } from "zod";

// ─────────────────────────────────────────────────────────────────────────────
// Shared primitives
// ─────────────────────────────────────────────────────────────────────────────

export const TokenUsageSchema = z.object({
  prompt_tokens: z.number().int(),
  completion_tokens: z.number().int(),
  total_tokens: z.number().int(),
  context_window: z.number().int().optional(),
  current_context_tokens: z.number().int().optional(),
});
export type TokenUsage = z.infer<typeof TokenUsageSchema>;

export const ModelSchema = z.object({
  provider: z.string(),
  id: z.string(),
  thinking_level: z.string().optional(),
});
export type Model = z.infer<typeof ModelSchema>;

export const ToolResultSchema = z.discriminatedUnion("ok", [
  z.object({ ok: z.literal(true), output: z.string(), meta: z.record(z.unknown()).optional() }),
  z.object({ ok: z.literal(false), error: z.string() }),
]);
export type ToolResult = z.infer<typeof ToolResultSchema>;

export const AuthStatusSchema = z.object({
  status: z.string(),
  provider: z.string().nullable(),
});
export type AuthStatus = z.infer<typeof AuthStatusSchema>;

// ─────────────────────────────────────────────────────────────────────────────
// Agent events (server → client notifications via agent/event)
// ─────────────────────────────────────────────────────────────────────────────

export const AgentEventSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("agent_start") }),

  z.object({
    type: z.literal("agent_end"),
    usage: TokenUsageSchema.optional(),
  }),

  z.object({ type: z.literal("agent_abort") }),

  z.object({ type: z.literal("agent_recovered") }),

  z.object({ type: z.literal("message_start") }),

  z.object({
    type: z.literal("message_delta"),
    delta: z.string(),
  }),

  z.object({
    type: z.literal("message_queued"),
    text: z.string(),
  }),

  z.object({
    type: z.literal("message_applied"),
    text: z.string(),
  }),

  z.object({ type: z.literal("thinking_start") }),

  z.object({
    type: z.literal("thinking_delta"),
    delta: z.string(),
  }),

  z.object({
    type: z.literal("tool_start"),
    tool: z.string(),
    call_id: z.string(),
    args: z.unknown(),
    meta: z.unknown().optional(),
  }),

  z.object({
    type: z.literal("tool_end"),
    tool: z.string(),
    call_id: z.string(),
    result: ToolResultSchema,
  }),

  z.object({
    type: z.literal("tool_output"),
    tool: z.string(),
    call_id: z.string(),
    chunk: z.string(),
  }),

  z.object({
    type: z.literal("turn_end"),
    message: z.string(),
  }),

  z.object({
    type: z.literal("status_update"),
    message: z.string(),
  }),

  z.object({
    type: z.literal("error"),
    reason: z.string(),
  }),

  z.object({
    type: z.literal("context_discovered"),
    files: z.array(z.string()),
  }),

  z.object({
    type: z.literal("skill_loaded"),
    name: z.string(),
    description: z.string(),
  }),

  z.object({
    type: z.literal("usage_update"),
    usage: TokenUsageSchema,
  }),

]);
export type AgentEvent = z.infer<typeof AgentEventSchema>;

// ─────────────────────────────────────────────────────────────────────────────
// JSON-RPC 2.0 wire types
// ─────────────────────────────────────────────────────────────────────────────

/** Any message coming out of the opal binary on stdout. */
export const OpalMessageSchema = z.union([
  // Response to a client→server request
  z.object({
    jsonrpc: z.literal("2.0"),
    id: z.union([z.string(), z.number()]),
    result: z.record(z.unknown()),
  }),
  // Error response
  z.object({
    jsonrpc: z.literal("2.0"),
    id: z.union([z.string(), z.number(), z.null()]),
    error: z.object({
      code: z.number().int(),
      message: z.string(),
      data: z.unknown().optional(),
    }),
  }),
  // agent/event notification
  z.object({
    jsonrpc: z.literal("2.0"),
    method: z.literal("agent/event"),
    params: z.object({
      session_id: z.string(),
      type: z.string(),
    }).passthrough(),
  }),
  // client/request server→client round-trip
  z.object({
    jsonrpc: z.literal("2.0"),
    id: z.string(),
    method: z.literal("client/request"),
    params: z.object({
      session_id: z.string(),
      kind: z.enum(["confirm", "input", "ask"]),
    }).passthrough(),
  }),
]);
export type OpalMessage = z.infer<typeof OpalMessageSchema>;

// ─────────────────────────────────────────────────────────────────────────────
// client/request — server → client interactive requests
// ─────────────────────────────────────────────────────────────────────────────

export const ClientRequestConfirmSchema = z.object({
  session_id: z.string(),
  kind: z.literal("confirm"),
  title: z.string(),
  message: z.string(),
  actions: z.array(z.string()),
});

export const ClientRequestInputSchema = z.object({
  session_id: z.string(),
  kind: z.literal("input"),
  prompt: z.string(),
  sensitive: z.boolean().optional(),
});

export const ClientRequestAskSchema = z.object({
  session_id: z.string(),
  kind: z.literal("ask"),
  question: z.string(),
  choices: z.array(z.string()).optional(),
});

export const ClientRequestParamsSchema = z.discriminatedUnion("kind", [
  ClientRequestConfirmSchema,
  ClientRequestInputSchema,
  ClientRequestAskSchema,
]);
export type ClientRequestParams = z.infer<typeof ClientRequestParamsSchema>;

// ─────────────────────────────────────────────────────────────────────────────
// Method params (client → server)
// ─────────────────────────────────────────────────────────────────────────────

export const SessionStartParamsSchema = z.object({
  working_dir: z.string().optional(),
  model: z.object({
    id: z.string(),
    thinking_level: z.string().optional(),
  }).optional(),
  system_prompt: z.string().optional(),
  features: z.object({
    skills: z.boolean().optional(),
    debug: z.boolean().optional(),
  }).optional(),
  session: z.boolean().optional(),
  session_id: z.string().optional(),
});
export type SessionStartParams = z.infer<typeof SessionStartParamsSchema>;

export const SessionStartResultSchema = z.object({
  session_id: z.string(),
  session_dir: z.string(),
  context_files: z.array(z.string()),
  available_skills: z.array(z.string()),
  node_name: z.string(),
  auth: AuthStatusSchema,
});
export type SessionStartResult = z.infer<typeof SessionStartResultSchema>;

export const AgentPromptParamsSchema = z.object({
  session_id: z.string(),
  text: z.string(),
});

export const ModelSetParamsSchema = z.object({
  session_id: z.string(),
  model_id: z.string(),
  thinking_level: z.enum(["off", "low", "medium", "high", "max"]).optional(),
});
