# Patches dependencies for OTP 28 / Elixir 1.18+ compatibility.
#
# Elixir 1.18+ cannot escape compiled Regex references stored in module
# attributes when injecting them into function bodies. This script rewrites
# affected files in deps/ so they compile on modern toolchains.
#
# Run automatically via: mix setup
# Run manually via:      mix run --no-compile --no-start scripts/patch_deps.exs

defmodule DepsPatches do
  @patches [
    {"deps/term_ui/lib/term_ui/widgets/log_viewer.ex",
     [
       {"@level_patterns [", "defp level_patterns do\n    ["},
       {"    {:debug, ~r/\\b(DEBUG|DBG)\\b/i}\n  ]",
        "      {:debug, ~r/\\b(DEBUG|DBG)\\b/i}\n    ]\n  end"},
       {"@timestamp_pattern ~r", "defp timestamp_pattern, do: ~r"},
       {"@source_pattern ~r", "defp source_pattern, do: ~r"},
       {"Regex.run(@timestamp_pattern,", "Regex.run(timestamp_pattern(),"},
       {"Enum.find_value(@level_patterns,", "Enum.find_value(level_patterns(),"},
       {"Regex.run(@source_pattern,", "Regex.run(source_pattern(),"}
     ]},
    {"deps/term_ui/lib/term_ui/widgets/process_monitor.ex",
     [
       {"@system_patterns [", "defp system_patterns do\n    ["},
       {"    ~r/^:erl_prim_loader$/\n  ]",
        "      ~r/^:erl_prim_loader$/\n    ]\n  end"},
       {"Enum.any?(@system_patterns,", "Enum.any?(system_patterns(),"}
     ]}
  ]

  def run do
    patched =
      Enum.count(@patches, fn {file, replacements} ->
        patch_file(file, replacements)
      end)

    if patched > 0 do
      Mix.shell().info("Patched #{patched} file(s) for OTP 28 compatibility.")
    else
      Mix.shell().info("No patches needed — deps already patched or not present.")
    end
  end

  defp patch_file(file, replacements) do
    if File.exists?(file) do
      original = File.read!(file)

      content =
        Enum.reduce(replacements, original, fn {from, to}, acc ->
          String.replace(acc, from, to, global: false)
        end)

      if content != original do
        File.write!(file, content)
        Mix.shell().info("  ✓ #{file}")
        true
      else
        false
      end
    else
      false
    end
  end
end

DepsPatches.run()
