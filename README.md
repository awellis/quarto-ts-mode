# quarto-ts-mode

An Emacs 32 major mode for authoring Quarto documents.

The package uses Emacs's built-in `markdown-ts-mode` rather than Polymode and
provides integrated editing, execution, preview, authoring, and
embedded-language tooling.

## Status

The current package provides:

- A `quarto-ts-mode` derived from `markdown-ts-mode`.
- `.qmd` file association.
- R, Python, Julia, and OJS code-block mode aliases.
- Tree-sitter-backed executable-cell extraction.
- Cell option and label extraction.
- Cell navigation, marking, folding, and fold-all commands.
- Imenu entries for labelled and unlabelled executable cells.
- Dedicated semantic faces for cell fences, languages, options, citations,
  cross-references, attributes, callouts, shortcodes, and table captions.
- Theme-aware table styling with distinct headers, body cells, delimiters,
  alignment rows, and header/body backgrounds.
- Independent inline-Markdown parsing inside table cells, preserving link,
  emphasis, code, and other inline syntax highlighting.
- An AUCTeX-like presentation layer that hides Markdown delimiters and link
  destinations while retaining editable source text.
- Cleaner cell-option, shortcode, callout, code-fence, and LaTeX-math display.
- Native YAML, Python, and Julia tree-sitter fontification, with conventional
  language-mode font-lock fallbacks when a grammar is unavailable.
- Context-sensitive completion for Quarto `#|` option names and common values.
- Schema-backed completion and documentation for document front matter and
  `_quarto.yml`/`_quarto.yaml` files, using the schema installed with Quarto.
- Project-aware YAML values for profiles, Lua filters, and extensions.
- Optional YAML Language Server validation using a generated Quarto schema.
- Cached project-wide completion for Quarto cross-references such as
  `@fig-...`, `@tbl-...`, and `@sec-...`.
- Citar citation completion and insertion when Citar is installed.
- Callout and shortcode insertion commands.
- Persistent shadow buffers for each language, with explicit bidirectional
  source maps when generated text changes positions.
- OJS-to-JavaScript translation for reactive names, `viewof`, `mutable`,
  imports, block cells, `await`, and `yield`.
- Ordinary Eglot sessions attached to language shadow buffers, including
  TypeScript Language Server for translated OJS.
- Flymake diagnostics mapped back into the `.qmd` source buffer.
- Completion, hover, and signature-help forwarding.
- Completion text edits copied back from executable cell bodies.
- Definitions and references remapped from synthetic files to `.qmd` files.
- Rename, cell formatting, and code-action edits mapped safely back from
  language shadow buffers; OJS rename and formatting discard generated-only
  edits through source maps.
- Cell, line, region, cells-above, and all-cells execution commands.
- Optional ESS, inferior Python, and `julia-repl` runner adapters.
- Quarto-native OJS execution that saves or starts the browser preview so
  Quarto reevaluates the complete reactive dependency graph.
- Respect for Quarto's `eval: false` cell option.
- Independent preview sessions for projects and standalone documents.
- Preview URL detection, browsing, refresh, logs, and clean process shutdown.
- Asynchronous document/project rendering with optional output formats.
- Unit tests plus live Ruff, R, Julia, and TypeScript language servers; ESS,
  Python, Julia, and OJS runners; preview; and render integration tests.

Edits outside executable cell bodies are intentionally discarded when mapping
language-server changes back to a document. Interactive snippet fields are not
yet preserved.

## Requirements

- GNU Emacs 32
- The `markdown` and `markdown-inline` tree-sitter grammars
- The `yaml` tree-sitter grammar for standalone Quarto project files
- Language grammars and major modes for the embedded languages you use
- Optional: Citar for citations; `yaml-language-server` for project validation;
  ESS and R `languageserver` for R; `julia-repl`, `julia-mode`, and Julia
  `LanguageServer` for Julia; an inferior Python process; and
  `typescript-language-server` plus TypeScript's `tsserver` for OJS

Install Markdown parsers interactively with:

```text
M-x markdown-ts-mode-install-parsers
```

## Development

```sh
make check
make integration-test  # requires Ruff, Python 3, and Quarto

# Optional local ESS and Julia integration
make integration-test \\
  ESS_LISP=/path/to/ess/lisp \\
  JULIA_REPL_LISP=/path/to/julia-repl \\
  JULIA_MODE_LISP=/path/to/julia-mode \\
  JULIA_TS_MODE_LISP=/path/to/julia-ts-mode \\
  S_LISP=/path/to/s.el \\
  TREE_SITTER_PATH=/path/to/tree-sitter-libraries
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
| `C-c C-q f` | Toggle current cell fold |
| `C-c C-q F` | Fold all cells |
| `C-c C-q u` | Unfold all cells |
| `C-c C-q h` | Toggle markup visibility |
| `C-c C-q d` | Describe the Quarto YAML option at point |
| `C-c C-q s` | Open a language shadow buffer |
| `C-c C-q e` | Start Eglot for an embedded language |
| `C-c C-q g r` | Rename an embedded-language symbol |
| `C-c C-q g f` | Format the current executable cell |
| `C-c C-q g a` | Run embedded-language code actions |
| `C-c C-q i c` | Insert or edit a citation with Citar |
| `C-c C-q i a` | Insert a callout |
| `C-c C-q i s` | Insert a shortcode |
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

In `_quarto.yml` and `_quarto.yaml`, `C-c C-q d` shows option documentation and
`C-c C-q e` starts YAML Language Server validation.
