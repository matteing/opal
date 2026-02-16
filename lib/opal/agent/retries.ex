defmodule Opal.Agent.Retries do
  @moduledoc """
  Retry policy facade for transient provider errors.
  """

  alias Opal.Agent.Retry

  @spec retryable?(term()) :: boolean()
  defdelegate retryable?(reason), to: Retry

  @spec delay(pos_integer(), keyword()) :: pos_integer()
  defdelegate delay(attempt, opts \\ []), to: Retry
end
