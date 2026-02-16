defmodule Opal.Config.Copilot do
  @moduledoc """
  Copilot-specific configuration: OAuth client ID and GitHub domain.

  ## Fields

    * `:client_id` — OAuth App client ID for the Copilot device-code flow.
      Default: `"Iv1.b507a08c87ecfe98"` (the VS Code Copilot Chat extension's ID).

    * `:domain` — GitHub domain for authentication endpoints.
      Default: `"github.com"`. Change for GitHub Enterprise Server instances.
  """

  @type t :: %__MODULE__{
          client_id: String.t(),
          domain: String.t()
        }

  # NOTE: This is the GitHub Copilot Chat VS Code extension's OAuth App
  # client ID, borrowed from Pi's source. It works because Copilot's
  # device-code flow doesn't enforce redirect URIs. Replace with Opal's
  # own registered OAuth App client ID when one exists.
  defstruct client_id: "Iv1.b507a08c87ecfe98",
            domain: "github.com"

  @doc "Builds from a keyword list or map."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: struct(__MODULE__, attrs)
  def new(attrs) when is_map(attrs), do: struct(__MODULE__, Map.to_list(attrs))
end
