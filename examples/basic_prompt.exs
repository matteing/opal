# examples/basic_prompt.exs
#
# Start a session, send a prompt, and print the response synchronously.
#
# Usage:
#   mix run examples/basic_prompt.exs
#

{:ok, agent} =
  Opal.start_session(%{
    system_prompt: "You are a helpful assistant. Keep answers short.",
    working_dir: File.cwd!()
  })

{:ok, response} = Opal.prompt_sync(agent, "What is the Fibonacci sequence?")
IO.puts(response)

Opal.stop_session(agent)
