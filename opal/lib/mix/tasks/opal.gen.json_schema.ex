defmodule Mix.Tasks.Opal.Gen.JsonSchema do
  @moduledoc """
  Generates a JSON Schema file from the Opal RPC protocol specification.

  The output is written to `priv/rpc_schema.json` by default, or to the
  path given as the first argument.

  ## Usage

      mix opal.gen.json_schema
      mix opal.gen.json_schema ../sdk/src/rpc_schema.json
  """
  use Mix.Task

  @shortdoc "Generate JSON Schema from Opal.RPC.Protocol"

  @impl true
  def run(args) do
    output_path = List.first(args) || "priv/rpc_schema.json"

    spec = Opal.RPC.Protocol.spec()

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Opal RPC Protocol",
      "description" => "Auto-generated from Opal.RPC.Protocol",
      "version" => spec.version,
      "definitions" => %{
        "methods" => build_methods(spec.methods),
        "server_requests" => build_methods(spec.server_requests),
        "events" => build_events(spec.event_types),
        "notification_method" => spec.notification_method
      }
    }

    output_path |> Path.dirname() |> File.mkdir_p!()
    json = Jason.encode!(schema, pretty: true)
    File.write!(output_path, json <> "\n")

    Mix.shell().info("Generated JSON Schema → #{output_path}")
  end

  # -- Methods / Server Requests --

  defp build_methods(methods) do
    Map.new(methods, fn m ->
      params_schema = params_to_json_schema(m.params)
      result_schema = fields_to_json_schema(m.result)

      {m.method,
       %{
         "description" => m.description,
         "params" => params_schema,
         "result" => result_schema
       }}
    end)
  end

  defp params_to_json_schema(params) do
    properties = Map.new(params, fn p -> {p.name, type_to_json_schema(p.type, p.description)} end)
    required = params |> Enum.filter(& &1.required) |> Enum.map(& &1.name)

    schema = %{"type" => "object", "properties" => properties}
    if required == [], do: schema, else: Map.put(schema, "required", required)
  end

  defp fields_to_json_schema(fields) do
    properties = Map.new(fields, fn f -> {f.name, type_to_json_schema(f.type, f.description)} end)
    required = Enum.map(fields, & &1.name)

    schema = %{"type" => "object", "properties" => properties}
    if required == [], do: schema, else: Map.put(schema, "required", required)
  end

  # -- Events --

  defp build_events(event_types) do
    Map.new(event_types, fn e ->
      properties =
        Map.new(e.fields, fn f ->
          {f.name, type_to_json_schema(f.type, f.description)}
        end)

      required =
        e.fields
        |> Enum.reject(fn f -> Map.get(f, :required) == false end)
        |> Enum.map(& &1.name)

      base = %{
        "type" => "object",
        "properties" =>
          Map.merge(
            %{
              "type" => %{
                "type" => "string",
                "const" => e.type,
                "description" => "Event type discriminator."
              },
              "session_id" => %{
                "type" => "string",
                "description" => "Session this event belongs to."
              }
            },
            properties
          ),
        "required" => ["type", "session_id"] ++ required,
        "description" => e.description
      }

      {e.type, base}
    end)
  end

  # -- Type → JSON Schema --

  @doc false
  def type_to_json_schema(type, description \\ "") do
    schema = parse_type(type)
    if description != "", do: Map.put(schema, "description", description), else: schema
  end

  # Atom types (used by Opal.RPC.Protocol)
  defp parse_type(:string), do: %{"type" => "string"}
  defp parse_type(:boolean), do: %{"type" => "boolean"}
  defp parse_type(:integer), do: %{"type" => "integer"}
  defp parse_type(:number), do: %{"type" => "number"}
  defp parse_type(:object), do: %{"type" => "object"}

  defp parse_type({:nullable, inner}) do
    Map.put(parse_type(inner), "nullable", true)
  end

  defp parse_type({:array, inner}),
    do: %{"type" => "array", "items" => parse_type(inner)}

  defp parse_type({:object, fields, required_set}) when is_map(fields) do
    properties = Map.new(fields, fn {name, type} -> {name, parse_type(type)} end)

    required =
      fields |> Map.keys() |> Enum.filter(&MapSet.member?(required_set, &1)) |> Enum.sort()

    schema = %{"type" => "object", "properties" => properties}
    if required == [], do: schema, else: Map.put(schema, "required", required)
  end

  defp parse_type({:object, fields}) when is_map(fields) do
    properties = Map.new(fields, fn {name, type} -> {name, parse_type(type)} end)
    required = Map.keys(fields) |> Enum.sort()
    schema = %{"type" => "object", "properties" => properties}
    if required == [], do: schema, else: Map.put(schema, "required", required)
  end

  # String types (legacy/fallback)
  defp parse_type("string"), do: %{"type" => "string"}
  defp parse_type("boolean"), do: %{"type" => "boolean"}
  defp parse_type("integer"), do: %{"type" => "integer"}
  defp parse_type("number"), do: %{"type" => "number"}
  defp parse_type("object"), do: %{"type" => "object"}

  defp parse_type("string[]"), do: %{"type" => "array", "items" => %{"type" => "string"}}
  defp parse_type("object[]"), do: %{"type" => "array", "items" => %{"type" => "object"}}

  defp parse_type("object{" <> rest) do
    fields_str = String.trim_trailing(rest, "}")

    pairs =
      fields_str
      |> String.split(",")
      |> Enum.map(fn pair ->
        [name, type] = pair |> String.trim() |> String.split(":", parts: 2)
        name = String.trim(name)
        type = String.trim(type)

        {optional?, clean_name} =
          if String.ends_with?(name, "?") do
            {true, String.trim_trailing(name, "?")}
          else
            {false, name}
          end

        {clean_name, parse_type(type), optional?}
      end)

    properties = Map.new(pairs, fn {name, schema, _} -> {name, schema} end)

    required =
      pairs |> Enum.reject(fn {_, _, opt?} -> opt? end) |> Enum.map(fn {name, _, _} -> name end)

    schema = %{"type" => "object", "properties" => properties}
    if required == [], do: schema, else: Map.put(schema, "required", required)
  end

  # Fallback for types we can't parse
  defp parse_type(other),
    do: %{"type" => "object", "description" => "Complex type: #{inspect(other)}"}
end
