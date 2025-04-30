# Changelog

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
