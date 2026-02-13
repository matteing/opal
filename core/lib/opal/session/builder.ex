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

    [
      session_id: generate_session_id(),
      system_prompt: Map.get(config, :system_prompt, ""),
      model: model,
      tools: Map.get(config, :tools) || cfg.default_tools,
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
          saved when is_binary(saved) and saved != "" -> Opal.Model.coerce(saved, model_opts)
          _ -> Opal.Model.coerce(cfg.default_model, model_opts)
        end

      spec ->
        Opal.Model.coerce(spec, model_opts)
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
          Opal.Model.provider_module(model)
        end
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
