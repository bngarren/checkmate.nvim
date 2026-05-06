# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`checkmate.nvim` is a Neovim plugin for managing todo items in Markdown files.
It converts `[ ]`/`[x]` Markdown checkbox syntax to Unicode markers (□/✔/…),
manages todo state transitions, metadata tags (dates, priority, custom), and
hierarchical todo trees — all backed by Treesitter parsing.

## Commands

```bash
make test                        # run all tests (headless nvim via busted)
make test FILE=tests/foo_spec.lua  # run a single test file
make test FILTER="some desc"     # filter tests by description
```

Tests live in `tests/` and use busted with a custom `tests/minimal_init.lua`.
The `Makefile` wires up the Neovim runtime path before running busted.

For interactive debugging, launch Neovim with `tests/interactive.lua` and use
the `lua/checkmate/debug/` helpers. DAP is supported via `osv`; set `DEBUG=1`
before running headless tests to block on port 8086.

## Architecture

### Public API (`lua/checkmate/init.lua`)
User-facing entry point: `setup()`, `toggle()`, `create_todo_*()`, `archive()`, etc. Delegates to the internal API via the transaction system.

### Transaction System (`lua/checkmate/transaction.lua`)
Groups buffer-mutating operations into batches so `discover_todos` (expensive Treesitter re-parse) runs only once per batch. Operations return `TextDiffHunk[]`; callbacks are classified as micro (queued during op/micro phase) or macro (queued otherwise) and drain in order: ops → micro-cbs → macro-cbs, repeating until all queues are empty.

### Internal API (`lua/checkmate/api.lua`)
Operation functions consumed by the transaction system: `toggle_state`, `create_todo_above/below/child`, `remove_todo`, `archive_todos`, `process_buffer`. `process_buffer` is the main re-render entry point, debounced (leading+trailing, 100 ms), triggered by autocmds.

### Parser (`lua/checkmate/parser/init.lua`)
`get_todo_map(bufnr)` returns a cached `TodoMap` (keyed by `changedtick`). On a cache miss it calls `discover_todos`, which walks Treesitter `list_item` nodes, places/reuses stable `ns_todos` extmarks as IDs (with `right_gravity = false`), builds parent–child relationships, and cleans up orphaned extmarks.

### TodoItem (`lua/checkmate/lib/todo_item.lua`)
Data class for a parsed todo. `range` is the *semantic* range (adjusts Treesitter's raw range: resolves `end_col == 0` quirk, scans lines to find the true content boundary stopping at sibling list items).

### Buffer (`lua/checkmate/buffer/init.lua`)
Sets up autocmds (`TextChanged` → full process, `TextChangedI` → highlight-only, `InsertLeave` → full process if modified) and `nvim_buf_attach` `on_lines` to track the last-changed region.

### Diff (`lua/checkmate/lib/diff.lua`)
`apply_diff(bufnr, hunks)` applies `TextDiffHunk[]` to the buffer. Hunks are sorted and applied bottom-up to keep line offsets stable.

### Highlights (`lua/checkmate/highlights.lua`)
Two strategies chosen adaptively in `apply_highlighting`:
- **Immediate** (< 500 lines AND < 30 root todos): `clear_hl_ns(bufnr)` wipes everything, then synchronously re-renders all roots.
- **Progressive** (large files): `_apply_progressive` splits roots into *immediate* (viewport-visible, synchronous) and *deferred* (async via `vim.schedule` steps with a generation counter for cancellation). The viewport is cleared as a full range before re-rendering immediate roots; deferred roots are cleared per-root by `_progressive_step`.

Two namespaces: `ns_todos` (stable ID extmarks on the marker character, `right_gravity = false`) and `hl_ns` (all visual highlights including count indicator virt_text).

### Metadata (`lua/checkmate/metadata/`)
Pluggable tag system (date, due, priority, custom). Each tag type registers `on_add`/`on_remove` callbacks; metadata operations queue ops inside the transaction system.

## Key Invariants

- **`ns_todos` extmarks are never placed by highlights code** — they are owned by the parser and act as stable IDs that survive buffer edits.
- **`hl_ns` is cleared and redrawn on every highlighting pass** — never mutated incrementally.
- **Operations must not directly mutate buffer state**; they return `TextDiffHunk[]` and let `apply_diff` do the writing. Callbacks queue further ops via `add_op`.
- **`todo_map` keys are `ns_todos` extmark IDs** (integers), not row numbers. Row-based lookups use `get_todo_item_at_position`.
- **Debounce wraps every call in `vim.schedule_wrap`**, including the leading edge — `process_impl` is always deferred by at least one event loop tick.
