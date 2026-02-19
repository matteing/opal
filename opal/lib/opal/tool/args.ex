defmodule Opal.Tool.Args do
  @moduledoc false

  @spec validate(map(), keyword(), keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def validate(args, schema, opts \\ []) when is_map(args) and is_list(schema) do
    with :ok <- ensure_required(args, schema, opts),
         {:ok, validated} <- NimbleOptions.validate(extract_known(args, schema), schema) do
      {:ok, validated}
    else
      {:error, %NimbleOptions.ValidationError{} = error} ->
        {:error, Exception.message(error)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_required(args, schema, opts) do
    missing =
      schema
      |> Enum.flat_map(fn {key, spec} ->
        if Keyword.get(spec, :required, false) and not Map.has_key?(args, Atom.to_string(key)) do
          [key]
        else
          []
        end
      end)

    case missing do
      [] ->
        :ok

      keys ->
        {:error, required_message(keys, opts)}
    end
  end

  defp required_message(keys, opts) do
    case Keyword.get(opts, :required_message) do
      message when is_binary(message) ->
        message

      _ ->
        do_required_message(keys)
    end
  end

  defp do_required_message([key]), do: "Missing required parameter: #{key}"

  defp do_required_message(keys) do
    names = Enum.map_join(keys, ", ", &to_string/1)
    "Missing required parameters: #{names}"
  end

  defp extract_known(args, schema) do
    Enum.reduce(schema, [], fn {key, _spec}, acc ->
      string_key = Atom.to_string(key)

      if Map.has_key?(args, string_key) do
        [{key, Map.fetch!(args, string_key)} | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end
end
