# Changelog

## [0.3.0](https://github.com/bngarren/checkmate.nvim/compare/v0.4.0...v0.3.0) (2025-05-04)


### ⚠ BREAKING CHANGES

* toggle_todo renamed to set_todo_item

### Features

* added metadata tags to todo items. These are customizable [@tag](https://github.com/tag)(value) snippets that can be keymapped and customized ([#7](https://github.com/bngarren/checkmate.nvim/issues/7)) ([296d83d](https://github.com/bngarren/checkmate.nvim/commit/296d83d64adc6dbef820ea48988731114e9ac720))
* added todo count indicator ([#10](https://github.com/bngarren/checkmate.nvim/issues/10)) ([ef0cece](https://github.com/bngarren/checkmate.nvim/commit/ef0cece5eed14eea92f13d316d5b54faf17167ca))
* **api:** adds a 'remove_all_metadata' function with default keymap and user command ([#28](https://github.com/bngarren/checkmate.nvim/issues/28)) ([a5950ef](https://github.com/bngarren/checkmate.nvim/commit/a5950ef85445df062848c678ff37c4fa564db613))


### Bug Fixes

* added apply highlighting calls to metadata functions ([0ca8c91](https://github.com/bngarren/checkmate.nvim/commit/0ca8c912d1fd42964833400dac6e7081f5ae04b2))
* added back missing autocmds from prev fix ([#15](https://github.com/bngarren/checkmate.nvim/issues/15)) ([4b56873](https://github.com/bngarren/checkmate.nvim/commit/4b56873ece732b7e788051a54fcdf93cbbbd3714))
* **api:** adjusted timing of metadata callbacks and improved tests ([#31](https://github.com/bngarren/checkmate.nvim/issues/31)) ([b68633d](https://github.com/bngarren/checkmate.nvim/commit/b68633d684c6a4e4e06262497d3ea9c2f55548c9))
* **api:** preserve cursor state during todo operations ([#32](https://github.com/bngarren/checkmate.nvim/issues/32)) ([882e0a7](https://github.com/bngarren/checkmate.nvim/commit/882e0a75557cc713918e0127fbb4bddd583a1fcd))
* **api:** suppress some notifications in visual mode ([#34](https://github.com/bngarren/checkmate.nvim/issues/34)) ([9e07329](https://github.com/bngarren/checkmate.nvim/commit/9e07329233673cda1d21def0ea1bfa2183137003))
* fixed bug where sometimes buffer was not being converted to markdown or conversion was faulty ([#14](https://github.com/bngarren/checkmate.nvim/issues/14)) ([31cdd14](https://github.com/bngarren/checkmate.nvim/commit/31cdd140f07cfd98d4314c5a6d59bb62f3353bde))
* fixes a off-by-one error in extract_metadata col indexing ([#17](https://github.com/bngarren/checkmate.nvim/issues/17)) ([e2de4c7](https://github.com/bngarren/checkmate.nvim/commit/e2de4c7d62e33c83a2d02801146c9a722096220f))
* **highlights:** fixed inconsistent highlighting of list item markers nested in a todo item ([296d83d](https://github.com/bngarren/checkmate.nvim/commit/296d83d64adc6dbef820ea48988731114e9ac720))
* missing check for nvim-treesitter before using TSBufDisable highlight ([#4](https://github.com/bngarren/checkmate.nvim/issues/4)) ([3d5e227](https://github.com/bngarren/checkmate.nvim/commit/3d5e227c6775e6f988ba793d6ba23d3c4e379694))


### Documentation

* updated README ([ef0cece](https://github.com/bngarren/checkmate.nvim/commit/ef0cece5eed14eea92f13d316d5b54faf17167ca))
* updated README. Added new example video ([296d83d](https://github.com/bngarren/checkmate.nvim/commit/296d83d64adc6dbef820ea48988731114e9ac720))


### Code Refactoring

* toggle_todo renamed to set_todo_item ([296d83d](https://github.com/bngarren/checkmate.nvim/commit/296d83d64adc6dbef820ea48988731114e9ac720))

## [0.4.0](https://github.com/bngarren/checkmate.nvim/compare/v0.3.3...v0.4.0) (2025-05-02)


### Features

* **api:** buf writes are now atomic to maintain data integrity with markdown conversion ([464f539](https://github.com/bngarren/checkmate.nvim/commit/464f539c6eba4e4ca0f38d6af2c0fb5dbba0cc07))
* **tests:** added proper testing with Busted. Decent coverage of parser, api, and config ([464f539](https://github.com/bngarren/checkmate.nvim/commit/464f539c6eba4e4ca0f38d6af2c0fb5dbba0cc07))


### Bug Fixes

* **api:** added notifications for toggles attempted at invalid locations ([464f539](https://github.com/bngarren/checkmate.nvim/commit/464f539c6eba4e4ca0f38d6af2c0fb5dbba0cc07))
* **log:** adjusted log module's log levels table to match vim's ([464f539](https://github.com/bngarren/checkmate.nvim/commit/464f539c6eba4e4ca0f38d6af2c0fb5dbba0cc07))

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
