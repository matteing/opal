defmodule Opal.SettingsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:opal, :data_dir, tmp_dir)

    on_exit(fn ->
      Application.delete_env(:opal, :data_dir)
    end)

    :ok
  end

  describe "get_all/0" do
    test "returns empty map when no settings file exists" do
      assert Opal.Settings.get_all() == %{}
    end

    test "returns parsed settings when file exists", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "settings.json")
      File.write!(path, Jason.encode!(%{"default_model" => "anthropic:claude-sonnet-4"}))

      assert Opal.Settings.get_all() == %{"default_model" => "anthropic:claude-sonnet-4"}
    end

    test "returns empty map for invalid JSON", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "settings.json")
      File.write!(path, "not json")

      assert Opal.Settings.get_all() == %{}
    end
  end

  describe "get/2" do
    test "returns default when key not found" do
      assert Opal.Settings.get("nonexistent", "fallback") == "fallback"
    end

    test "returns value when key exists", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "settings.json")
      File.write!(path, Jason.encode!(%{"default_model" => "openai:gpt-5"}))

      assert Opal.Settings.get("default_model") == "openai:gpt-5"
    end
  end

  describe "save/1" do
    test "creates settings file when it doesn't exist" do
      assert :ok = Opal.Settings.save(%{"default_model" => "anthropic:claude-sonnet-4"})
      assert Opal.Settings.get("default_model") == "anthropic:claude-sonnet-4"
    end

    test "merges with existing settings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "settings.json")

      File.write!(
        path,
        Jason.encode!(%{"default_model" => "anthropic:claude-sonnet-4", "other" => true})
      )

      assert :ok = Opal.Settings.save(%{"default_model" => "openai:gpt-5"})

      settings = Opal.Settings.get_all()
      assert settings["default_model"] == "openai:gpt-5"
      assert settings["other"] == true
    end
  end
end
