defmodule Opal.Platform do
  @moduledoc """
  Cross-platform helpers.

  Provides a single, cached platform detection used throughout the codebase
  instead of scattering `:os.type()` calls.
  """

  @type os :: :linux | :macos | :windows

  @doc """
  Returns the current platform as `:linux`, `:macos`, or `:windows`.
  """
  @spec os() :: os()
  def os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, _} -> :linux
      {:win32, _} -> :windows
    end
  end

  @doc "Returns `true` on Windows."
  @spec windows?() :: boolean()
  def windows?, do: os() == :windows

  @doc "Returns `true` on macOS."
  @spec macos?() :: boolean()
  def macos?, do: os() == :macos

  @doc "Returns `true` on Linux (any non-macOS Unix)."
  @spec linux?() :: boolean()
  def linux?, do: os() == :linux

  @doc "Returns `true` on any Unix variant (macOS or Linux)."
  @spec unix?() :: boolean()
  def unix?, do: os() in [:linux, :macos]
end
