# quarto-ts-mode

An experimental Emacs 32 major mode for authoring Quarto documents.

The package is being developed locally before Doom Emacs integration. It uses
Emacs's built-in `markdown-ts-mode` rather than Polymode and is intended to
provide the editing, code-running, preview, and embedded-language tooling found
in `quarto-nvim`.

## Status

This is an early parser and embedded-language prototype. It currently provides:

- A `quarto-ts-mode` derived from `markdown-ts-mode`.
- `.qmd` file association.
- R, Python, Julia, and OJS code-block mode aliases.
- Tree-sitter-backed executable-cell extraction.
- Cell option and label extraction.
- Cell navigation and marking commands.
- Persistent, position-preserving shadow buffers for each language.
- Ordinary Eglot sessions attached to language shadow buffers.
- Flymake diagnostics mapped back into the `.qmd` source buffer.
- Completion, hover, and signature-help forwarding.
- Completion text edits copied back from executable cell bodies.
- Definitions and references remapped from synthetic files to `.qmd` files.
- Cell, line, region, cells-above, and all-cells execution commands.
- Optional ESS, inferior Python, and `julia-repl` runner adapters.
- Respect for Quarto's `eval: false` cell option.
- Independent preview sessions for projects and standalone documents.
- Preview URL detection, browsing, refresh, logs, and clean process shutdown.
- Asynchronous document/project rendering with optional output formats.
- Unit tests plus live Ruff, Python, preview, and render integration tests.

Rename, formatting, and workspace edits are not yet mapped. Edits outside
executable cell bodies are intentionally discarded, and interactive snippet
fields are not yet preserved.

## Requirements

- GNU Emacs 32
- The `markdown` and `markdown-inline` tree-sitter grammars
- Language grammars and major modes for the embedded languages you use
- Optional: ESS for R, `julia-repl` for Julia, and an inferior Python process

Install Markdown parsers interactively with:

```text
M-x markdown-ts-mode-install-parsers
```

## Development

```sh
make check
make integration-test  # requires Ruff and Python 3
```

Development grammars may be installed in the ignored project-local
`tree-sitter/` directory. Parser-dependent tests are skipped when the Markdown
grammars are unavailable.

## Prototype key bindings

| Binding | Command |
|---|---|
| `C-c C-q n` | Next cell |
| `C-c C-q p` | Previous cell |
| `C-c C-q m` | Mark cell body |
| `C-c C-q s` | Open a language shadow buffer |
| `C-c C-q e` | Start Eglot for an embedded language |
| `C-c C-q c` | Run current cell |
| `C-c C-q RET` | Run current cell and move to the next |
| `C-c C-q l` | Run current line |
| `C-c C-q r` | Run region |
| `C-c C-q a` | Run cells above |
| `C-c C-q b` | Run all cells |
| `C-c C-q z` | Open the current language's REPL |
| `C-c C-q v p` | Start/restart preview |
| `C-c C-q v s` | Stop preview |
| `C-c C-q v b` | Browse preview |
| `C-c C-q v r` | Save and refresh preview |
| `C-c C-q v l` | Show preview log |
| `C-c C-q v x` | Render document |
| `C-c C-q v f` | Render document to a format |
| `C-c C-q v P` | Render project |

These bindings are provisional. Doom-specific bindings will live in the Doom
configuration rather than this package.
