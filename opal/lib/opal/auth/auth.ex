defmodule Opal.Auth do
  @moduledoc """
  Copilot credential detection.

  Checks whether a valid Copilot token exists and returns a summary
  the client can use to decide whether the device-code login flow
  is needed.
  """

  @type probe_result :: %{
          status: String.t(),
          provider: String.t() | nil
        }

  @doc """
  Probes Copilot credentials and returns auth readiness.

  Returns a map with:

    * `status` — `"ready"` if a valid Copilot token exists,
      `"setup_required"` if not.
    * `provider` — `"copilot"` when ready, `nil` otherwise.
  """
  @spec probe() :: probe_result()
  def probe do
    case Opal.Auth.Copilot.get_token() do
      {:ok, _} -> %{status: "ready", provider: "copilot"}
      _ -> %{status: "setup_required", provider: nil}
    end
  end

  @doc """
  Checks whether Copilot credentials are available.
  """
  @spec ready?() :: boolean()
  def ready? do
    probe().status == "ready"
  end
end
