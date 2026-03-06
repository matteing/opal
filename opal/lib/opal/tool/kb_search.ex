defmodule Opal.Tool.KbSearch do
  @moduledoc """
  Search the session knowledge base for previously indexed tool outputs.

  When Smoosh indexes large tool outputs into the per-session FTS5 store,
  this tool lets the agent search that indexed content later. Supports
  stemming (Porter), substring (trigram), and source filtering.

  Only included in the active tool set when the knowledge base has content.
  """

  @behaviour Opal.Tool

  alias Opal.Agent.Smoosh.KnowledgeBase

  @impl true
  def name, do: "kb_search"

  @impl true
  def description,
    do: "Search the session knowledge base for previously indexed tool outputs."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" =>
            "Search query. Supports stemming (running→run), substrings, and multi-word queries."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Max results to return (default: 5)."
        },
        "source" => %{
          "type" => "string",
          "description" =>
            "Filter results to a specific source label (substring match, e.g. 'shell' or 'grep')."
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def meta(%{"query" => q}), do: "KB search: #{Opal.Util.Text.truncate(q, 40, "…")}"
  def meta(_), do: "KB search"

  @impl true
  def smoosh, do: :skip

  @impl true
  def execute(%{"query" => query} = args, %{agent_state: state}) do
    limit = Map.get(args, "limit", 5)
    source = Map.get(args, "source")
    opts = [limit: limit] ++ if(source, do: [source: source], else: [])

    case KnowledgeBase.lookup(state.session_id) do
      {:ok, pid} ->
        case KnowledgeBase.search(pid, query, opts) do
          {:ok, []} ->
            {:ok, "No results found for query: #{query}"}

          {:ok, results} ->
            {:ok, format_results(results, query)}
        end

      :not_started ->
        {:ok, "Knowledge base is empty — no tool outputs have been indexed yet."}
    end
  end

  def execute(%{"query" => _query}, _context) do
    {:error, "Missing agent_state in context"}
  end

  def execute(_args, _context) do
    {:error, "Missing required parameter: query"}
  end

  # ── Formatting ──

  defp format_results(results, query) do
    header = "Found #{length(results)} result(s) for \"#{query}\":\n"

    body =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {r, i} ->
        type_tag = if r.content_type == :code, do: " [code]", else: ""

        """
        ---
        ### Result #{i}#{type_tag}
        **Source:** #{r.source}
        **Section:** #{r.title}
        **Relevance:** #{Float.round(abs(r.rank), 4)}

        #{r.content}
        """
      end)

    header <> body
  end
end
