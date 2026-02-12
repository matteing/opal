defmodule Opal.RPC.Protocol do
  @moduledoc """
  Declarative protocol specification for the Opal JSON-RPC 2.0 API.

  This module is the **single source of truth** for the Opal RPC protocol.
  Every method, notification, event type, and server→client request is
  defined here as structured data. The handler dispatches only methods
  listed here; the stdio transport serializes only event types listed here.

  ## Design Goals

    * **Machine-readable** — the definitions are plain Elixir data structures
      that a code generator can traverse to produce TypeScript types, JSON
      Schema, or documentation.
    * **Self-documenting** — each definition carries its own description,
      required/optional params, and result shape.
    * **Single source of truth** — `Opal.RPC.Handler` and `Opal.RPC.Stdio`
      reference these definitions rather than embedding protocol knowledge.

  ## Usage

      # List all method names
      Opal.RPC.Protocol.method_names()

      # Get a specific method definition
      Opal.RPC.Protocol.method("agent/prompt")

      # List all event types
      Opal.RPC.Protocol.event_types()

      # List server→client request methods
      Opal.RPC.Protocol.server_request_names()

      # Full spec for export/codegen
      Opal.RPC.Protocol.spec()
  """

  # -- Types --

  @typedoc "A structured type descriptor for codegen."
  @type type_desc ::
          :string
          | :boolean
          | :integer
          | :object
          | {:array, type_desc()}
          | {:object, %{String.t() => type_desc()}}
          | {:optional_fields, %{String.t() => type_desc()}}

  @typedoc "A parameter field definition."
  @type param :: %{
          name: String.t(),
          type: type_desc(),
          required: boolean(),
          description: String.t()
        }

  @typedoc "A result field definition."
  @type result_field :: %{
          name: String.t(),
          type: type_desc(),
          description: String.t()
        }

  @typedoc "A client→server method definition."
  @type method_def :: %{
          method: String.t(),
          direction: :client_to_server,
          description: String.t(),
          params: [param()],
          result: [result_field()]
        }

  @typedoc "A server→client request definition."
  @type server_request_def :: %{
          method: String.t(),
          direction: :server_to_client,
          description: String.t(),
          params: [param()],
          result: [result_field()]
        }

  @typedoc "A server→client notification event type."
  @type event_type_def :: %{
          type: String.t(),
          description: String.t(),
          fields: [result_field()]
        }

  # ---------------------------------------------------------------------------
  # Client → Server Methods
  # ---------------------------------------------------------------------------

  @methods [
    %{
      method: "session/start",
      direction: :client_to_server,
      description: "Start a new agent session.",
      params: [
        %{name: "model", type: {:object, %{"provider" => :string, "id" => :string}}, required: false,
          description: "Model to use. Defaults to config default."},
        %{name: "system_prompt", type: :string, required: false,
          description: "System prompt for the agent."},
        %{name: "working_dir", type: :string, required: false,
          description: "Working directory. Defaults to server cwd."},
        %{name: "tools", type: {:array, :string}, required: false,
          description: "Tool names to enable."},
        %{name: "mcp_servers", type: {:array, :object}, required: false,
          description: "MCP server configurations."},
        %{name: "session", type: :boolean, required: false,
          description: "If true, enable session persistence."}
      ],
      result: [
        %{name: "session_id", type: :string, description: "The new session's unique ID."},
        %{name: "context_files", type: {:array, :string}, description: "Paths of loaded context files."},
        %{name: "available_skills", type: {:array, :string}, description: "Names of discovered skills (not yet loaded)."},
        %{name: "node_name", type: :string, description: "Erlang node name of the server (for debugging)."}
      ]
    },
    %{
      method: "agent/prompt",
      direction: :client_to_server,
      description: "Send an async user prompt. Results stream as agent/event notifications.",
      params: [
        %{name: "session_id", type: :string, required: true,
          description: "Target session ID."},
        %{name: "text", type: :string, required: true,
          description: "The user's prompt text."}
      ],
      result: []
    },
    %{
      method: "agent/steer",
      direction: :client_to_server,
      description: "Steer the agent mid-run. If idle, acts like agent/prompt.",
      params: [
        %{name: "session_id", type: :string, required: true,
          description: "Target session ID."},
        %{name: "text", type: :string, required: true,
          description: "The steering message."}
      ],
      result: []
    },
    %{
      method: "agent/abort",
      direction: :client_to_server,
      description: "Abort the current agent run.",
      params: [
        %{name: "session_id", type: :string, required: true,
          description: "Target session ID."}
      ],
      result: []
    },
    %{
      method: "agent/state",
      direction: :client_to_server,
      description: "Get the current agent state.",
      params: [
        %{name: "session_id", type: :string, required: true,
          description: "Target session ID."}
      ],
      result: [
        %{name: "session_id", type: :string, description: "Session ID."},
        %{name: "status", type: :string, description: "One of: idle, running, streaming."},
        %{name: "model", type: {:object, %{"provider" => :string, "id" => :string}}, description: "Current model."},
        %{name: "message_count", type: :integer, description: "Number of messages in history."},
        %{name: "tools", type: {:array, :string}, description: "Active tool names."}
      ]
    },
    %{
      method: "session/list",
      direction: :client_to_server,
      description: "List saved sessions on disk.",
      params: [],
      result: [
        %{name: "sessions", type: {:array, :object}, description: "Array of {id, title, modified}."}
      ]
    },
    %{
      method: "session/branch",
      direction: :client_to_server,
      description: "Branch the conversation at a specific message.",
      params: [
        %{name: "session_id", type: :string, required: true,
          description: "Target session ID."},
        %{name: "entry_id", type: :string, required: true,
          description: "Message ID to branch from."}
      ],
      result: []
    },
    %{
      method: "session/compact",
      direction: :client_to_server,
      description: "Compact older messages in the session. (Not yet implemented.)",
      params: [
        %{name: "session_id", type: :string, required: true,
          description: "Target session ID."},
        %{name: "keep_recent", type: :integer, required: false,
          description: "Number of recent messages to keep. Default: 10."}
      ],
      result: []
    },
    %{
      method: "models/list",
      direction: :client_to_server,
      description: "List available LLM models.",
      params: [],
      result: [
        %{name: "models", type: {:array, :object}, description: "Array of {id, name}."}
      ]
    },
    %{
      method: "model/set",
      direction: :client_to_server,
      description: "Change the model for a running session.",
      params: [
        %{name: "session_id", type: :string, required: true,
          description: "Target session ID."},
        %{name: "model_id", type: :string, required: true,
          description: "Model ID to switch to."}
      ],
      result: [
        %{name: "model", type: {:object, %{"provider" => :string, "id" => :string}}, description: "The new active model."}
      ]
    },
    %{
      method: "auth/status",
      direction: :client_to_server,
      description: "Check whether the server is authenticated.",
      params: [],
      result: [
        %{name: "authenticated", type: :boolean, description: "True if a valid token exists."}
      ]
    },
    %{
      method: "auth/login",
      direction: :client_to_server,
      description: "Start the device-code OAuth login flow.",
      params: [],
      result: [
        %{name: "user_code", type: :string, description: "Code for the user to enter."},
        %{name: "verification_uri", type: :string, description: "URL to visit."},
        %{name: "device_code", type: :string, description: "Device code for polling."},
        %{name: "interval", type: :integer, description: "Polling interval in seconds."}
      ]
    },
    %{
      method: "tasks/list",
      direction: :client_to_server,
      description: "List active tasks (open, in_progress, blocked) for a session's project.",
      params: [
        %{name: "session_id", type: :string, required: true,
          description: "Target session ID."}
      ],
      result: [
        %{name: "tasks", type: {:array, :object}, description: "Array of task objects."}
      ]
    }
  ]

  @server_requests [
    %{
      method: "client/confirm",
      direction: :server_to_client,
      description: "Ask the user for confirmation (e.g., before executing a tool).",
      params: [
        %{name: "session_id", type: :string, required: true,
          description: "Session this confirmation belongs to."},
        %{name: "title", type: :string, required: true,
          description: "Short title for the confirmation dialog."},
        %{name: "message", type: :string, required: true,
          description: "Detailed message to show."},
        %{name: "actions", type: {:array, :string}, required: true,
          description: "Available actions (e.g., [\"allow\", \"deny\", \"allow_session\"])."}
      ],
      result: [
        %{name: "action", type: :string, description: "The user's chosen action."}
      ]
    },
    %{
      method: "client/input",
      direction: :server_to_client,
      description: "Ask the user for freeform text input.",
      params: [
        %{name: "session_id", type: :string, required: true,
          description: "Session this input request belongs to."},
        %{name: "prompt", type: :string, required: true,
          description: "Prompt to display to the user."},
        %{name: "sensitive", type: :boolean, required: false,
          description: "If true, input should be masked (e.g., API keys)."}
      ],
      result: [
        %{name: "text", type: :string, description: "The user's input."}
      ]
    }
  ]

  # ---------------------------------------------------------------------------
  # Server → Client Notifications (agent/event types)
  # ---------------------------------------------------------------------------

  @event_types [
    %{type: "agent_start", description: "Agent has started processing.",
      fields: []},
    %{type: "agent_end", description: "Agent has finished processing.",
      fields: [
        %{name: "usage", type: {:object, %{"prompt_tokens" => :integer, "completion_tokens" => :integer, "total_tokens" => :integer, "context_window" => :integer, "current_context_tokens" => :integer}}, required: false,
          description: "Cumulative token usage for the session."}
      ]},
    %{type: "agent_abort", description: "Agent run was aborted.",
      fields: []},
    %{type: "message_start", description: "LLM has started generating a message.",
      fields: []},
    %{type: "message_delta", description: "A chunk of LLM-generated text.",
      fields: [
        %{name: "delta", type: :string, description: "The text fragment."}
      ]},
    %{type: "thinking_start", description: "LLM has started a thinking/reasoning block.",
      fields: []},
    %{type: "thinking_delta", description: "A chunk of LLM thinking/reasoning text.",
      fields: [
        %{name: "delta", type: :string, description: "The thinking text fragment."}
      ]},
    %{type: "tool_execution_start", description: "A tool has started executing.",
      fields: [
        %{name: "tool", type: :string, description: "Tool name."},
        %{name: "call_id", type: :string, description: "Unique call identifier."},
        %{name: "args", type: :object, description: "Tool arguments."},
        %{name: "meta", type: :string, description: "Human-readable summary of the invocation."}
      ]},
    %{type: "tool_execution_end", description: "A tool has finished executing.",
      fields: [
        %{name: "tool", type: :string, description: "Tool name."},
        %{name: "call_id", type: :string, description: "Unique call identifier."},
        %{name: "result", type: {:object, %{"ok" => :boolean}},
          description: "Tool execution result. May include optional output or error string fields."}
      ]},
    %{type: "turn_end", description: "An LLM turn has ended (may be followed by tool calls).",
      fields: [
        %{name: "message", type: :string, description: "The assistant's message text."}
      ]},
    %{type: "error", description: "An error occurred during processing.",
      fields: [
        %{name: "reason", type: :string, description: "Error description."}
      ]},
    %{type: "context_discovered", description: "Project context files were discovered during session initialization.",
      fields: [
        %{name: "files", type: {:array, :string}, description: "Paths of discovered context files."}
      ]},
    %{type: "skill_loaded", description: "An agent skill was dynamically loaded into context.",
      fields: [
        %{name: "name", type: :string, description: "Skill name."},
        %{name: "description", type: :string, description: "Skill description."}
      ]},
    %{type: "sub_agent_event", description: "An event forwarded from a spawned sub-agent.",
      fields: [
        %{name: "parent_call_id", type: :string, description: "The call_id of the parent sub_agent tool invocation."},
        %{name: "sub_session_id", type: :string, description: "The sub-agent's session ID."},
        %{name: "inner", type: :object, description: "The wrapped agent event from the sub-agent (contains a type field and event-specific data)."}
      ]},
    %{type: "usage_update", description: "Live token usage update during a turn.",
      fields: [
        %{name: "usage", type: {:object, %{"prompt_tokens" => :integer, "completion_tokens" => :integer, "total_tokens" => :integer, "context_window" => :integer, "current_context_tokens" => :integer}},
          description: "Current token usage snapshot."}
      ]}
  ]

  # ---------------------------------------------------------------------------
  # Notification wrapper (the notification method name for all events)
  # ---------------------------------------------------------------------------

  @notification_method "agent/event"

  @doc "The JSON-RPC method name used for all streaming event notifications."
  @spec notification_method() :: String.t()
  def notification_method, do: @notification_method

  # ---------------------------------------------------------------------------
  # Public Query API
  # ---------------------------------------------------------------------------

  @doc "Returns all client→server method definitions."
  @spec methods() :: [method_def()]
  def methods, do: @methods

  @doc "Returns all client→server method name strings."
  @spec method_names() :: [String.t()]
  def method_names, do: Enum.map(@methods, & &1.method)

  @doc "Returns the definition for a specific method, or nil."
  @spec method(String.t()) :: method_def() | nil
  def method(name), do: Enum.find(@methods, &(&1.method == name))

  @doc "Returns all server→client request definitions."
  @spec server_requests() :: [server_request_def()]
  def server_requests, do: @server_requests

  @doc "Returns all server→client request method name strings."
  @spec server_request_names() :: [String.t()]
  def server_request_names, do: Enum.map(@server_requests, & &1.method)

  @doc "Returns the definition for a specific server request, or nil."
  @spec server_request(String.t()) :: server_request_def() | nil
  def server_request(name), do: Enum.find(@server_requests, &(&1.method == name))

  @doc "Returns all event type definitions."
  @spec event_types() :: [event_type_def()]
  def event_types, do: @event_types

  @doc "Returns all event type name strings."
  @spec event_type_names() :: [String.t()]
  def event_type_names, do: Enum.map(@event_types, & &1.type)

  @doc "Returns the definition for a specific event type, or nil."
  @spec event_type(String.t()) :: event_type_def() | nil
  def event_type(name), do: Enum.find(@event_types, &(&1.type == name))

  @doc """
  Returns the complete protocol specification as a single map.

  Useful for serialization, export, or code generation.

  ## Structure

      %{
        version: "0.1.0",
        transport: "stdio",
        framing: "newline-delimited JSON",
        methods: [...],
        server_requests: [...],
        event_types: [...],
        notification_method: "agent/event"
      }
  """
  @spec spec() :: map()
  def spec do
    %{
      version: "0.1.0",
      transport: "stdio",
      framing: "newline-delimited JSON",
      methods: @methods,
      server_requests: @server_requests,
      event_types: @event_types,
      notification_method: @notification_method
    }
  end

  @doc """
  Serializes a type descriptor to a JSON-friendly format.

  ## Examples

      iex> Opal.RPC.Protocol.serialize_type(:string)
      "string"

      iex> Opal.RPC.Protocol.serialize_type({:array, :string})
      %{kind: "array", item: "string"}

      iex> Opal.RPC.Protocol.serialize_type({:object, %{"provider" => :string, "id" => :string}})
      %{kind: "object", fields: %{"provider" => "string", "id" => "string"}}
  """
  @spec serialize_type(type_desc()) :: String.t() | map()
  def serialize_type(:string), do: "string"
  def serialize_type(:boolean), do: "boolean"
  def serialize_type(:integer), do: "integer"
  def serialize_type(:object), do: "object"
  def serialize_type({:array, inner}), do: %{kind: "array", item: serialize_type(inner)}
  def serialize_type({:object, fields}) when is_map(fields) do
    %{kind: "object", fields: Map.new(fields, fn {k, v} -> {k, serialize_type(v)} end)}
  end

  @doc """
  Returns the spec with all types serialized to JSON-friendly format.
  """
  @spec spec_json() :: map()
  def spec_json do
    spec = spec()
    %{spec |
      methods: Enum.map(spec.methods, &serialize_def/1),
      server_requests: Enum.map(spec.server_requests, &serialize_def/1),
      event_types: Enum.map(spec.event_types, &serialize_event_type/1)
    }
  end

  @doc """
  Returns true if the given method name is a known client→server method.
  """
  @spec known_method?(String.t()) :: boolean()
  def known_method?(name), do: name in method_names()

  @doc """
  Returns the required param names for a given method.
  """
  @spec required_params(String.t()) :: [String.t()]
  def required_params(name) do
    case method(name) do
      nil -> []
      m -> m.params |> Enum.filter(& &1.required) |> Enum.map(& &1.name)
    end
  end

  @doc """
  Returns true if the given event type is a known event.
  """
  @spec known_event_type?(String.t()) :: boolean()
  def known_event_type?(name), do: name in event_type_names()

  # -- Private Helpers --

  defp serialize_def(def_map) do
    def_map
    |> Map.update!(:params, fn params ->
      Enum.map(params, fn p -> Map.update!(p, :type, &serialize_type/1) end)
    end)
    |> Map.update!(:result, fn fields ->
      Enum.map(fields, fn f -> Map.update!(f, :type, &serialize_type/1) end)
    end)
  end

  defp serialize_event_type(et) do
    Map.update!(et, :fields, fn fields ->
      Enum.map(fields, fn f -> Map.update!(f, :type, &serialize_type/1) end)
    end)
  end
end
