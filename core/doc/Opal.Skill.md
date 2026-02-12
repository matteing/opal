# `Opal.Skill`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/skill.ex#L1)

Parses and validates Agent Skills following the [agentskills.io specification](https://agentskills.io/specification).

A skill is a directory containing a `SKILL.md` file with YAML frontmatter
(metadata) and a Markdown body (instructions). Skills support progressive
disclosure: metadata is loaded at discovery time, and full instructions are
loaded on demand when the agent activates the skill.

## SKILL.md Format

    ---
    name: my-skill
    description: What this skill does and when to use it.
    ---

    # Instructions

    Step-by-step instructions for the agent...

## Required Fields

  * `name` — 1–64 characters, lowercase alphanumeric and hyphens only.
    Must not start/end with `-` or contain `--`. Must match the parent
    directory name.

  * `description` — 1–1024 characters describing what the skill does
    and when to use it.

## Optional Fields

  * `license` — License name or reference to a bundled file.
  * `compatibility` — 1–500 characters indicating environment requirements.
  * `metadata` — Arbitrary key-value map for additional properties.
  * `allowed-tools` — Space-delimited list of pre-approved tools (experimental).

## Usage

    # Parse a single SKILL.md file
    {:ok, skill} = Opal.Skill.parse_file("/path/to/my-skill/SKILL.md")

    # Parse raw markdown content
    {:ok, skill} = Opal.Skill.parse("---\nname: my-skill\n...")

    # Validate a parsed skill against its directory
    :ok = Opal.Skill.validate(skill, dir_name: "my-skill")

# `t`

```elixir
@type t() :: %Opal.Skill{
  allowed_tools: [String.t()] | nil,
  compatibility: String.t() | nil,
  description: String.t(),
  instructions: String.t(),
  license: String.t() | nil,
  metadata: map() | nil,
  name: String.t(),
  path: String.t() | nil
}
```

# `parse`

```elixir
@spec parse(String.t()) :: {:ok, t()} | {:error, term()}
```

Parses raw SKILL.md content (YAML frontmatter + Markdown body).

The content must begin with `---` followed by YAML frontmatter and
a closing `---`. Everything after the closing delimiter is treated
as the Markdown instructions body.

Returns `{:ok, skill}` or `{:error, reason}`.

## Examples

    iex> Opal.Skill.parse("---\nname: test\ndescription: A test skill.\n---\n# Hello")
    {:ok, %Opal.Skill{name: "test", description: "A test skill.", instructions: "# Hello"}}

# `parse_file`

```elixir
@spec parse_file(String.t()) :: {:ok, t()} | {:error, term()}
```

Parses a `SKILL.md` file from disk.

Returns `{:ok, skill}` with the full struct including `:path`, or
`{:error, reason}` if the file cannot be read or parsed.

# `summary`

```elixir
@spec summary(t()) :: String.t()
```

Returns a short summary string for progressive disclosure.

Only includes `name` and `description` — suitable for injecting into
the agent's context at startup without loading full instructions.

# `validate`

```elixir
@spec validate(
  t(),
  keyword()
) :: :ok | {:error, [String.t()]}
```

Validates a parsed skill struct.

Checks all field constraints from the agentskills.io spec. Returns
`:ok` or `{:error, reasons}` where `reasons` is a list of validation
error strings.

## Options

  * `:dir_name` — if provided, validates that `skill.name` matches
    the parent directory name.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
