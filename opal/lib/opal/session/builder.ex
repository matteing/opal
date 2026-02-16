defmodule Opal.Session.Builder do
  @moduledoc "Resolves model, provider, and config for new sessions."

  @doc """
  Builds the full opts list for `Opal.SessionServer` from user-provided options.

  Applies the priority cascade: explicit opts → saved settings → defaults.
  """
  @spec build_opts(map()) :: keyword()
  def build_opts(config) when is_map(config) do
    cfg = Opal.Config.new(config)
    model = resolve_model(config, cfg)
    provider = resolve_provider(config, cfg, model)
    tools = resolve_tools(config, cfg)
    disabled_tools = resolve_disabled_tools(config, tools)

    [
      session_id: Map.get(config, :session_id) || generate_session_id(),
      system_prompt: Map.get(config, :system_prompt, ""),
      model: model,
      tools: tools,
      disabled_tools: disabled_tools,
      working_dir: Map.get(config, :working_dir, File.cwd!()),
      config: cfg,
      provider: provider,
      session: Map.get(config, :session, false)
    ]
  end

  defp resolve_model(config, cfg) do
    model_opts = model_opts_from_config(config)

    case Map.get(config, :model) do
      nil ->
        case Opal.Settings.get("default_model") do
          saved when is_binary(saved) and saved != "" ->
            Opal.Provider.Model.coerce(saved, model_opts)

          _ ->
            Opal.Provider.Model.coerce(cfg.default_model, model_opts)
        end

      spec ->
        Opal.Provider.Model.coerce(spec, model_opts)
    end
  end

  defp model_opts_from_config(config) do
    case Map.get(config, :thinking_level) do
      nil -> []
      level -> [thinking_level: level]
    end
  end

  defp resolve_provider(config, cfg, model) do
    case Map.get(config, :provider) do
      mod when is_atom(mod) and not is_nil(mod) ->
        mod

      _ ->
        if cfg.provider != Opal.Provider.Copilot do
          cfg.provider
        else
          Opal.Provider.Model.provider_module(model)
        end
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp resolve_tools(config, cfg) do
    case Map.get(config, :tools) do
      tools when is_list(tools) -> tools
      _ -> cfg.default_tools
    end
  end

  defp resolve_disabled_tools(config, tools) do
    all_tool_names = Enum.map(tools, & &1.name())

    case Map.get(config, :tool_names) do
      names when is_list(names) ->
        enabled = MapSet.new(names)
        Enum.reject(all_tool_names, &MapSet.member?(enabled, &1))

      _ ->
        case Map.get(config, :disabled_tools) do
          names when is_list(names) -> names
          _ -> []
        end
    end
  end
end
