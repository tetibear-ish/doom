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
- To sanity-check that the config loads without error without a full GUI restart, load it in batch mode, e.g.:
  `emacs --batch -l ~/.config/emacs/init.el --eval '(message "LOADED OK")'`
  (swap `~/.config/emacs` for wherever the Doom emacs core is checked out on this machine).
- There is no test suite, linter, or build step — verification is "does Emacs start and does the changed behavior work."

## Architecture / custom behavior in config.el

- **Project commands** (`SPC p t/c/r`): `my/project-test`, `my/project-clean-and-compile`, `my/project-run` shell out via `compile` from the project root. Each reads a per-project shell command from a buffer-local variable (`my/project-test-command`, etc.) that is meant to be set per-project in that project's `.dir-locals.el`; if unset, the user is prompted interactively. These variables are whitelisted as safe-local-variables.
- **Project dashboard** (`SPC p d`, and auto-shown on `+workspaces-switch-project-function`): `my/project-dashboard` renders a per-project buffer (git branch, `git status --short`, last 10 commits as clickable buttons via Magit, recent files from `recentf-list` filtered to the project root). This replaces Doom workspaces' default "find file" prompt on project switch — see the `+workspaces-switch-project-function` override at the bottom of that section.
- **Notes system** (`SPC n`): `my/new-idea`, `my/new-question`, `my/new-thought` create timestamped, slugified org files under subdirectories (`ideas/`, `questions/`, `thoughts/`) of `my/notes-root` (an Obsidian vault path), each seeded with a skeleton template. `org-roam-directory` is configured separately, pointed at a different path under `~/Documents/org/roam/`. Don't conflate the two note systems — notes-root/Obsidian is for these quick-capture skeletons, org-roam is Doom's `(org +roam2)` module.
- **claude-code-ide** (`SPC a c/m/t/r`): integrates this CLI into Emacs via `claude-code-ide.el` (declared in `packages.el` with a GitHub recipe), using `vterm` as the terminal backend and Emacs-aware tools (xref, project info, imenu, tree-sitter) enabled via `claude-code-ide-emacs-tools-setup`.

## Conventions to preserve when editing

- Custom interactive commands and helpers are prefixed `my/` (or `my/--` for internal helpers), matching the existing style — keep new additions consistent with this.
- Package-specific settings belong inside `(after! PACKAGE ...)` or a `use-package!` `:config` block, not loose at top level, per Doom's own convention (see the comment block explaining this near the top of `config.el`).
