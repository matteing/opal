# `Opal.Context`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/context.ex#L1)

Discovers project context files and agent skills from the filesystem.

Context is gathered from two sources:

## Context Files (walk-up discovery)

Starting from the agent's `working_dir`, walks up the directory tree to
the filesystem root, collecting known context files at each level. These
files provide project-specific instructions that are prepended to the
agent's system prompt.

Files checked at each directory level:
  * `AGENTS.md`
  * `OPAL.md`
  * `.agents/AGENTS.md`
  * `.opal/OPAL.md`

The filename list is configurable via `Opal.Config.Features` `:context` subsystem.
Files found closer to `working_dir` appear later in the list (higher priority).

## Skills (directory discovery)

Scans well-known directories for skill subdirectories, each containing a
`SKILL.md` file per the [agentskills.io spec](https://agentskills.io/specification).

Standard search locations:
  * `<working_dir>/.agents/skills/*/SKILL.md`
  * `<working_dir>/.github/skills/*/SKILL.md`
  * `~/.agents/skills/*/SKILL.md`
  * `~/.opal/skills/*/SKILL.md`

Additional directories can be specified via `Opal.Config.Features` `:skills` subsystem.

Skills use **progressive disclosure**: only `name` and `description` are
loaded into the agent's context at startup. Full instructions are loaded
when a skill is activated.

# `build_context`

```elixir
@spec build_context(
  String.t(),
  keyword()
) :: String.t()
```

Builds the context string to inject into the system prompt.

Concatenates discovered context files and skill summaries into a single
string block. Returns an empty string if no context is found.

## Options

  * `:filenames` — context filenames (default: `["AGENTS.md", "OPAL.md"]`)
  * `:extra_dirs` — additional skill directories (default: `[]`)
  * `:skip_skills` — if `true`, skip skill discovery entirely (default: `false`)

# `discover_context`

```elixir
@spec discover_context(
  String.t(),
  keyword()
) :: [%{path: String.t(), content: String.t()}]
```

Discovers context files by walking up from `working_dir`.

Returns a list of `%{path: String.t(), content: String.t()}` maps,
ordered from root-most to deepest (closest to `working_dir` comes last).

## Options

  * `:filenames` — list of filenames to look for (default from config).
    Also searches `.agents/<filename>` and `.opal/<filename>` variants.

# `discover_skills`

```elixir
@spec discover_skills(
  String.t(),
  keyword()
) :: [Opal.Skill.t()]
```

Discovers skills from standard and configured directories.

Returns a list of `Opal.Skill.t()` structs with metadata parsed.
Only valid skills (those that parse and pass validation) are included;
invalid `SKILL.md` files are silently skipped.

## Options

  * `:extra_dirs` — additional directories containing skill subdirectories
    (default: `[]`).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
