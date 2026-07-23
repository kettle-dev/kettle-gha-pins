# frozen_string_literal: true

require "json"
require "net/http"
require "timeout"
require "uri"

module Kettle
  module Gha
    module Pins
      # Lightweight GitHub API client for commit and release SHA resolution.
      class GitHubClient
        def initialize(token:, api_base:, user_agent:, persistent_cache: nil, refresh_cache: false, open_timeout: DEFAULT_HTTP_OPEN_TIMEOUT_SECONDS, read_timeout: DEFAULT_HTTP_READ_TIMEOUT_SECONDS, refresh_timeout: DEFAULT_HTTP_REFRESH_TIMEOUT_SECONDS)
          @token = token
          @api_base = api_base
          @user_agent = user_agent
          @persistent_cache = persistent_cache
          @refresh_cache = refresh_cache
          @open_timeout = open_timeout
          @read_timeout = read_timeout
          @refresh_timeout = refresh_timeout
          @commit_cache = {}
          @release_cache = {}
        end

        def versions_for_repo(repo_ref)
          return [] if repo_ref.to_s.empty?
          return @release_cache[repo_ref] if @release_cache.key?(repo_ref)

          stale = nil
          unless @refresh_cache
            cached = @persistent_cache&.versions_for_repo(repo_ref, fresh: true)
            if cached
              @release_cache[repo_ref] = cached
              return cached
            end
            stale = @persistent_cache&.versions_for_repo(repo_ref, fresh: false)
          end

          releases = nil
          Timeout.timeout(@refresh_timeout) do
            data = request_json("/repos/#{repo_ref}/releases?per_page=100")
            return cached_versions(repo_ref, stale) unless data.is_a?(Array)

            tag_shas = tag_ref_shas(repo_ref)
            return cached_versions(repo_ref, stale) unless tag_shas

            releases = build_release_versions(data, tag_shas)
          end
          @persistent_cache&.write_versions(repo_ref, releases)
          @release_cache[repo_ref] = releases
          releases
        rescue Timeout::Error
          cached_versions(repo_ref, stale)
        end

        def commit_sha(repo_ref, ref)
          return nil if repo_ref.to_s.empty? || ref.to_s.empty?

          cache_key = "commit:#{repo_ref}:#{ref}"
          return @commit_cache[cache_key] if @commit_cache.key?(cache_key)

          unless @refresh_cache
            cached = @persistent_cache&.ref_sha(repo_ref, ref, fresh: true)
            if cached
              @commit_cache[cache_key] = cached
              return cached
            end
          end

          data = request_json("/repos/#{repo_ref}/commits/#{uri_encode(ref)}")
          sha = if data.is_a?(Hash)
            data.fetch("sha", "")[0, 40]
          end
          if sha.to_s.empty?
            sha = @persistent_cache&.ref_sha(repo_ref, ref, fresh: false)
          else
            @persistent_cache&.write_ref_sha(repo_ref, ref, sha)
          end
          @commit_cache[cache_key] = sha
          sha
        end

        def release_latest_sha(repo_ref)
          versions = versions_for_repo(repo_ref)
          latest = versions.first
          latest ? version_entry_sha(repo_ref, latest) : nil
        end

        private

        def cached_versions(repo_ref, stale)
          versions = stale || []
          @release_cache[repo_ref] = versions
          versions
        end

        def build_release_versions(data, tag_shas)
          release_tags = data.filter_map do |release|
            next unless release.is_a?(Hash)

            tag = release["tag_name"].to_s
            next unless VersionRubric.parse(tag)

            tag
          end

          VersionRubric.build_release_versions(
            release_tags: release_tags,
            tag_shas: tag_shas
          )
        end

        def tag_ref_shas(repo_ref)
          data = request_json("/repos/#{repo_ref}/git/matching-refs/tags/")
          return nil unless data.is_a?(Array)

          data.each_with_object({}) do |entry, memo|
            ref = entry["ref"].to_s
            next unless ref.start_with?("refs/tags/")

            tag = ref.sub(%r{\Arefs/tags/}, "")
            next unless VersionRubric.parse(tag)

            object = entry["object"]
            next unless object.is_a?(Hash)

            sha = object["sha"].to_s[0, 40]
            case object["type"]
            when "commit"
              memo[tag] = sha
            when "tag"
              memo[tag] = nil
            end
          end
        end

        def annotated_tag_commit_sha(repo_ref, tag_sha)
          return nil if tag_sha.to_s.empty?

          data = request_json("/repos/#{repo_ref}/git/tags/#{tag_sha}")
          return nil unless data.is_a?(Hash)

          object = data["object"]
          return nil unless object.is_a?(Hash)
          return nil unless object["type"] == "commit"

          object["sha"].to_s[0, 40]
        end

        def request_json(path, redirects: 3)
          uri = URI.join(@api_base + "/", path)

          response = nil
          loop do
            request = Net::HTTP::Get.new(uri)
            request["Accept"] = "application/vnd.github+json"
            request["User-Agent"] = @user_agent
            request["X-GitHub-Api-Version"] = "2022-11-28"
            request["Authorization"] = "Bearer #{@token}" if @token && !@token.empty?

            response = http_request(uri, request)

            break unless response.code.to_i.between?(300, 399)
            redirects -= 1
            return nil if redirects.negative?

            location = response["location"].to_s
            return nil if location.empty?

            uri = URI.join(uri.to_s, location)
          end

          return nil unless response.code.to_i == 200

          begin
            JSON.parse(response.body)
          rescue JSON::ParserError
            nil
          end
        rescue IOError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout
          nil
        end

        def http_request(uri, request)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          http.ssl_timeout = @open_timeout if http.respond_to?(:ssl_timeout=)
          http.start { |connection| connection.request(request) }
        end

        def uri_encode(value)
          URI.encode_www_form_component(value)
        end

        def version_entry_sha(repo_ref, entry)
          return nil unless entry
          return entry[:sha] unless entry[:sha].to_s.empty?

          entry[:sha] = commit_sha(repo_ref, entry[:tag])
        end
      end
    end
  end
end
