defmodule Opal.Provider.EventStream do
  @moduledoc """
  A streaming handle for providers that emit pre-parsed event tuples.

  Unlike HTTP-based providers that return `Req.Response.t()` with raw SSE,
  library-wrapped providers (e.g., ReqLLM) can return this struct. The
  agent dispatches events directly to `handle_stream_event/2` without
  JSON serialization or SSE parsing.

  ## Message Protocol

  The provider spawns a process that sends messages to the agent:

    * `{ref, {:events, [Opal.Provider.stream_event()]}}` — batch of events
    * `{ref, :done}` — stream complete

  """

  @type t :: %__MODULE__{
          ref: reference(),
          cancel_fun: (-> :ok)
        }

  @enforce_keys [:ref, :cancel_fun]
  defstruct [:ref, :cancel_fun]
end
