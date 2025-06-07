# Changelog

## [0.8.2](https://github.com/bngarren/checkmate.nvim/compare/v0.8.1...v0.8.2) (2025-06-07)


### Bug Fixes

* **highlights:** various fixes and improvements to highlights system ([#102](https://github.com/bngarren/checkmate.nvim/issues/102)) ([63d14f3](https://github.com/bngarren/checkmate.nvim/commit/63d14f3cd6666085e1392f0d679b34e83aea26fa))

## [0.8.1](https://github.com/bngarren/checkmate.nvim/compare/v0.8.0...v0.8.1) (2025-06-07)


### Bug Fixes

* **api:** converts buffer back to markdown on checkmate disable/shutdown ([#93](https://github.com/bngarren/checkmate.nvim/issues/93)) ([21a6560](https://github.com/bngarren/checkmate.nvim/commit/21a656096f50cfe62b84f2f22e7b882a8018524e))

## [0.8.0](https://github.com/bngarren/checkmate.nvim/compare/v0.7.1...v0.8.0) (2025-06-05)


### ⚠ BREAKING CHANGES

* improved 'create todo' functionality, allowing for new line insertion ([#80](https://github.com/bngarren/checkmate.nvim/issues/80))
* Improve file pattern matching to follow expected unix style glob pattern behavior ([#86](https://github.com/bngarren/checkmate.nvim/issues/86))

### Features

* **api:** added `newest_first` option to config.archive ([addbe4d](https://github.com/bngarren/checkmate.nvim/commit/addbe4d1d18b5c10dd9863f9ff6a7aee6cc9f8b2))
* Improve file pattern matching to follow expected unix style glob pattern behavior ([#86](https://github.com/bngarren/checkmate.nvim/issues/86)) ([062ae46](https://github.com/bngarren/checkmate.nvim/commit/062ae465e614dc89d095394bf1bb577af1cf2016))
* improved 'create todo' functionality, allowing for new line insertion ([#80](https://github.com/bngarren/checkmate.nvim/issues/80)) ([f827108](https://github.com/bngarren/checkmate.nvim/commit/f827108d20d7832bb6466252b6b659bc1f7dfa86))


### Bug Fixes

* **api:** fixes bug with incorrect spacing of remaining todos after archive ([f8cf100](https://github.com/bngarren/checkmate.nvim/commit/f8cf100fcec87260aff36e3dcbea445850f8c704))
* **config:** updates config validation to match current config options ([#71](https://github.com/bngarren/checkmate.nvim/issues/71)) ([0a6deab](https://github.com/bngarren/checkmate.nvim/commit/0a6deab40e0858dc0bd5d005e19c5769da179908))
* fixes [#81](https://github.com/bngarren/checkmate.nvim/issues/81) error with parsing markdown boxes at EOL ([#82](https://github.com/bngarren/checkmate.nvim/issues/82)) ([9e0cf89](https://github.com/bngarren/checkmate.nvim/commit/9e0cf89a5988cf39e5bed607884f5c5fbf3e3399))
* warn about multi-character todo markers rather than fail validation ([#87](https://github.com/bngarren/checkmate.nvim/issues/87)) ([6eb56d3](https://github.com/bngarren/checkmate.nvim/commit/6eb56d39c78c0202ad6043bdfc54f321b3b078fa))

## [0.7.1](https://github.com/bngarren/checkmate.nvim/compare/v0.7.0...v0.7.1) (2025-06-03)


### Bug Fixes

* **config:** fixes bug when validating metadata sort_order option ([#78](https://github.com/bngarren/checkmate.nvim/issues/78)) ([56ea7f7](https://github.com/bngarren/checkmate.nvim/commit/56ea7f7d3fdf6e3e886cf33aeebd3f02d514c5ad))

## [0.7.0](https://github.com/bngarren/checkmate.nvim/compare/v0.6.0...v0.7.0) (2025-05-31)


### ⚠ BREAKING CHANGES

* public api functions now return a boolean (success or failure) rather than a structured result type

### Features

* adds 'smart_toggle' feature, allowing for todo state propagation to children and parent ([#65](https://github.com/bngarren/checkmate.nvim/issues/65)) ([bdce5f5](https://github.com/bngarren/checkmate.nvim/commit/bdce5f54921d06faab9b04965e3fd43e9db65c4f))
* adds a new 'archive' functionality that allows reorganizing checked/completed todos to the bottom in a customizable section ([#59](https://github.com/bngarren/checkmate.nvim/issues/59)) ([e5d80be](https://github.com/bngarren/checkmate.nvim/commit/e5d80bed458a65bb53a0c014958c188de65f2d42))
* Major refactor to improve performance. Under the hood, now using extmarks for tracking todos, diff hunks and batch processing ([#62](https://github.com/bngarren/checkmate.nvim/issues/62)) ([7436333](https://github.com/bngarren/checkmate.nvim/commit/7436333cf577c0ea6c2720ffa9daea479b453236))


### Bug Fixes

* **api:** fixes bug with :wq command not exiting correctly ([#66](https://github.com/bngarren/checkmate.nvim/issues/66)) ([2c8b3a4](https://github.com/bngarren/checkmate.nvim/commit/2c8b3a41d3e86ae706bd97cc55d786425da6b69e))
* **highlights:** fixed a bug in which the wrong hl group is applied when inserting text at EOL or new lines ([#63](https://github.com/bngarren/checkmate.nvim/issues/63)) ([aba5528](https://github.com/bngarren/checkmate.nvim/commit/aba552861de391d4709429b51ac2ce483ff57c16))

## [0.6.0](https://github.com/bngarren/checkmate.nvim/compare/v0.5.1...v0.6.0) (2025-05-18)


### Features

* added 'color scheme aware' reasonable default styles. Can still override highlights via config.style ([#53](https://github.com/bngarren/checkmate.nvim/issues/53)) ([b57b88f](https://github.com/bngarren/checkmate.nvim/commit/b57b88f79cd99679fcd0c098b78d5132f9eb8b7c))
* **linter:** adds a 'verbose' field to config.linter (LinterConfig), default is false ([62e5f9b](https://github.com/bngarren/checkmate.nvim/commit/62e5f9b722900047e1b5880668c9cf45871bd8e2))


### Bug Fixes

* adjusted default style (additional content too dim) ([db10370](https://github.com/bngarren/checkmate.nvim/commit/db10370f243ee901c194658c441434bdcc24be7b))
* **linter:** fixes bug in inconsistent_markers rule ([5de7d3e](https://github.com/bngarren/checkmate.nvim/commit/5de7d3e8e5d0bc0bee1a8d7c3dd0f485b0799c1e))
* **linter:** fixes linter impl that didn't follow CommonMark exactly. Refactored for easier future additions. ([#56](https://github.com/bngarren/checkmate.nvim/issues/56)) ([62e5f9b](https://github.com/bngarren/checkmate.nvim/commit/62e5f9b722900047e1b5880668c9cf45871bd8e2))
* **parser:** adjusted markdown checkbox parsing to align with commonmark spec ([f3bfadf](https://github.com/bngarren/checkmate.nvim/commit/f3bfadf8bfd804626a7e1e2dee118e8ff1d5602a))
* remove code related to deprecated .todo extension requirement ([977fee1](https://github.com/bngarren/checkmate.nvim/commit/977fee1ca5518fbf369c2a1ee62c139ced492596))


### Miscellaneous Chores

* release as 0.6.0 ([03d22af](https://github.com/bngarren/checkmate.nvim/commit/03d22af626ac24329d94982e5960d520bcba1198))

## [0.5.1](https://github.com/bngarren/checkmate.nvim/compare/v0.5.0...v0.5.1) (2025-05-16)


### Bug Fixes

* **parser:** fixed off-by-one error in metadata parsing, leading to highlighting bug ([#51](https://github.com/bngarren/checkmate.nvim/issues/51)) ([436092e](https://github.com/bngarren/checkmate.nvim/commit/436092ed88d46de54d6c583a93bd483eb170617e))

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
