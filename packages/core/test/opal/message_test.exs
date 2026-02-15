defmodule Opal.MessageTest do
  use ExUnit.Case, async: true

  alias Opal.Message

  # Validates user message construction
  describe "user/1" do
    test "creates a message with role :user and given content" do
      msg = Message.user("Hello")
      assert msg.role == :user
      assert msg.content == "Hello"
    end

    test "generates a unique id" do
      msg = Message.user("Hi")
      assert is_binary(msg.id)
      assert byte_size(msg.id) > 0
    end

    test "two calls produce different ids" do
      msg1 = Message.user("A")
      msg2 = Message.user("B")
      assert msg1.id != msg2.id
    end

    test "sets other fields to defaults" do
      msg = Message.user("Hi")
      assert msg.tool_calls == nil
      assert msg.call_id == nil
      assert msg.name == nil
      assert msg.is_error == false
    end
  end

  # Validates assistant message construction
  describe "assistant/1" do
    test "creates a message with role :assistant and given content" do
      msg = Message.assistant("Sure thing")
      assert msg.role == :assistant
      assert msg.content == "Sure thing"
    end

    test "defaults tool_calls to empty list" do
      msg = Message.assistant("OK")
      assert msg.tool_calls == []
    end
  end

  # Validates assistant message with tool calls
  describe "assistant/2" do
    test "stores tool_calls when provided" do
      calls = [%{call_id: "c1", name: "read", arguments: %{"path" => "/tmp"}}]
      msg = Message.assistant("Let me check", calls)
      assert msg.role == :assistant
      assert msg.content == "Let me check"
      assert msg.tool_calls == calls
    end

    test "content can be nil" do
      msg = Message.assistant(nil, [])
      assert msg.role == :assistant
      assert msg.content == nil
    end
  end

  # Validates tool call message construction
  describe "tool_call/3" do
    test "creates a message with role :tool_call" do
      msg = Message.tool_call("call-1", "read_file", %{"path" => "/tmp/a.txt"})
      assert msg.role == :tool_call
      assert msg.call_id == "call-1"
      assert msg.name == "read_file"
    end

    test "encodes arguments as JSON in content" do
      args = %{"path" => "/tmp/a.txt"}
      msg = Message.tool_call("call-1", "read_file", args)
      assert msg.content == Jason.encode!(args)
    end

    test "generates a unique id" do
      msg1 = Message.tool_call("c1", "tool", %{})
      msg2 = Message.tool_call("c2", "tool", %{})
      assert msg1.id != msg2.id
    end
  end

  # Validates tool result message construction
  describe "tool_result/2" do
    test "creates a message with role :tool_result and is_error false by default" do
      msg = Message.tool_result("call-1", "file contents here")
      assert msg.role == :tool_result
      assert msg.call_id == "call-1"
      assert msg.content == "file contents here"
      assert msg.is_error == false
    end
  end

  # Validates tool result with error flag
  describe "tool_result/3" do
    test "sets is_error to true when specified" do
      msg = Message.tool_result("call-1", "something went wrong", true)
      assert msg.role == :tool_result
      assert msg.is_error == true
    end

    test "sets is_error to false when explicitly passed" do
      msg = Message.tool_result("call-1", "ok", false)
      assert msg.is_error == false
    end
  end
end
