defmodule Opal.RPCTest do
  use ExUnit.Case, async: true

  alias Opal.RPC

  describe "encode_request/3" do
    test "encodes a valid JSON-RPC 2.0 request" do
      json = RPC.encode_request(1, "agent/prompt", %{text: "hello"})
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "agent/prompt"
      assert decoded["params"] == %{"text" => "hello"}
    end

    test "supports string ids" do
      json = RPC.encode_request("s2c-1", "client/confirm", %{})
      decoded = Jason.decode!(json)
      assert decoded["id"] == "s2c-1"
    end
  end

  describe "encode_response/2" do
    test "encodes a success response" do
      json = RPC.encode_response(1, %{ok: true})
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["result"] == %{"ok" => true}
      refute Map.has_key?(decoded, "error")
    end
  end

  describe "encode_error/3,4" do
    test "encodes an error without data" do
      json = RPC.encode_error(1, -32601, "Method not found")
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["error"]["code"] == -32601
      assert decoded["error"]["message"] == "Method not found"
      refute Map.has_key?(decoded["error"], "data")
    end

    test "encodes an error with data" do
      json = RPC.encode_error(1, -32603, "Internal error", %{reason: "boom"})
      decoded = Jason.decode!(json)

      assert decoded["error"]["data"] == %{"reason" => "boom"}
    end

    test "supports nil id for parse errors" do
      json = RPC.encode_error(nil, -32700, "Parse error")
      decoded = Jason.decode!(json)
      assert decoded["id"] == nil
    end
  end

  describe "encode_notification/2" do
    test "encodes a notification without id" do
      json = RPC.encode_notification("agent/event", %{type: "token_delta", delta: "hi"})
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "agent/event"
      assert decoded["params"]["type"] == "token_delta"
      refute Map.has_key?(decoded, "id")
    end
  end

  describe "decode/1" do
    test "decodes a request" do
      json = ~s({"jsonrpc":"2.0","id":1,"method":"agent/prompt","params":{"text":"hi"}})
      assert {:request, 1, "agent/prompt", %{"text" => "hi"}} = RPC.decode(json)
    end

    test "decodes a request with no params" do
      json = ~s({"jsonrpc":"2.0","id":2,"method":"session/list"})
      assert {:request, 2, "session/list", %{}} = RPC.decode(json)
    end

    test "decodes a success response" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}})
      assert {:response, 1, %{"ok" => true}} = RPC.decode(json)
    end

    test "decodes an error response" do
      json = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Not found"}})

      assert {:error_response, 1, %{"code" => -32601, "message" => "Not found"}} =
               RPC.decode(json)
    end

    test "decodes a notification" do
      json = ~s({"jsonrpc":"2.0","method":"agent/event","params":{"type":"token"}})
      assert {:notification, "agent/event", %{"type" => "token"}} = RPC.decode(json)
    end

    test "returns parse_error for invalid JSON" do
      assert {:error, :parse_error} = RPC.decode("not json")
    end

    test "returns invalid_request for valid JSON without jsonrpc field" do
      assert {:error, :invalid_request} = RPC.decode(~s({"method":"foo"}))
    end

    test "returns invalid_request for wrong jsonrpc version" do
      assert {:error, :invalid_request} = RPC.decode(~s({"jsonrpc":"1.0","method":"foo"}))
    end
  end

  describe "roundtrip encode/decode" do
    test "request roundtrips" do
      json = RPC.encode_request(42, "models/list", %{})
      assert {:request, 42, "models/list", %{}} = RPC.decode(json)
    end

    test "response roundtrips" do
      json = RPC.encode_response(42, %{models: ["a", "b"]})
      assert {:response, 42, %{"models" => ["a", "b"]}} = RPC.decode(json)
    end

    test "notification roundtrips" do
      json = RPC.encode_notification("agent/event", %{type: "delta", delta: "hi"})

      assert {:notification, "agent/event", %{"type" => "delta", "delta" => "hi"}} =
               RPC.decode(json)
    end

    test "error response roundtrips" do
      json = RPC.encode_error(7, -32600, "Bad request")

      assert {:error_response, 7, %{"code" => -32600, "message" => "Bad request"}} =
               RPC.decode(json)
    end
  end

  describe "error code constants" do
    test "parse_error is -32700" do
      assert RPC.parse_error() == -32700
    end

    test "invalid_request is -32600" do
      assert RPC.invalid_request() == -32600
    end

    test "method_not_found is -32601" do
      assert RPC.method_not_found() == -32601
    end

    test "invalid_params is -32602" do
      assert RPC.invalid_params() == -32602
    end

    test "internal_error is -32603" do
      assert RPC.internal_error() == -32603
    end
  end
end
