defmodule Opal.Tool.UseSkill do
  @moduledoc """
  Loads an agent skill's full instructions into the active context.

  Skills use progressive disclosure: only name/description are visible
  initially. This tool loads the full instructions when the agent decides
  a skill is relevant to the current task.
  """

  @behaviour Opal.Tool

  alias Opal.Tool.Args, as: ToolArgs

  @args_schema [
    skill_name: [type: :string, required: true]
  ]

  @impl true
  def name, do: "use_skill"

  @impl true
  def description do
    """
    Load a skill's full instructions into your context. Use this when you
    encounter a task that matches an available skill's description. The
    skill's detailed instructions will be added to your working context.
    """
  end

  @impl true
  def meta(%{"skill_name" => name}), do: "Loading skill: #{name}"
  def meta(_), do: "Loading skill"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "skill_name" => %{
          "type" => "string",
          "description" => "Name of the skill to load (from available skills list)."
        }
      },
      "required" => ["skill_name"]
    }
  end

  @impl true
  def execute(args, _context) when is_map(args) do
    with {:ok, opts} <-
           ToolArgs.validate(args, @args_schema,
             required_message: "Missing required parameter: skill_name"
           ) do
      {:effect, {:load_skill, opts[:skill_name]}}
    end
  end

  def execute(_, _), do: {:error, "Missing required parameter: skill_name"}
end
