# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

This is `$DOOMDIR` — a personal Doom Emacs private configuration directory (`~/.config/doom`), not an application codebase. It has three files that Doom itself expects by convention:

- `init.el` — declares which Doom modules are enabled (the `(doom! ...)` form). Editing this changes what functionality is available, not custom behavior.
- `packages.el` — declares extra packages via `package!` (and their `:recipe` if not on a package archive).
- `config.el` — all custom configuration: variables, keybindings (`map!`), and hand-written `defun`s/`use-package!` blocks.

## Commands

- After editing `init.el` or `packages.el` (module list or package declarations changed): run `doom sync`, then restart Emacs (or `M-x doom/reload`, bound to `SPC h r`).
- After editing `config.el` only: no sync needed; `M-x doom/reload` (or restart Emacs) picks it up.
- To sanity-check that the config loads without error without a full GUI restart, try loading Doom's bootstrapper in batch mode, e.g.:
  `emacs --batch -l ~/.config/emacs/early-init.el --eval '(message "LOADED OK")'`
  (swap `~/.config/emacs` for wherever the Doom Emacs core is checked out on this machine; older Doom versions bootstrap from `init.el` instead of `early-init.el`). This CLI bootstrap path doesn't always behave like a normal load, though — treat a clean exit as a good sign, not proof, and fall back to an actual GUI/`emacs --batch` restart when in doubt.
- There is no test suite, linter, or build step — verification is "does Emacs start and does the changed behavior work."

## Architecture / custom behavior in config.el

- **Project test/clean/run** (`SPC p t/c/r`): `my/project-test` prompts among named, per-project test scripts (`my/project-test-scripts`, an alist persisted to that project's `.dir-locals.el`), with a "Create new test script..." entry to define one on the fly. `my/project-clean-and-compile` and `my/project-run` are simpler: each reads a single shell command from a buffer-local variable (`my/project-clean-and-compile-command`, `my/project-run-command`) meant to be set per-project in `.dir-locals.el`, prompting interactively if unset. All these variables are whitelisted as safe-local-variables.
- **Persistent run scripts** (`SPC p R`): `my/project-run-scripts`, another per-project `.dir-locals.el` alist, holds long-lived commands (dev servers, watchers) — unlike the `compile`-based commands above, each gets its own dedicated `comint` process buffer so several can run concurrently. `SPC p R` opens a `tabulated-list-mode` buffer (`my/project-run-scripts-mode`) to run/restart, kill, edit, add, and delete them.
- **Project dashboard** (`SPC p d`, and auto-shown on `+workspaces-switch-project-function`): `my/project-dashboard` renders a per-project buffer (git branch, `git status --short`, last 10 commits as clickable buttons via Magit, recent files from `recentf-list` filtered to the project root). This replaces Doom workspaces' default "find file" prompt on project switch — see the `+workspaces-switch-project-function` override at the bottom of that section.
- **Notes** (`SPC n`): `my/new-note` prompts for a category (idea/observation/question/feature/monetizable idea/todo, `my/note-categories`) and an optional hub/subcategory note to link to, then writes a flat, timestamped, slugified org-roam node (seeded from that category's template) into `org-roam-directory`. `my/list-notes` is just `org-roam-node-find`.
- **Diary** (`SPC o d` global, `SPC p j` per-project): `my/diary-open`/`my/project-diary-open` split the frame into a running Markdown log and a small compose buffer — type a message, RET sends it, appended with a timestamp (consecutive messages within `my/diary-collapse-seconds' share one). `@mention`-ing a name from `my/diary-personas` (e.g. `@mimi`, backed by a system-prompt file under `personas/`) gets that persona an asynchronous, OpenAI-backed reply in the same log; requires an `api.openai.com` entry in `auth-source` (e.g. `~/.authinfo.gpg`).
- **Dictation** (`SPC t t`): `my/dictation-mode` is a minor mode that streams mic input through whisper.cpp's `whisper-stream` (GPU-accelerated via Vulkan) and inserts finished segments at point.
- **LSP smart jump** (`C-RET` in `lsp-mode` buffers): `my/lsp-jump-or-list-usages` jumps to a symbol's definition, or lists usages via xref if point is already on the definition.
- **claude-code-ide** (`SPC a c/m/t/r`): integrates this CLI into Emacs via `claude-code-ide.el` (declared in `packages.el` with a GitHub recipe), using `vterm` as the terminal backend and Emacs-aware tools (xref, project info, imenu, tree-sitter) enabled via `claude-code-ide-emacs-tools-setup`.

## Conventions to preserve when editing

- Custom interactive commands and helpers are prefixed `my/` (or `my/--` for internal helpers), matching the existing style — keep new additions consistent with this.
- Package-specific settings belong inside `(after! PACKAGE ...)` or a `use-package!` `:config` block, not loose at top level, per Doom's own convention — Doom's defaults can otherwise clobber settings applied before the package loads. (Exceptions: file/directory variables like `org-directory`, variables a package's docstring says to set before it loads, and Doom variables themselves, i.e. those starting with `doom-` or `+`.)
