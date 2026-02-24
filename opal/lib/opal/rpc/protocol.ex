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
    * **Single source of truth** — `Opal.RPC.Server`
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
        %{
          name: "model",
          type:
            {:object, %{"provider" => :string, "id" => :string, "thinking_level" => :string},
             MapSet.new(["provider", "id"])},
          required: false,
          description: "Model to use. Defaults to config default."
        },
        %{
          name: "system_prompt",
          type: :string,
          required: false,
          description: "System prompt for the agent."
        },
        %{
          name: "working_dir",
          type: :string,
          required: false,
          description: "Working directory. Defaults to server cwd."
        },
        %{
          name: "mcp_servers",
          type: {:array, :object},
          required: false,
          description: "MCP server configurations."
        },
        %{
          name: "features",
          type:
            {:object,
             %{
               "sub_agents" => :boolean,
               "skills" => :boolean,
               "mcp" => :boolean,
               "debug" => :boolean
             }},
          required: false,
          description: "Boot-time feature toggles."
        },
        %{
          name: "session",
          type: :boolean,
          required: false,
          description: "If true, enable session persistence."
        },
        %{
          name: "session_id",
          type: :string,
          required: false,
          description:
            "Resume an existing session by ID. Implies session=true. The session is loaded from disk."
        }
      ],
      result: [
        %{name: "session_id", type: :string, description: "The new session's unique ID."},
        %{
          name: "session_dir",
          type: :string,
          description: "Filesystem path to the session's data directory."
        },
        %{
          name: "context_files",
          type: {:array, :string},
          description: "Paths of loaded context files."
        },
        %{
          name: "available_skills",
          type: {:array, :string},
          description: "Names of discovered skills (not yet loaded)."
        },
        %{
          name: "mcp_servers",
          type: {:array, :string},
          description: "Names of connected MCP servers."
        },
        %{
          name: "node_name",
          type: :string,
          description: "Erlang node name of the server (for debugging)."
        },
        %{
          name: "auth",
          type:
            {:object,
             %{
               "status" => :string,
               "provider" => :string
             }},
          description:
            "Auth probe result: status is 'ready' or 'setup_required', provider is 'copilot' or null."
        }
      ]
    },
    %{
      method: "agent/prompt",
      direction: :client_to_server,
      description:
        "Send a user prompt. If idle the agent starts immediately; if busy the message is queued for injection between tool calls.",
      params: [
        %{name: "session_id", type: :string, required: true, description: "Target session ID."},
        %{name: "text", type: :string, required: true, description: "The user's prompt text."}
      ],
      result: [
        %{
          name: "queued",
          type: :boolean,
          description: "True when the agent was busy and the message was queued."
        }
      ]
    },
    %{
      method: "agent/abort",
      direction: :client_to_server,
      description: "Abort the current agent run.",
      params: [
        %{name: "session_id", type: :string, required: true, description: "Target session ID."}
      ],
      result: []
    },
    %{
      method: "agent/state",
      direction: :client_to_server,
      description: "Get the current agent state.",
      params: [
        %{name: "session_id", type: :string, required: true, description: "Target session ID."}
      ],
      result: [
        %{name: "session_id", type: :string, description: "Session ID."},
        %{name: "status", type: :string, description: "One of: idle, running, streaming."},
        %{
          name: "model",
          type: {:object, %{"provider" => :string, "id" => :string, "thinking_level" => :string}},
          description: "Current model."
        },
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
        %{
          name: "sessions",
          type: {:array, :object},
          description: "Array of {id, title, modified}."
        }
      ]
    },
    %{
      method: "session/branch",
      direction: :client_to_server,
      description: "Branch the conversation at a specific message.",
      params: [
        %{name: "session_id", type: :string, required: true, description: "Target session ID."},
        %{
          name: "entry_id",
          type: :string,
          required: true,
          description: "Message ID to branch from."
        }
      ],
      result: []
    },
    %{
      method: "session/compact",
      direction: :client_to_server,
      description: "Compact older messages in the session. (Not yet implemented.)",
      params: [
        %{name: "session_id", type: :string, required: true, description: "Target session ID."},
        %{
          name: "keep_recent",
          type: :integer,
          required: false,
          description: "Number of recent messages to keep. Default: 10."
        }
      ],
      result: []
    },
    %{
      method: "models/list",
      direction: :client_to_server,
      description: "List available LLM models from Copilot.",
      params: [],
      result: [
        %{
          name: "models",
          type: {:array, :object},
          description: "Array of {id, name, provider, supports_thinking}."
        }
      ]
    },
    %{
      method: "model/set",
      direction: :client_to_server,
      description: "Change the model for a running session.",
      params: [
        %{name: "session_id", type: :string, required: true, description: "Target session ID."},
        %{name: "model_id", type: :string, required: true, description: "Model ID to switch to."},
        %{
          name: "thinking_level",
          type: :string,
          required: false,
          description: "Reasoning effort: off, low, medium, high."
        }
      ],
      result: [
        %{
          name: "model",
          type: {:object, %{"provider" => :string, "id" => :string, "thinking_level" => :string}},
          description: "The new active model."
        }
      ]
    },
    %{
      method: "thinking/set",
      direction: :client_to_server,
      description: "Change the reasoning effort level for the current model.",
      params: [
        %{name: "session_id", type: :string, required: true, description: "Target session ID."},
        %{
          name: "level",
          type: :string,
          required: true,
          description: "Reasoning effort: off, low, medium, high."
        }
      ],
      result: [
        %{name: "thinking_level", type: :string, description: "The new thinking level."}
      ]
    },
    %{
      method: "auth/status",
      direction: :client_to_server,
      description: "Probe Copilot credentials and return auth readiness.",
      params: [],
      result: [
        %{
          name: "authenticated",
          type: :boolean,
          description: "True if Copilot credentials are available."
        },
        %{
          name: "auth",
          type:
            {:object,
             %{
               "status" => :string,
               "provider" => :string
             }},
          description:
            "Probe result: status is 'ready' or 'setup_required', provider is 'copilot' or null."
        }
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
      method: "auth/poll",
      direction: :client_to_server,
      description: "Poll for device-code authorization and exchange for a Copilot token.",
      params: [
        %{
          name: "device_code",
          type: :string,
          required: true,
          description: "Device code from auth/login."
        },
        %{
          name: "interval",
          type: :integer,
          required: true,
          description: "Polling interval in seconds."
        }
      ],
      result: [
        %{
          name: "authenticated",
          type: :boolean,
          description: "True once the user has authorized."
        }
      ]
    },
    %{
      method: "tasks/list",
      direction: :client_to_server,
      description: "List active tasks (open, in_progress, blocked) for a session's project.",
      params: [
        %{name: "session_id", type: :string, required: true, description: "Target session ID."}
      ],
      result: [
        %{name: "tasks", type: {:array, :object}, description: "Array of task objects."}
      ]
    },
    %{
      method: "settings/get",
      direction: :client_to_server,
      description: "Get all persistent user settings.",
      params: [],
      result: [
        %{name: "settings", type: :object, description: "Map of setting key-value pairs."}
      ]
    },
    %{
      method: "settings/save",
      direction: :client_to_server,
      description: "Save user settings (merged with existing).",
      params: [
        %{
          name: "settings",
          type: :object,
          required: true,
          description: "Map of setting key-value pairs to save."
        }
      ],
      result: [
        %{name: "settings", type: :object, description: "The full settings after merge."}
      ]
    },
    %{
      method: "opal/config/get",
      direction: :client_to_server,
      description: "Get runtime feature and tool configuration for a session.",
      params: [
        %{name: "session_id", type: :string, required: true, description: "Target session ID."}
      ],
      result: [
        %{
          name: "features",
          type:
            {:object,
             %{
               "sub_agents" => :boolean,
               "skills" => :boolean,
               "mcp" => :boolean,
               "debug" => :boolean
             }},
          description: "Current runtime feature flags."
        },
        %{
          name: "tools",
          type:
            {:object,
             %{
               "all" => {:array, :string},
               "enabled" => {:array, :string},
               "disabled" => {:array, :string}
             }},
          description: "Tool availability for the session."
        },
        %{
          name: "distribution",
          type:
            {:nullable,
             {:object,
              %{
                "node" => :string,
                "cookie" => :string
              }}},
          description:
            "Erlang distribution info if active (node name and cookie), or null if not distributed."
        }
      ]
    },
    %{
      method: "opal/config/set",
      direction: :client_to_server,
      description: "Update runtime feature and tool configuration for a session.",
      params: [
        %{name: "session_id", type: :string, required: true, description: "Target session ID."},
        %{
          name: "features",
          type:
            {:object,
             %{
               "sub_agents" => :boolean,
               "skills" => :boolean,
               "mcp" => :boolean,
               "debug" => :boolean
             }},
          required: false,
          description: "Feature flags to update."
        },
        %{
          name: "tools",
          type: {:array, :string},
          required: false,
          description: "Exact list of enabled tool names."
        },
        %{
          name: "distribution",
          type:
            {:nullable,
             {:object,
              %{
                "name" => :string,
                "cookie" => :string
              }, MapSet.new(["name"])}},
          required: false,
          description:
            "Start or stop Erlang distribution. Pass {name, cookie?} to start, null to stop."
        }
      ],
      result: [
        %{
          name: "features",
          type:
            {:object,
             %{
               "sub_agents" => :boolean,
               "skills" => :boolean,
               "mcp" => :boolean,
               "debug" => :boolean
             }},
          description: "Current runtime feature flags."
        },
        %{
          name: "tools",
          type:
            {:object,
             %{
               "all" => {:array, :string},
               "enabled" => {:array, :string},
               "disabled" => {:array, :string}
             }},
          description: "Tool availability for the session."
        },
        %{
          name: "distribution",
          type:
            {:nullable,
             {:object,
              %{
                "node" => :string,
                "cookie" => :string
              }}},
          description:
            "Erlang distribution info if active (node name and cookie), or null if not distributed."
        }
      ]
    },
    %{
      method: "opal/ping",
      direction: :client_to_server,
      description: "Liveness check. Returns immediately.",
      params: [],
      result: []
    },
    %{
      method: "opal/version",
      direction: :client_to_server,
      description: "Return server and protocol version information.",
      params: [],
      result: [
        %{
          name: "server_version",
          type: :string,
          description: "Opal server version (e.g. 0.1.10)."
        },
        %{
          name: "protocol_version",
          type: :string,
          description: "RPC protocol version (e.g. 0.1.0)."
        }
      ]
    },
    %{
      method: "session/history",
      direction: :client_to_server,
      description:
        "Return the message history for a running session. Used to restore the UI after resuming.",
      params: [
        %{name: "session_id", type: :string, required: true, description: "Target session ID."}
      ],
      result: [
        %{
          name: "messages",
          type: {:array, :object},
          description:
            "Ordered list of messages from root to current leaf. Each message has id, role, content, thinking, tool_calls, call_id, name, is_error, and metadata."
        }
      ]
    },
    %{
      method: "session/delete",
      direction: :client_to_server,
      description: "Delete a saved session by ID.",
      params: [
        %{
          name: "session_id",
          type: :string,
          required: true,
          description: "ID of the session to delete."
        }
      ],
      result: [
        %{name: "ok", type: :boolean, description: "True if deleted successfully."}
      ]
    }
  ]

  @server_requests [
    %{
      method: "client/confirm",
      direction: :server_to_client,
      description: "Ask the user for confirmation (e.g., before executing a tool).",
      params: [
        %{
          name: "session_id",
          type: :string,
          required: true,
          description: "Session this confirmation belongs to."
        },
        %{
          name: "title",
          type: :string,
          required: true,
          description: "Short title for the confirmation dialog."
        },
        %{
          name: "message",
          type: :string,
          required: true,
          description: "Detailed message to show."
        },
        %{
          name: "actions",
          type: {:array, :string},
          required: true,
          description: "Available actions (e.g., [\"allow\", \"deny\", \"allow_session\"])."
        }
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
        %{
          name: "session_id",
          type: :string,
          required: true,
          description: "Session this input request belongs to."
        },
        %{
          name: "prompt",
          type: :string,
          required: true,
          description: "Prompt to display to the user."
        },
        %{
          name: "sensitive",
          type: :boolean,
          required: false,
          description: "If true, input should be masked (e.g., API keys)."
        }
      ],
      result: [
        %{name: "text", type: :string, description: "The user's input."}
      ]
    },
    %{
      method: "client/ask_user",
      direction: :server_to_client,
      description: "Ask the user a question with optional multiple-choice answers.",
      params: [
        %{
          name: "session_id",
          type: :string,
          required: true,
          description: "Session this question belongs to."
        },
        %{
          name: "question",
          type: :string,
          required: true,
          description: "The question to display."
        },
        %{
          name: "choices",
          type: {:array, :string},
          required: false,
          description: "Optional multiple-choice options."
        }
      ],
      result: [
        %{name: "answer", type: :string, description: "The user's response text."}
      ]
    }
  ]

  # ---------------------------------------------------------------------------
  # Server → Client Notifications (agent/event types)
  # ---------------------------------------------------------------------------

  @event_types [
    %{type: "agent_start", description: "Agent has started processing.", fields: []},
    %{
      type: "agent_end",
      description: "Agent has finished processing.",
      fields: [
        %{
          name: "usage",
          type:
            {:object,
             %{
               "prompt_tokens" => :integer,
               "completion_tokens" => :integer,
               "total_tokens" => :integer,
               "context_window" => :integer,
               "current_context_tokens" => :integer
             }},
          required: false,
          description: "Cumulative token usage for the session."
        }
      ]
    },
    %{type: "agent_abort", description: "Agent run was aborted.", fields: []},
    %{type: "message_start", description: "LLM has started generating a message.", fields: []},
    %{
      type: "message_delta",
      description: "A chunk of LLM-generated text.",
      fields: [
        %{name: "delta", type: :string, description: "The text fragment."}
      ]
    },
    %{
      type: "thinking_start",
      description: "LLM has started a thinking/reasoning block.",
      fields: []
    },
    %{
      type: "thinking_delta",
      description: "A chunk of LLM thinking/reasoning text.",
      fields: [
        %{name: "delta", type: :string, description: "The thinking text fragment."}
      ]
    },
    %{
      type: "tool_execution_start",
      description: "A tool has started executing.",
      fields: [
        %{name: "tool", type: :string, description: "Tool name."},
        %{name: "call_id", type: :string, description: "Unique call identifier."},
        %{name: "args", type: :object, description: "Tool arguments."},
        %{name: "meta", type: :string, description: "Human-readable summary of the invocation."}
      ]
    },
    %{
      type: "tool_execution_end",
      description: "A tool has finished executing.",
      fields: [
        %{name: "tool", type: :string, description: "Tool name."},
        %{name: "call_id", type: :string, description: "Unique call identifier."},
        %{
          name: "result",
          type: :object,
          description:
            "Tool execution result object. Includes ok plus tool-specific payload fields. May optionally include a meta field with tool-specific structured data (e.g., diffs)."
        }
      ]
    },
    %{
      type: "tool_output",
      description: "Streaming output chunk from a running tool.",
      fields: [
        %{name: "tool", type: :string, description: "Tool name."},
        %{name: "call_id", type: :string, description: "Unique call identifier."},
        %{name: "chunk", type: :string, description: "Output chunk."}
      ]
    },
    %{
      type: "turn_end",
      description: "An LLM turn has ended (may be followed by tool calls).",
      fields: [
        %{name: "message", type: :string, description: "The assistant's message text."}
      ]
    },
    %{
      type: "error",
      description: "An error occurred during processing.",
      fields: [
        %{name: "reason", type: :string, description: "Error description."}
      ]
    },
    %{
      type: "context_discovered",
      description: "Project context files were discovered during session initialization.",
      fields: [
        %{
          name: "files",
          type: {:array, :string},
          description: "Paths of discovered context files."
        }
      ]
    },
    %{
      type: "skill_loaded",
      description: "An agent skill was dynamically loaded into context.",
      fields: [
        %{name: "name", type: :string, description: "Skill name."},
        %{name: "description", type: :string, description: "Skill description."}
      ]
    },
    %{
      type: "sub_agent_event",
      description: "An event forwarded from a spawned sub-agent.",
      fields: [
        %{
          name: "parent_call_id",
          type: :string,
          description: "The call_id of the parent sub_agent tool invocation."
        },
        %{name: "sub_session_id", type: :string, description: "The sub-agent's session ID."},
        %{
          name: "inner",
          type: :object,
          description:
            "The wrapped agent event from the sub-agent (contains a type field and event-specific data)."
        }
      ]
    },
    %{
      type: "usage_update",
      description: "Live token usage update during a turn.",
      fields: [
        %{
          name: "usage",
          type:
            {:object,
             %{
               "prompt_tokens" => :integer,
               "completion_tokens" => :integer,
               "total_tokens" => :integer,
               "context_window" => :integer,
               "current_context_tokens" => :integer
             }},
          description: "Current token usage snapshot."
        }
      ]
    },
    %{
      type: "message_queued",
      description:
        "A message was queued because the agent was busy. Emitted immediately on receipt.",
      fields: [
        %{name: "text", type: :string, description: "The queued message text."}
      ]
    },
    %{
      type: "message_applied",
      description:
        "A previously queued message has been applied and injected into the conversation.",
      fields: [
        %{name: "text", type: :string, description: "The message text."}
      ]
    },
    %{
      type: "status_update",
      description: "Short status message describing what the agent is currently working on.",
      fields: [
        %{name: "message", type: :string, description: "Brief human-readable status."}
      ]
    },
    %{
      type: "agent_recovered",
      description:
        "Agent process crashed and was restarted by the supervisor. Conversation history was reloaded from the surviving session.",
      fields: []
    }
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @notification_method "agent/event"

  @doc "The JSON-RPC method name used for all streaming event notifications."
  @spec notification_method() :: String.t()
  def notification_method, do: @notification_method

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

  @doc "Returns all event type definitions."
  @spec event_types() :: [event_type_def()]
  def event_types, do: @event_types

  @doc "Returns all event type name strings."
  @spec event_type_names() :: [String.t()]
  def event_type_names, do: Enum.map(@event_types, & &1.type)

  @doc """
  Returns the complete protocol specification as a single map.

  Used by `mix opal.gen.json_schema` and the codegen pipeline.
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
end
