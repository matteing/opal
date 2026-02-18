defmodule Opal.RPC.ProtocolTest do
  use ExUnit.Case, async: true

  alias Opal.RPC.Protocol

  describe "methods/0" do
    test "returns a non-empty list of method definitions" do
      methods = Protocol.methods()
      assert is_list(methods)
      assert length(methods) > 0
    end

    test "every method has required fields" do
      for m <- Protocol.methods() do
        assert is_binary(m.method), "method name must be a string: #{inspect(m)}"
        assert m.direction == :client_to_server
        assert is_binary(m.description)
        assert is_list(m.params)
        assert is_list(m.result)
      end
    end

    test "every param has required fields" do
      for m <- Protocol.methods(), p <- m.params do
        assert is_binary(p.name), "param name must be a string"
        assert p.type != nil, "param type must be set"
        assert is_boolean(p.required), "param required must be boolean"
        assert is_binary(p.description), "param description must be a string"
      end
    end
  end

  describe "method_names/0" do
    test "returns the expected method names" do
      names = Protocol.method_names()
      assert "session/start" in names
      assert "agent/prompt" in names
      assert "agent/abort" in names
      assert "agent/state" in names
      assert "session/list" in names
      assert "session/branch" in names
      assert "session/compact" in names
      assert "models/list" in names
      assert "auth/status" in names
      assert "auth/login" in names
      assert "opal/config/get" in names
      assert "opal/config/set" in names
    end
  end

  describe "method/1" do
    test "returns a definition for a known method" do
      m = Protocol.method("agent/prompt")
      assert m.method == "agent/prompt"
      assert m.direction == :client_to_server

      required = Enum.filter(m.params, & &1.required) |> Enum.map(& &1.name)
      assert "session_id" in required
      assert "text" in required
    end

    test "returns nil for unknown method" do
      assert Protocol.method("foo/bar") == nil
    end

    test "feature schemas include debug toggle" do
      session_start = Protocol.method("session/start")
      opal_set = Protocol.method("opal/config/set")

      start_features = Enum.find(session_start.params, &(&1.name == "features"))
      set_features = Enum.find(opal_set.params, &(&1.name == "features"))

      assert {:object, start_feature_fields} = start_features.type
      assert {:object, set_feature_fields} = set_features.type
      assert start_feature_fields["debug"] == :boolean
      assert set_feature_fields["debug"] == :boolean
    end
  end

  describe "server_requests/0" do
    test "includes client/confirm and client/input" do
      names = Protocol.server_request_names()
      assert "client/confirm" in names
      assert "client/input" in names
    end

    test "every server request is server_to_client direction" do
      for sr <- Protocol.server_requests() do
        assert sr.direction == :server_to_client
      end
    end
  end

  describe "event_types/0" do
    test "includes all expected event types" do
      types = Protocol.event_type_names()
      assert "agent_start" in types
      assert "agent_end" in types
      assert "agent_abort" in types
      assert "message_start" in types
      assert "message_delta" in types
      assert "thinking_start" in types
      assert "thinking_delta" in types
      assert "tool_execution_start" in types
      assert "tool_execution_end" in types
      assert "turn_end" in types
      assert "error" in types
    end

    test "message_delta event has a delta field" do
      delta = Enum.find(Protocol.event_types(), &(&1.type == "message_delta"))
      field_names = Enum.map(delta.fields, & &1.name)
      assert "delta" in field_names
    end
  end

  describe "notification_method/0" do
    test "returns agent/event" do
      assert Protocol.notification_method() == "agent/event"
    end
  end

  describe "spec/0" do
    test "returns a complete spec map" do
      spec = Protocol.spec()
      assert spec.version == "0.1.0"
      assert spec.transport == "stdio"
      assert spec.framing == "newline-delimited JSON"
      assert spec.notification_method == "agent/event"
      assert is_list(spec.methods)
      assert is_list(spec.server_requests)
      assert is_list(spec.event_types)
    end

    test "spec methods match methods/0" do
      assert Protocol.spec().methods == Protocol.methods()
    end

    test "spec is a well-formed map" do
      spec = Protocol.spec()
      # Types use Elixir tuples (e.g. {:array, :string}) which are not
      # directly JSON-encodable — that's by design for codegen. The mix
      # task handles its own serialization.
      assert is_map(spec)
      assert length(spec.methods) > 0
      assert length(spec.server_requests) > 0
      assert length(spec.event_types) > 0
    end
  end
end
