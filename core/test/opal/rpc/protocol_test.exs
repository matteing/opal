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
      assert "agent/steer" in names
      assert "agent/abort" in names
      assert "agent/state" in names
      assert "session/list" in names
      assert "session/branch" in names
      assert "session/compact" in names
      assert "models/list" in names
      assert "auth/status" in names
      assert "auth/login" in names
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
      et = Protocol.event_type("message_delta")
      field_names = Enum.map(et.fields, & &1.name)
      assert "delta" in field_names
    end
  end

  describe "known_method?/1" do
    test "returns true for known methods" do
      assert Protocol.known_method?("session/start")
      assert Protocol.known_method?("agent/prompt")
    end

    test "returns false for unknown methods" do
      refute Protocol.known_method?("foo/bar")
    end
  end

  describe "known_event_type?/1" do
    test "returns true for known event types" do
      assert Protocol.known_event_type?("agent_start")
      assert Protocol.known_event_type?("message_delta")
    end

    test "returns false for unknown event types" do
      refute Protocol.known_event_type?("unknown_event")
    end
  end

  describe "required_params/1" do
    test "returns required params for agent/prompt" do
      required = Protocol.required_params("agent/prompt")
      assert "session_id" in required
      assert "text" in required
    end

    test "returns empty list for session/list (no required params)" do
      assert Protocol.required_params("session/list") == []
    end

    test "returns empty list for unknown method" do
      assert Protocol.required_params("foo/bar") == []
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

    test "spec is JSON-serializable" do
      assert {:ok, json} = Jason.encode(Protocol.spec_json())
      assert is_binary(json)
      assert {:ok, decoded} = Jason.decode(json)
      assert is_map(decoded)
    end
  end

  describe "protocol completeness" do
    test "every method in Protocol has a handler clause (not method_not_found)" do
      for name <- Protocol.method_names() do
        result =
          try do
            Opal.RPC.Handler.handle(name, %{})
          rescue
            # Some methods may crash with empty params (e.g. session/start
            # tries to start a real session). That's fine — the method is
            # still *handled*, it just needs valid params.
            _ -> :handled_but_raised
          end

        case result do
          {:error, -32601, _, _} ->
            flunk("Method #{name} is declared in Protocol but not handled")

          _ ->
            :ok
        end
      end
    end
  end
end
