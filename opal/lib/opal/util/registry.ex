defmodule Opal.Util.Registry do
  @moduledoc "Helpers for looking up processes in `Opal.Registry`."

  @doc """
  Looks up a process by registry key.

  Returns `{:ok, pid}` if found, `{:error, message}` otherwise.

      lookup({:agent, "abc123"})
      #=> {:ok, #PID<0.123.0>}
  """
  @spec lookup(term()) :: {:ok, pid()} | {:error, String.t()}
  def lookup(key) do
    case Registry.lookup(Opal.Registry, key) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, "No process registered for #{inspect(key)}"}
    end
  end
end
