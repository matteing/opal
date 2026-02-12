# `Opal.Session.Compaction`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/session/compaction.ex#L1)

Context window compaction following pi's approach.

Summarizes older messages using the agent's LLM, producing a structured
summary that preserves goals, progress, decisions, and file operations.
Falls back to truncation if no agent is available.

## How it works

1. Walk backwards from the newest message, estimating tokens, until
   `keep_recent_tokens` (default 20k) is reached — this is the cut point.
2. Cut at a turn boundary (user message), never mid-turn.
3. Serialize messages before the cut point into a text transcript.
4. Ask the LLM to produce a structured summary.
5. Replace old messages with a single summary message.

## Usage

    Opal.Session.Compaction.compact(session, agent: agent_pid)
    Opal.Session.Compaction.compact(session, strategy: :truncate)

# `compact`

```elixir
@spec compact(
  GenServer.server(),
  keyword()
) :: :ok | {:error, term()}
```

Compacts old messages in the session.

## Options

  * `:agent` — Agent pid for LLM summarization (calls get_state to get provider/model)
  * `:provider` — Provider module (alternative to `:agent`, avoids GenServer call)
  * `:model` — Model struct (required when `:provider` is given)
  * `:strategy` — `:summarize` (default if provider available) or `:truncate`
  * `:keep_recent_tokens` — tokens to keep uncompacted (default: 20000)
  * `:instructions` — optional focus instructions for the summary

# `extract_file_ops`

```elixir
@spec extract_file_ops([Opal.Message.t()]) :: %{
  read: [String.t()],
  modified: [String.t()]
}
```

Extracts file read/write operations from tool calls in messages.

# `serialize_conversation`

```elixir
@spec serialize_conversation([Opal.Message.t()]) :: String.t()
```

Serializes messages into a text transcript for summarization.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
