# `Opal.Path`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/path.ex#L1)

Cross-platform path normalization and security utilities.

Provides functions for normalizing file paths across operating systems
and ensuring paths stay within allowed base directories to prevent
path traversal attacks.

# `normalize`

```elixir
@spec normalize(String.t()) :: String.t()
```

Normalizes a path by replacing backslashes with forward slashes and expanding it.

This ensures consistent path representation regardless of the source OS.

## Examples

    iex> Opal.Path.normalize("foo\\bar/baz")
    Path.expand("foo/bar/baz")

# `safe_relative`

```elixir
@spec safe_relative(String.t(), String.t()) ::
  {:ok, String.t()} | {:error, :outside_base_dir}
```

Ensures a path is safely contained within a base directory.

Expands both paths and verifies the target is a child of the base directory.
This prevents path traversal attacks (e.g. `../../etc/passwd`).

Returns `{:ok, expanded_path}` if the path is within the base directory,
or `{:error, :outside_base_dir}` if it escapes.

## Examples

    iex> Opal.Path.safe_relative("src/main.ex", "/project")
    {:ok, "/project/src/main.ex"}

    iex> Opal.Path.safe_relative("../../etc/passwd", "/project")
    {:error, :outside_base_dir}

# `to_native`

```elixir
@spec to_native(String.t()) :: String.t()
```

Converts a path to use native OS separators.

Uses backslashes on Windows and forward slashes elsewhere.

## Examples

    iex> Opal.Path.to_native("foo/bar/baz")
    "foo/bar/baz"

---

*Consult [api-reference.md](api-reference.md) for complete listing*
