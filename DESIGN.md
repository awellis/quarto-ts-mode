# Design

## Goal

Provide a reusable Emacs 32 Quarto mode with feature parity with the useful
parts of `quarto-nvim`, without depending on Polymode.

## Architecture

The package is split into components so that editor parsing, language
intelligence, execution, and Quarto processes can evolve independently.

1. `quarto-ts-mode.el`
   - Major mode derived from `markdown-ts-mode`.
   - Quarto syntax, navigation, folding, and user-facing commands.

2. `quarto-ts-cell.el`
   - Parser-neutral cell representation.
   - Cell discovery, options, labels, and source ranges.
   - The initial provider uses the standard Markdown tree-sitter grammar.

3. `quarto-ts-shadow.el`
   - Persistent per-language shadow buffers.
   - Source-position-preserving synchronization.
   - Synthetic file identities in the source project.

4. `quarto-ts-eglot.el`
   - Ordinary Eglot sessions in language shadow buffers.
   - Flymake diagnostics mapped back to the Quarto source.
   - Completion, hover, and signature-help forwarding.
   - Completion edits copied back from executable cell bodies.
   - Xrefs remapped from synthetic files to Quarto source files.
   - Rename, formatting, interactive snippets, and general workspace-edit
     mapping remain planned.

5. `quarto-ts-runner.el`
   - Language-neutral cell and region execution.
   - ESS, inferior Python, and `julia-repl` adapters.
   - Mixed-language cells-above/all execution and `eval: false` handling.
   - Further terminal transports remain configurable extensions.

6. `quarto-ts-preview.el`
   - One preview process per standalone file or Quarto project.
   - URL detection, browsing, refresh, logs, and lifecycle management.
   - Asynchronous document and project rendering with format selection.

## Parser strategy

The cell API must not expose parser nodes. The first backend uses the standard
Markdown grammar. This lets development proceed while the community
`tree-sitter-quarto` grammar and the official Quarto grammar mature. A future
backend can replace cell extraction without changing runners, previews, or
Eglot integration.

## Validated prototypes

- The standard Markdown grammar recognizes `{r}`, `{python}`, and `{julia}`
  fenced blocks with stable cell and body ranges.
- A shadow buffer can preserve every source position by blanking prose and
  copying cells for one language verbatim.
- Ruff can manage the synthetic Python document through ordinary Eglot.
- Ruff diagnostics retain the same positions and can be reported by Flymake in
  the `.qmd` source buffer.
- The Python runner starts an inferior process, waits for initialization, and
  evaluates cell code successfully.
- Runner dispatch, mixed-language ordering, regions, and `eval: false` behavior
  are covered by unit tests; live ESS and Julia validation remains pending.
- Standalone preview starts, reports a browser URL, and shuts down cleanly.
- A live Quarto render produces the expected HTML output.

## Development order

1. ~~Validate cell extraction against representative `.qmd` fixtures.~~
2. ~~Prototype a Python shadow buffer and mapped Eglot diagnostics.~~
3. ~~Forward basic completion and hover from Python Eglot.~~
4. ~~Map cell-local completion text edits and implement xref forwarding.~~
5. Complete basic editing, folding, and navigation.
6. ~~Add R, Python, and Julia runner adapters.~~
7. ~~Add project-aware preview management.~~
8. Validate R and Julia Eglot shadow buffers.
9. Add citation, cross-reference, YAML, and chunk-option completion.
10. Integrate into Doom while retaining `poly-quarto-mode` as a fallback.

## Initial non-goals

- Emacs 31 and earlier.
- TRAMP.
- Inline rich output and image display.
- Owning or replacing language-specific REPL packages.
