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

- `kettle-gha-pins` now defaults `--upgrade` to `major`, making
  `kettle-gha-pins --check` fail for any unapplied GitHub Actions pin update
  unless callers choose a narrower upgrade level.
- `kettle-gha-pins --check` now supports `--cooldown-days` and
  `KETTLE_GHA_PINS_COOLDOWN_DAYS` so projects can warn on freshly released
  action version upgrades before enforcing them.

### Deprecated

### Removed

### Fixed

### Security

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

- kettle-jem-template-20260716-001 - Shim gemspec manifests now include
  `LICENSE.md` instead of nonexistent `LICENSE.txt`.
- kettle-jem-template-20260716-002 - Generated gemspec manifests now ship fewer
  repository-only files by default to reduce downstream distro packaging churn.
- kettle-jem-template-20260720-001 - Generated READMEs can now render
  template-managed corporate sponsor logos from project or family config.
- kettle-jem-template-20260720-002 - Generated development Gemfiles now use the
  released `tree_sitter_language_pack` gem 1.13.3 or newer by default.
- kettle-jem-template-20260720-003 - Generated StructuredMerge Git diff driver
  config now uses the installed `smorg-rb` Ruby driver name.
- kettle-jem-template-20260720-004 - Generated multi-engine workflow files now
  omit JRuby and TruffleRuby jobs when project config declares MRI-only engines.
- kettle-jem-template-20260720-005 - Generated README Support & Community rows
  now include a RubyForum help badge.

[Unreleased]: https://github.com/kettle-dev/kettle-gha-pins/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/kettle-dev/kettle-gha-pins/compare/v0.2.0...v0.2.1
[0.2.1t]: https://github.com/kettle-dev/kettle-gha-pins/releases/tag/v0.2.1
[0.2.0]: https://github.com/kettle-dev/kettle-gha-pins/compare/v0.1.0...v0.2.0
[0.2.0t]: https://github.com/kettle-dev/kettle-gha-pins/releases/tag/v0.2.0
[0.1.0]: https://github.com/kettle-dev/kettle-gha-pins/compare/c633526495c7db0a8721a94a71c3def0f3cc71bb...v0.1.0
[0.1.0t]: https://github.com/kettle-dev/kettle-gha-pins/releases/tag/v0.1.0
