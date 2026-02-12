# `Opal.Tool.Edit`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/tool/edit.ex#L1)

Applies a search-and-replace edit to a file.

The old string must match exactly one location in the file. Implements
the `Opal.Tool` behaviour and resolves paths relative to the session's
working directory using `Opal.Path.safe_relative/2`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
