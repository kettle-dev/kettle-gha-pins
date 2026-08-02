# Changelog

[![SemVer 2.0.0][📌semver-img]][📌semver] [![Keep-A-Changelog 1.0.0][📗keep-changelog-img]][📗keep-changelog]

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog][📗keep-changelog],
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html),
and [yes][📌major-versions-not-sacred], platform and engine support are part of the [public API][📌semver-breaking].
Please file a bug if you notice a violation of semantic versioning.

[📌semver]: https://semver.org/spec/v2.0.0.html
[📌semver-img]: https://img.shields.io/badge/semver-2.0.0-FFDD67.svg?style=flat
[📌semver-breaking]: https://github.com/semver/semver/issues/716#issuecomment-869336139
[📌major-versions-not-sacred]: https://tom.preston-werner.com/2022/05/23/major-version-numbers-are-not-sacred.html
[📗keep-changelog]: https://keepachangelog.com/en/1.0.0/
[📗keep-changelog-img]: https://img.shields.io/badge/keep--a--changelog-1.0.0-FFDD67.svg?style=flat

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

- kettle-jem-template-20260802-001 - Devcontainer JSON files now merge as JSONC,
  preserving comments and trailing commas during template updates.

### Security

## [0.3.5] - 2026-08-01

- TAG: [v0.3.5][0.3.5t]
- COVERAGE: 98.94% -- 935/945 lines in 8 files
- BRANCH COVERAGE: 90.91% -- 380/418 branches in 8 files
- 24.04% documented

### Changed

- kettle-jem-template-20260801-001 - Generated README gem dashboard links now
  use ClickGems instead of BestGems.

### Fixed

- kettle-jem-template-20260801-002 - Generated RSpec helpers now normalize
  managed configuration block bindings structurally, preventing mixed block
  parameter names from producing invalid configuration after a merge.
- kettle-jem-template-20260801-003 - Generated project metadata and
  documentation now normalize configured underscore hostnames to valid
  hyphenated hostnames.
- kettle-jem-template-20260801-004 - Generated organization README logos now
  use GitHub's stable organization avatar endpoint instead of assuming a
  matching Galtzo-hosted asset exists.

## [0.3.4] - 2026-07-30

- TAG: [v0.3.4][0.3.4t]
- COVERAGE: 98.94% -- 935/945 lines in 8 files
- BRANCH COVERAGE: 90.91% -- 380/418 branches in 8 files
- 24.04% documented

### Added

### Fixed

- kettle-jem-template-20260728-003 - Generated dep-heads workflows now run
  TruffleRuby jobs with current RubyGems and Bundler, avoiding setup failures
  before the test suite starts.
- kettle-jem-template-20260728-004 - Generated dep-heads workflows now use the
  setup-ruby Bundler install path for direct appraisal Gemfiles, avoiding rv
  lockfile parser failures on Git and path dependencies.
- kettle-jem-template-20260728-005 - VersionGem bootstrap now creates the
  missing canonical version spec when a project only has shim namespace version
  specs.
- kettle-jem-template-20260729-001 - Generated JRuby 9.4 workflows now use the
  legacy manual bundle install path, avoiding setup-time Bundler full-index
  failures against `gem.coop`.
- kettle-jem-template-20260730-001 - Gemspec package file enumeration now runs
  relative to the gemspec directory, so release package contents stay correct
  even when the gemspec is loaded from another working directory.

## [0.3.3] - 2026-07-28

- TAG: [v0.3.3][0.3.3t]
- COVERAGE: 98.94% -- 935/945 lines in 8 files
- BRANCH COVERAGE: 90.91% -- 380/418 branches in 8 files
- 24.04% documented

### Fixed

- Version comment normalization now rewrites equivalent comments to a real
  action tag, preferring the most specific version spelling when both equivalent
  tags exist.
- Two-segment version comments like `v2.0` are now parsed when deciding whether
  an adjacent SHA-pin comment needs normalization.

## [0.3.2] - 2026-07-27

- TAG: [v0.3.2][0.3.2t]
- COVERAGE: 98.92% -- 915/925 lines in 8 files
- BRANCH COVERAGE: 90.93% -- 371/408 branches in 8 files
- 24.75% documented

### Added

- kettle-jem-template-20260726-001 - Projects now include YARD lint
  configuration and documentation dependencies so documentation issues fail
  before generated docs are refreshed.

- kettle-jem-template-20260727-001 - Spec harness documentation now lists the
  RSpec helpers provided by `kettle-test`.

### Changed

- The `kettle-gha-pins` executable startup header is now shown only when
  `--verbose` is passed; `-v` and `--version` still print just the executable
  version and exit.

- kettle-jem-template-20260725-001 - Release pull request branches beginning
  with `feature/release` now run JRuby and TruffleRuby workflows.
- kettle-jem-template-20260725-002 - Version specs now use `anonymous_loader` to
  cover `version.rb` without redefining constants, or are removed when version
  specs are not managed for the project.

- kettle-jem-template-20260728-001 - Generated Ruby workflows now use clearer
  setup-ruby-flash planning and can prepare appraisal-only jobs without
  installing the main Gemfile bundle.

### Fixed

- Two-segment GitHub Action releases like `v2.0` are now recognized as
  versioned action tags, so SHA pin updaters do not collapse them to evergreen
  major tags like `v2`.
- kettle-jem-template-20260726-002 - Generated version files now document their
  version namespace and constants, reducing warning-only YARD lint output.

- kettle-jem-template-20260726-003 - Coverage upload steps now treat Coveralls,
  QLTY, and Codecov as optional, so provider outages do not fail CI when local
  coverage thresholds still pass.
- kettle-jem-template-20260728-002 - Generated RuboCop configs now ignore the
  same `gemfiles/vendor/bundle` tree as `.gitignore`, so vendored dependency
  installs are not reported as project lint debt.

## [0.3.1] - 2026-07-23

- TAG: [v0.3.1][0.3.1t]
- COVERAGE: 98.92% -- 915/925 lines in 8 files
- BRANCH COVERAGE: 90.93% -- 371/408 branches in 8 files
- 22.77% documented

### Changed

- The `kettle-gha-pins` executable now supports `-v` / `--version` and prints a
  standard startup header on normal runs.

### Fixed

- The `kettle-gha-pins` executable now uses normal `require` loading for its
  version file, avoiding stale RuboCop Gradual baselines for `require_relative`
  in shipped executables.

## [0.3.0] - 2026-07-23

- TAG: [v0.3.0][0.3.0t]
- COVERAGE: 98.92% -- 915/925 lines in 8 files
- BRANCH COVERAGE: 90.93% -- 371/408 branches in 8 files
- 22.77% documented

### Changed

- `kettle-gha-pins` now defaults `--upgrade` to `major`, making
  `kettle-gha-pins --check` fail for any unapplied GitHub Actions pin update
  unless callers choose a narrower upgrade level.
- `kettle-gha-pins --check` now supports `--cooldown-days` and
  `KETTLE_GHA_PINS_COOLDOWN_DAYS` so projects can warn on freshly released
  action version upgrades before enforcing them.

- Action-resolution progress now uses `tty-progressbar` multi-line bars so
  cached, live, and skipped counters no longer overwrite each other on TTYs.

### Fixed

- GitHub Actions pin cache writes now persist tag SHA refs from release version
  metadata, so repeated runs can reuse cached action resolution instead of
  rechecking freshly cached actions live.

## [0.2.1] - 2026-07-22

- TAG: [v0.2.1][0.2.1t]
- COVERAGE: 99.08% -- 858/866 lines in 8 files
- BRANCH COVERAGE: 92.11% -- 350/380 branches in 8 files
- 22.22% documented

### Fixed

- Lowered the generated gemspec Ruby requirement to `>= 2.4.0` to match
  `kettle-dev`, restored Ruby 2.4-compatible runtime syntax, and explicitly
  required the `set` stdlib used by the CLI.
- Made CLI line rewrites tolerate Psych scalar column differences across Ruby
  versions.

## [0.2.0] - 2026-07-22

- TAG: [v0.2.0][0.2.0t]
- COVERAGE: 99.07% -- 849/857 lines in 8 files
- BRANCH COVERAGE: 92.55% -- 348/376 branches in 8 files
- 22.22% documented

### Added

- Added the shared `PersistentActionCache`, `GitHubClient`, and action ref
  resolver API so GitHub Actions pin tools can reuse cache, network, and upgrade
  planning behavior without shelling out to each other.
- Added the `kettle-gha-pins` executable for scanning standard GitHub Actions
  workflow YAML files and updating action refs to immutable SHAs.

## [0.1.0] - 2026-07-22

- TAG: [v0.1.0][0.1.0t]
- COVERAGE: 97.65% -- 83/85 lines in 3 files
- BRANCH COVERAGE: 88.89% -- 24/27 branches in 3 files
- 20.83% documented
- Initial release

### Added

- Added `Kettle::Gha::Pins::VersionRubric` as the shared version parsing,
  canonicalization, and upgrade-target selection API for GitHub Actions pin
  maintenance.

### Changed

- kettle-jem-template-20260716-002 - Generated gemspec manifests now ship fewer
  repository-only files by default to reduce downstream distro packaging churn.
- kettle-jem-template-20260720-002 - Generated development Gemfiles now use the
  released `tree_sitter_language_pack` gem 1.13.3 or newer by default.
- kettle-jem-template-20260720-003 - Generated StructuredMerge Git diff driver
  config now uses the installed `smorg-rb` Ruby driver name.
- kettle-jem-template-20260720-005 - Generated README Support & Community rows
  now include a RubyForum help badge.

[Unreleased]: https://github.com/kettle-dev/kettle-gha-pins/compare/v0.3.5...HEAD
[0.3.5]: https://github.com/kettle-dev/kettle-gha-pins/compare/v0.3.4...v0.3.5
[0.3.5t]: https://github.com/kettle-dev/kettle-gha-pins/releases/tag/v0.3.5
[0.3.4]: https://github.com/kettle-dev/kettle-gha-pins/compare/v0.3.3...v0.3.4
[0.3.4t]: https://github.com/kettle-dev/kettle-gha-pins/releases/tag/v0.3.4
[0.3.3]: https://github.com/kettle-dev/kettle-gha-pins/compare/v0.3.2...v0.3.3
[0.3.3t]: https://github.com/kettle-dev/kettle-gha-pins/releases/tag/v0.3.3
[0.3.2]: https://github.com/kettle-dev/kettle-gha-pins/compare/v0.3.1...v0.3.2
[0.3.2t]: https://github.com/kettle-dev/kettle-gha-pins/releases/tag/v0.3.2
[0.3.1]: https://github.com/kettle-dev/kettle-gha-pins/compare/v0.3.0...v0.3.1
[0.3.1t]: https://github.com/kettle-dev/kettle-gha-pins/releases/tag/v0.3.1
[0.3.0]: https://github.com/kettle-dev/kettle-gha-pins/compare/v0.2.1...v0.3.0
[0.3.0t]: https://github.com/kettle-dev/kettle-gha-pins/releases/tag/v0.3.0
[0.2.1]: https://github.com/kettle-dev/kettle-gha-pins/compare/v0.2.0...v0.2.1
[0.2.1t]: https://github.com/kettle-dev/kettle-gha-pins/releases/tag/v0.2.1
[0.2.0]: https://github.com/kettle-dev/kettle-gha-pins/compare/v0.1.0...v0.2.0
[0.2.0t]: https://github.com/kettle-dev/kettle-gha-pins/releases/tag/v0.2.0
[0.1.0]: https://github.com/kettle-dev/kettle-gha-pins/compare/c633526495c7db0a8721a94a71c3def0f3cc71bb...v0.1.0
[0.1.0t]: https://github.com/kettle-dev/kettle-gha-pins/releases/tag/v0.1.0
