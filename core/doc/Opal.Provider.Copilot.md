# `Opal.Provider.Copilot`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/provider/copilot.ex#L1)

GitHub Copilot provider implementation.

Supports two OpenAI API variants based on the model:

- **Chat Completions** (`/v1/chat/completions`) — used by most models
  (Claude, GPT-4o, Gemini, o3/o4, etc.)
- **Responses API** (`/v1/responses`) — used by GPT-5 family models

Streams responses via SSE into the calling process's mailbox using
`Req.post/2` with `into: :self`. The caller (typically `Opal.Agent`)
iterates chunks with `Req.parse_message/2`.

# `convert_tools`

Converts tool modules to the OpenAI function-calling format.
Works for both Chat Completions and Responses API.

# `parse_stream_event`

Parses a raw SSE JSON line into stream event tuples.

Handles both Chat Completions format (`choices[0].delta`) and
Responses API format (`response.output_text.delta`, etc.).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
