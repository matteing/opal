# Opinions

Design opinions that shape Opal's architecture.

## No complicated RAG or context management

Models have got so good at working with raw text that overly-complicated RAG pipelines, vector databases, and embedding-based retrieval have fallen out of fashion for coding agents. Opal gives the model basic `grep` and `read_file` tools and lets it drive its own context gathering. This is simpler, more transparent, and — with current-generation models — just as effective.
