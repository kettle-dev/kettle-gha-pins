# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Kettle
  module Gha
    module Pins
      # Persistent cache of GitHub Action release versions and target SHAs.
      class PersistentActionCache
        VERSION = 3

        def self.default_path
          state_home = ENV["XDG_STATE_HOME"]
          state_home = File.join(Dir.home, ".local", "state") if state_home.to_s.empty?
          File.join(state_home, "kettle-dev", "gha-sha-pins-cache.json")
        rescue ArgumentError
          nil
        end

        def initialize(path:, ttl_seconds: DEFAULT_CACHE_TTL_SECONDS, clock: -> { Time.now })
          @path = path
          @ttl_seconds = ttl_seconds
          @clock = clock
          @data = nil
        end

        def versions_for_repo(repo_ref, fresh: true)
          action = action_data(repo_ref)
          return nil unless action

          versions = action.fetch("versions", {}).values
          return nil if versions.empty?

          entries = if fresh
            versions.select { |entry| fresh_entry?(entry) }
          else
            versions
          end
          return nil if entries.empty?
          return nil if fresh && entries.length != versions.length

          entries.each_with_object([]) do |entry, memo|
            deserialized = deserialize_version_entry(entry)
            memo << deserialized if deserialized
          end
            .sort_by { |entry| VersionRubric.sort_key(entry) }
            .reverse
        end

        def write_versions(repo_ref, versions)
          return if @path.to_s.empty?
          return if repo_ref.to_s.empty?

          action = data.fetch("actions")[repo_ref] ||= {}
          stored_versions = action["versions"] ||= {}
          timestamp = @clock.call.utc.iso8601

          versions.each do |entry|
            version = entry[:version].to_s
            next if version.empty?

            stored_versions[version] = {
              "tag" => entry[:tag].to_s,
              "version" => version,
              "sha" => entry[:sha].to_s,
              "released_at" => entry[:released_at].to_s,
              "cached_at" => timestamp
            }
          end

          action["targets"] = target_cache(stored_versions.values)
          save!
        end

        def ref_sha(repo_ref, ref, fresh: true)
          action = action_data(repo_ref)
          return nil unless action

          refs = action.fetch("refs", {})
          entry = refs[ref.to_s]
          return nil unless entry
          return nil if fresh && !fresh_entry?(entry)

          sha = entry["sha"].to_s
          sha.empty? ? nil : sha
        end

        def write_ref_sha(repo_ref, ref, sha)
          return if @path.to_s.empty?
          return if repo_ref.to_s.empty? || ref.to_s.empty? || sha.to_s.empty?

          action = data.fetch("actions")[repo_ref] ||= {}
          refs = action["refs"] ||= {}
          refs[ref.to_s] = {
            "sha" => sha.to_s[0, 40],
            "cached_at" => @clock.call.utc.iso8601
          }
          save!
        end

        def to_h
          data
        end

        private

        def data
          @data ||= load_data
        end

        def action_data(repo_ref)
          data.fetch("actions")[repo_ref]
        end

        def load_data
          parsed = if @path && File.file?(@path)
            JSON.parse(File.read(@path))
          end
          return empty_data unless parsed.is_a?(Hash)
          return empty_data unless parsed["version"].to_i == VERSION

          parsed["version"] ||= VERSION
          parsed["actions"] = {} unless parsed["actions"].is_a?(Hash)
          parsed
        rescue JSON::ParserError, Errno::EACCES
          empty_data
        end

        def empty_data
          {"version" => VERSION, "actions" => {}}
        end

        def save!
          FileUtils.mkdir_p(File.dirname(@path))
          File.write(@path, JSON.pretty_generate(data) + "\n")
        end

        def deserialize_version_entry(entry)
          version = entry["version"].to_s
          parsed = VersionRubric.parse(version)
          return nil unless parsed

          {
            tag: entry["tag"].to_s,
            version_obj: parsed,
            version: version,
            sha: entry["sha"].to_s,
            released_at: entry["released_at"].to_s
          }
        end

        def target_cache(version_entries)
          entries = version_entries.each_with_object([]) do |entry, memo|
            deserialized = deserialize_version_entry(entry)
            next unless deserialized

            memo << deserialized.merge(cached_at: entry["cached_at"].to_s)
          end
          return {} if entries.empty?

          full_semver_entries = entries.reject { |entry| VersionRubric.major_line?(entry[:version]) }
          {
            "patch" => full_semver_entries.group_by { |entry| entry[:version_obj].segments[0, 2].join(".") }
              .transform_values { |group| serialize_target(group.max_by { |entry| VersionRubric.sort_key(entry) }) },
            "minor" => full_semver_entries.group_by { |entry| entry[:version_obj].segments[0].to_s }
              .transform_values { |group| serialize_target(group.max_by { |entry| VersionRubric.sort_key(entry) }) },
            "major" => {"*" => serialize_target(entries.max_by { |entry| VersionRubric.sort_key(entry) })}
          }
        end

        def serialize_target(entry)
          {
            "tag" => entry[:tag],
            "version" => entry[:version],
            "sha" => entry[:sha],
            "released_at" => entry[:released_at],
            "cached_at" => entry[:cached_at]
          }
        end

        def fresh_entry?(entry)
          cached_at = Time.iso8601(entry["cached_at"].to_s)
          cached_at >= @clock.call - @ttl_seconds
        rescue ArgumentError
          false
        end
      end
    end
  end
end
