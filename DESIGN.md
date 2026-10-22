# Design

## Goal

Provide a reusable Emacs 32 Quarto mode with feature parity with the useful
parts of `quarto-nvim`, without depending on Polymode.

## Architecture

The package is split into components so that editor parsing, language
intelligence, execution, and Quarto processes can evolve independently.

1. `quarto-ts-mode.el`
   - Major mode derived from `markdown-ts-mode`.
   - Cell navigation, folding, Imenu, and user-facing commands.

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
   - Rename, cell formatting, and code-action edits copied back from executable
     cells while rejecting changes to synthetic prose.
   - Interactive snippet fields remain planned.

5. `quarto-ts-font-lock.el`
   - Quarto-specific semantic faces layered over native Markdown and YAML.
   - Distinct cell fences, languages, options, citations, cross-references,
     attributes, callouts, shortcodes, and table captions.
   - Theme-aware table backgrounds with separate header, body, and delimiter
     faces.
   - Dedicated `markdown-inline` parser ranges inside pipe-table cells retain
     link, emphasis, code, and other inline syntax highlighting.
   - A presentation layer hides Markdown delimiters, link destinations, cell
     markers, shortcode wrappers, and callout wrappers without changing text.
   - Cell language names remain visible, and LaTeX mathematics receives a
     distinct semantic face.
   - Fresh per-language tree-sitter configuration prevents guest parser state
     from leaking between Python and Julia code blocks.
   - Conventional major-mode font-lock remains the grammar fallback.

6. `quarto-ts-authoring.el`
   - Context-sensitive cell-option name and value completion.
   - Cached project-wide cross-reference label discovery and completion.
   - Optional Citar completion and citation insertion.
   - Callout and shortcode insertion commands.

7. `quarto-ts-yaml.el`
   - Schema-backed completion and documentation for front matter and project
     configuration files.
   - Project-aware profile, filter, and extension values.
   - Optional YAML Language Server validation against Quarto's installed schema.

8. `quarto-ts-runner.el`
   - Language-neutral cell and region execution.
   - ESS, inferior Python, and `julia-repl` adapters.
   - Mixed-language cells-above/all execution and `eval: false` handling.
   - Further terminal transports remain configurable extensions.

9. `quarto-ts-preview.el`
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
- Python and Julia code blocks use distinct native tree-sitter parsers rather
  than leaking the first guest parser across later cells.
- Quarto options and document-level constructs retain semantic faces alongside
  language-native code fontification.
- A shadow buffer can preserve every source position by blanking prose and
  copying cells for one language verbatim.
- Ruff can manage the synthetic Python document through ordinary Eglot.
- The R `languageserver` can manage an ESS shadow buffer through ordinary
  Eglot.
- Julia `LanguageServer` can manage a `julia-mode` shadow buffer through
  ordinary Eglot.
- Ruff diagnostics retain the same positions and can be reported by Flymake in
  the `.qmd` source buffer.
- The Python runner starts an inferior process, waits for initialization, and
  evaluates cell code successfully.
- Runner dispatch, mixed-language ordering, regions, and `eval: false` behavior
  are covered by unit tests.
- ESS, inferior Python, and `julia-repl` adapters all execute live code and
  return the expected result.
- Standalone preview starts, reports a browser URL, and shuts down cleanly.
- A live Quarto render produces the expected HTML output.

## Development order

1. ~~Validate cell extraction against representative `.qmd` fixtures.~~
2. ~~Prototype a Python shadow buffer and mapped Eglot diagnostics.~~
3. ~~Forward basic completion and hover from Python Eglot.~~
4. ~~Map cell-local completion text edits and implement xref forwarding.~~
5. ~~Complete basic cell editing, folding, navigation, and Imenu support.~~
6. ~~Add R, Python, and Julia runner adapters.~~
7. ~~Add project-aware preview management.~~
8. ~~Validate R Eglot shadow buffers.~~
9. ~~Validate Julia Eglot shadow buffers.~~
10. ~~Add project cross-reference and chunk-option completion.~~
11. ~~Add rich Quarto-specific semantic fontification.~~
12. ~~Add citation integration, YAML completion, callout insertion, and
    shortcode authoring commands.~~
13. ~~Map rename, formatting, and code-action edits back to Quarto source.~~
14. ~~Integrate into Doom while retaining `poly-quarto-mode` as a fallback.~~

## Initial non-goals

- Emacs 31 and earlier.
- TRAMP.
- Inline rich output and image display.
- Owning or replacing language-specific REPL packages.
