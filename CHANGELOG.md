# Changelog

## [0.5.0](https://github.com/bngarren/checkmate.nvim/compare/v0.4.0...v0.5.0) (2025-05-15)


### ⚠ BREAKING CHANGES

* **core:** The plugin no longer auto-loads only `.todo` files; activation now follows the `files` pattern. E.g. the plugin will lazy load for 'markdown' filetype whose filename matches a pattern in the 'files' config option

### Features

* **api:** adds 'jump_to_on_insert' and 'select_on_insert' options to metadata props ([#39](https://github.com/bngarren/checkmate.nvim/issues/39)) ([2772fd4](https://github.com/bngarren/checkmate.nvim/commit/2772fd4fafc3146324e9199ed6a450d709eb3eb1))
* **core:** improved TS parsing, new custom Markdown linter, more flexible plugin activation, performance improvements, bug fixes ([#42](https://github.com/bngarren/checkmate.nvim/issues/42)) ([f782b8a](https://github.com/bngarren/checkmate.nvim/commit/f782b8a821d330209ca5909a924e63baeb112bd2))


### Bug Fixes

* **api:** removed extra apply_highlighting call that was causing perf lag ([#48](https://github.com/bngarren/checkmate.nvim/issues/48)) ([6ae49bf](https://github.com/bngarren/checkmate.nvim/commit/6ae49bfdee044b936f7178ef442e463b45e2e6e0))
* **config:** clears the line cache in highlights when closing with each buffer ([#38](https://github.com/bngarren/checkmate.nvim/issues/38)) ([fc1bab8](https://github.com/bngarren/checkmate.nvim/commit/fc1bab8b92f4a2305ca7fea023ae795ff54b078b))
* **config:** linter is enabled by default ([3575222](https://github.com/bngarren/checkmate.nvim/commit/3575222a16d1f60b41529d902480a9ab745fc710))
* default notify to only once and limit hit-enter prompts ([#45](https://github.com/bngarren/checkmate.nvim/issues/45)) ([d1a0449](https://github.com/bngarren/checkmate.nvim/commit/d1a0449f669f44626155095d2d684dc935d0e0a0))
* **parser:** critical bug fixed in parser related to TS handling of end col and 0-based indexing ([#41](https://github.com/bngarren/checkmate.nvim/issues/41)) ([cef93fb](https://github.com/bngarren/checkmate.nvim/commit/cef93fbd692240403b7b44e2418e78c2c6cae331))
* removes nvim_echo from notify as this was causing poor user experience when notify was disabled ([#43](https://github.com/bngarren/checkmate.nvim/issues/43)) ([9ec79fd](https://github.com/bngarren/checkmate.nvim/commit/9ec79fd0d9420c221d6dbc215f8a57beb2183d06))


### Performance Improvements

* added a profiler (disabled by default) to help identify performance bottlenecks ([#47](https://github.com/bngarren/checkmate.nvim/issues/47)) ([bca1176](https://github.com/bngarren/checkmate.nvim/commit/bca1176ccdfd90d4bd3717b318210610680cb56b))
* **api:** combine TextChanged and InsertLeave handling into single process_buffer function with debouncing ([9a5a33d](https://github.com/bngarren/checkmate.nvim/commit/9a5a33d0f4d9b3dfb58707998b556e0ee5143cd8))

## [0.4.0](https://github.com/bngarren/checkmate.nvim/compare/v0.3.3...v0.4.0) (2025-05-04)


### Features

* **api:** adds a 'remove_all_metadata' function with default keymap and user command ([#28](https://github.com/bngarren/checkmate.nvim/issues/28)) ([a5950ef](https://github.com/bngarren/checkmate.nvim/commit/a5950ef85445df062848c678ff37c4fa564db613))


### Bug Fixes

* **api:** adjusted timing of metadata callbacks and improved tests ([#31](https://github.com/bngarren/checkmate.nvim/issues/31)) ([b68633d](https://github.com/bngarren/checkmate.nvim/commit/b68633d684c6a4e4e06262497d3ea9c2f55548c9))
* **api:** preserve cursor state during todo operations ([#32](https://github.com/bngarren/checkmate.nvim/issues/32)) ([882e0a7](https://github.com/bngarren/checkmate.nvim/commit/882e0a75557cc713918e0127fbb4bddd583a1fcd))
* **api:** suppress some notifications in visual mode ([#34](https://github.com/bngarren/checkmate.nvim/issues/34)) ([9e07329](https://github.com/bngarren/checkmate.nvim/commit/9e07329233673cda1d21def0ea1bfa2183137003))


### Miscellaneous Chores

* fix release-please manifest ([09d6a0f](https://github.com/bngarren/checkmate.nvim/commit/09d6a0f9ae9b0efc468b534b2c8bdadaf214755b))

## [0.3.3](https://github.com/bngarren/checkmate.nvim/compare/v0.3.2...v0.3.3) (2025-05-01)


### Bug Fixes

* fixes a off-by-one error in extract_metadata col indexing ([#17](https://github.com/bngarren/checkmate.nvim/issues/17)) ([e2de4c7](https://github.com/bngarren/checkmate.nvim/commit/e2de4c7d62e33c83a2d02801146c9a722096220f))

## [0.3.2](https://github.com/bngarren/checkmate.nvim/compare/v0.3.1...v0.3.2) (2025-04-30)


### Bug Fixes

* added back missing autocmds from prev fix ([#15](https://github.com/bngarren/checkmate.nvim/issues/15)) ([4b56873](https://github.com/bngarren/checkmate.nvim/commit/4b56873ece732b7e788051a54fcdf93cbbbd3714))

## [0.3.1](https://github.com/bngarren/checkmate.nvim/compare/v0.3.0...v0.3.1) (2025-04-30)


### Bug Fixes

* added apply highlighting calls to metadata functions ([0ca8c91](https://github.com/bngarren/checkmate.nvim/commit/0ca8c912d1fd42964833400dac6e7081f5ae04b2))
* fixed bug where sometimes buffer was not being converted to markdown or conversion was faulty ([#14](https://github.com/bngarren/checkmate.nvim/issues/14)) ([31cdd14](https://github.com/bngarren/checkmate.nvim/commit/31cdd140f07cfd98d4314c5a6d59bb62f3353bde))

## [0.3.0](https://github.com/bngarren/checkmate.nvim/compare/v0.2.0...v0.3.0) (2025-04-29)


### Features

* added todo count indicator ([#10](https://github.com/bngarren/checkmate.nvim/issues/10)) ([ef0cece](https://github.com/bngarren/checkmate.nvim/commit/ef0cece5eed14eea92f13d316d5b54faf17167ca))


### Documentation

* updated README ([ef0cece](https://github.com/bngarren/checkmate.nvim/commit/ef0cece5eed14eea92f13d316d5b54faf17167ca))

## [0.2.0](https://github.com/bngarren/checkmate.nvim/compare/v0.1.1...v0.2.0) (2025-04-29)


### ⚠ BREAKING CHANGES

* toggle_todo renamed to set_todo_item

### Features

* added metadata tags to todo items. These are customizable [@tag](https://github.com/tag)(value) snippets that can be keymapped and customized ([#7](https://github.com/bngarren/checkmate.nvim/issues/7)) ([296d83d](https://github.com/bngarren/checkmate.nvim/commit/296d83d64adc6dbef820ea48988731114e9ac720))


### Bug Fixes

* **highlights:** fixed inconsistent highlighting of list item markers nested in a todo item ([296d83d](https://github.com/bngarren/checkmate.nvim/commit/296d83d64adc6dbef820ea48988731114e9ac720))


### Documentation

* updated README. Added new example video ([296d83d](https://github.com/bngarren/checkmate.nvim/commit/296d83d64adc6dbef820ea48988731114e9ac720))


### Code Refactoring

* toggle_todo renamed to set_todo_item ([296d83d](https://github.com/bngarren/checkmate.nvim/commit/296d83d64adc6dbef820ea48988731114e9ac720))

## [0.1.1](https://github.com/bngarren/checkmate.nvim/compare/v0.1.0...v0.1.1) (2025-04-19)


### Bug Fixes

* missing check for nvim-treesitter before using TSBufDisable highlight ([#4](https://github.com/bngarren/checkmate.nvim/issues/4)) ([3d5e227](https://github.com/bngarren/checkmate.nvim/commit/3d5e227c6775e6f988ba793d6ba23d3c4e379694))
