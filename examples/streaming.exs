# examples/streaming.exs
#
# Use Opal.stream/2 to lazily consume agent events as they arrive.
#
# Usage:
#   mix run examples/streaming.exs
#

{:ok, agent} =
  Opal.start_session(%{
    system_prompt: "You are a helpful assistant.",
    working_dir: File.cwd!()
  })

Opal.stream(agent, "Explain pattern matching in Elixir in 3 sentences.")
|> Enum.each(fn
  {:message_delta, %{delta: text}} ->
    IO.write(text)

  {:agent_end, _} ->
    IO.puts("\n--- Done ---")

  {:agent_end, _, _} ->
    IO.puts("\n--- Done ---")

  _other ->
    :ok
end)

Opal.stop_session(agent)
