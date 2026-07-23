# frozen_string_literal: true

module Kettle
  module Gha
    module Pins
      # Shared version ordering and upgrade selection rules for GitHub Action pins.
      module VersionRubric
        VALID_UPGRADE_LEVELS = %w[major minor patch].freeze
        DEFAULT_UPGRADE_LEVEL = "major"
        RELEASE_TAG_RE = /\A(?:\d+|\d+\.\d+\.\d+(?:[-.]?[0-9A-Za-z.-]+)?)\z/

        module_function

        def parse(value)
          normalized = value.to_s.sub(/\A[vV]/, "")
          return nil unless normalized.match?(RELEASE_TAG_RE)

          Gem::Version.new(normalized)
        rescue ArgumentError
          nil
        end

        def major_line?(value)
          value.to_s.match?(/\A\d+\z/)
        end

        def entry(tag:, sha: nil, released_at: nil)
          version_obj = parse(tag)
          return nil unless version_obj

          {
            tag: tag.to_s,
            version_obj: version_obj,
            version: version_obj.to_s,
            sha: sha,
            released_at: released_at.to_s
          }
        end

        def build_release_versions(release_tags:, tag_shas:, release_dates: {})
          released_tags = release_tags.each_with_object({}) { |tag, memo| memo[tag.to_s] = true }
          releases = release_tags.each_with_object([]) do |tag, memo|
            release_entry = entry(tag: tag, sha: tag_shas[tag.to_s], released_at: release_dates[tag.to_s])
            memo << release_entry if release_entry
          end
          tag_versions = tag_shas.each_with_object([]) do |(tag, sha), memo|
            next if released_tags[tag.to_s]

            tag_entry = entry(tag: tag, sha: sha)
            memo << tag_entry if tag_entry
          end

          sort_versions(canonicalize_equivalent_release_versions(releases + tag_versions)).reverse
        end

        def canonicalize_equivalent_release_versions(releases)
          releases.each_with_object([]) do |release, groups|
            group = groups.find { |entries| equivalent_release_tag?(entries.first, release) }
            group ? group << release : groups << [release]
          end.map { |entries| entries.max_by { |entry| sort_key(entry) } }
        end

        def sort_versions(versions)
          versions.sort_by { |entry| sort_key(entry) }
        end

        def sort_key(entry)
          [entry.fetch(:version_obj), *specificity(entry)]
        end

        def specificity(entry)
          text = entry.fetch(:tag).to_s.sub(/\A[vV]/, "")
          release_text, suffix = text.split(/[-.](?=[A-Za-z])/, 2)
          numeric_segments = release_text.to_s.split(".").take_while { |part| part.match?(/\A\d+\z/) }

          [
            numeric_segments.length,
            suffix ? 0 : 1,
            text.length,
            entry.fetch(:tag).to_s
          ]
        end

        def choose_upgrade_target(current_version, versions, level)
          normalized_level = normalize_upgrade_level(level)
          current = parse(current_version)
          return nil if current.nil?
          return nil if normalized_level != "major" && major_line?(current_version)

          versions.select do |entry|
            entry.fetch(:version_obj, nil).is_a?(Gem::Version) &&
              entry.fetch(:version_obj) > current &&
              (!entry.fetch(:version_obj).prerelease? || current.prerelease?) &&
              allowed_by_level?(current_version, current, entry, normalized_level)
          end.max_by { |entry| sort_key(entry) }
        end

        def latest_outdated_target(current_version, versions)
          current = parse(current_version)
          return nil if current.nil?

          versions.select do |entry|
            entry.fetch(:version_obj, nil).is_a?(Gem::Version) &&
              entry.fetch(:version_obj) > current &&
              (!entry.fetch(:version_obj).prerelease? || current.prerelease?)
          end.max_by { |entry| sort_key(entry) }
        end

        def normalize_upgrade_level(level)
          normalized = level.to_s.downcase
          VALID_UPGRADE_LEVELS.include?(normalized) ? normalized : DEFAULT_UPGRADE_LEVEL
        end

        def equivalent_release_tag?(left, right)
          left[:version_obj] == right[:version_obj] &&
            left[:sha] &&
            right[:sha] &&
            left[:sha] == right[:sha]
        end

        def allowed_by_level?(current_version, current, entry, level)
          return true if level == "major"
          return false if major_line?(entry.fetch(:version))
          return false if major_line?(current_version)

          case level
          when "patch"
            entry.fetch(:version_obj).segments[0, 2] == current.segments[0, 2]
          when "minor"
            entry.fetch(:version_obj).segments[0] == current.segments[0]
          else
            true
          end
        end
      end
    end
  end
end
