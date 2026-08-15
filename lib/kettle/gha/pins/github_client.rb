# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "timeout"
require "uri"

module Kettle
  module Gha
    module Pins
      # Lightweight GitHub API client for commit and release SHA resolution.
      class GitHubClient
        ANNOTATED_TAG_GIT_FALLBACK_THRESHOLD = 4
        HTTP_RETRY_LIMIT = 2
        RETRYABLE_HTTP_STATUS_CODES = [408, 425, 429, 500, 502, 503, 504].freeze
        class CacheMissError < Error; end
        class RefreshError < Error; end

        def initialize(token:, api_base:, user_agent:, persistent_cache: nil, refresh_cache: false, offline: false, fail_on_refresh_error: false, open_timeout: DEFAULT_HTTP_OPEN_TIMEOUT_SECONDS, read_timeout: DEFAULT_HTTP_READ_TIMEOUT_SECONDS, refresh_timeout: DEFAULT_HTTP_REFRESH_TIMEOUT_SECONDS)
          @token = token
          @api_base = api_base
          @user_agent = user_agent
          @persistent_cache = persistent_cache
          @refresh_cache = refresh_cache
          @offline = offline
          @fail_on_refresh_error = fail_on_refresh_error
          @open_timeout = open_timeout
          @read_timeout = read_timeout
          @refresh_timeout = refresh_timeout
          @commit_cache = {}
          @release_cache = {}
          @last_versions_cache_hit = false
          @last_request_error = nil
        end

        attr_reader :last_request_error, :last_versions_cache_hit

        def versions_for_repo(repo_ref)
          @last_versions_cache_hit = false
          return [] if repo_ref.to_s.empty?
          if @release_cache.key?(repo_ref)
            @last_versions_cache_hit = true
            return @release_cache[repo_ref]
          end

          if @offline
            cached = @persistent_cache&.versions_for_repo(repo_ref, fresh: false)
            raise CacheMissError, "offline cache miss for #{repo_ref}" if cached.nil?

            @last_versions_cache_hit = true
            @release_cache[repo_ref] = cached
            return cached
          end

          stale = nil
          unless @refresh_cache
            cached = @persistent_cache&.versions_for_repo(repo_ref, fresh: true)
            if cached
              @last_versions_cache_hit = true
              @release_cache[repo_ref] = cached
              return cached
            end
            stale = @persistent_cache&.versions_for_repo(repo_ref, fresh: false)
          end

          releases = nil
          Timeout.timeout(@refresh_timeout) do
            data = request_json("/repos/#{repo_ref}/releases?per_page=100")
            unless data.is_a?(Array)
              detail = data.nil? ? nil : "expected an array, got #{data.class}"
              return refresh_failed!(repo_ref, stale, "invalid releases response", detail: detail)
            end

            tag_shas = tag_ref_shas(repo_ref)
            return refresh_failed!(repo_ref, stale, "invalid tag response") unless tag_shas

            releases = build_release_versions(data, tag_shas)
          end
          @persistent_cache&.write_versions(repo_ref, releases)
          @release_cache[repo_ref] = releases
          releases
        rescue Timeout::Error
          refresh_failed!(repo_ref, stale, "GitHub refresh timed out")
        end

        def commit_sha(repo_ref, ref, refresh: false)
          return nil if repo_ref.to_s.empty? || ref.to_s.empty?

          cache_key = "commit:#{repo_ref}:#{ref}"
          return @commit_cache[cache_key] if @commit_cache.key?(cache_key) && !refresh

          unless @refresh_cache || refresh
            cached = @persistent_cache&.ref_sha(repo_ref, ref, fresh: !@offline)
            if cached
              @commit_cache[cache_key] = cached
              return cached
            end
          end

          raise CacheMissError, "offline cache miss for #{repo_ref}@#{ref}" if @offline

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
          @last_versions_cache_hit = !stale.nil?
          @release_cache[repo_ref] = versions
          versions
        end

        def refresh_failed!(repo_ref, stale, message, detail: nil)
          return cached_versions(repo_ref, stale) unless @fail_on_refresh_error

          detail ||= @last_request_error
          suffix = detail.to_s.empty? ? "" : ": #{detail}"
          raise RefreshError, "#{message} for #{repo_ref}#{suffix}"
        end

        def build_release_versions(data, tag_shas)
          release_dates = {}
          release_tags = data.each_with_object([]) do |release, memo|
            next unless release.is_a?(Hash)

            tag = release["tag_name"].to_s
            next unless VersionRubric.parse(tag)

            release_dates[tag] = release["published_at"].to_s
            release_dates[tag] = release["created_at"].to_s if release_dates[tag].empty?
            memo << tag
          end

          VersionRubric.build_release_versions(
            release_tags: release_tags,
            tag_shas: tag_shas,
            release_dates: release_dates
          )
        end

        def tag_ref_shas(repo_ref)
          data = request_json("/repos/#{repo_ref}/git/matching-refs/tags/")
          return nil unless data.is_a?(Array)

          entries = data.each_with_object([]) do |entry, memo|
            ref = entry["ref"].to_s
            next unless ref.start_with?("refs/tags/")

            tag = ref.sub(%r{\Arefs/tags/}, "")
            next unless VersionRubric.parse(tag)

            object = entry["object"]
            next unless object.is_a?(Hash)

            memo << [tag, object["type"].to_s, object["sha"].to_s[0, 40]]
          end
          annotated_tag_shas = git_tag_ref_shas(repo_ref) if entries.count { |_, type, _| type == "tag" } > ANNOTATED_TAG_GIT_FALLBACK_THRESHOLD

          entries.each_with_object({}) do |(tag, type, sha), memo|
            case type
            when "commit"
              memo[tag] = sha
            when "tag"
              memo[tag] = annotated_tag_shas&.fetch(tag, nil) || annotated_tag_commit_sha(repo_ref, sha)
            end
          end
        end

        # The REST API exposes annotated tags as tag objects, requiring one
        # additional request per tag to reach the commit. A single Git
        # protocol exchange returns both tag objects and peeled commit refs,
        # avoiding a refresh timeout for repositories with large tag histories.
        def git_tag_ref_shas(repo_ref)
          return unless @api_base.to_s.sub(%r{/\z}, "") == API_BASE

          stdout, _stderr, status = Open3.capture3(
            {"GIT_TERMINAL_PROMPT" => "0"},
            "git",
            "ls-remote",
            "--tags",
            "https://github.com/#{repo_ref}.git"
          )
          return unless status.success?

          stdout.each_line.each_with_object({}) do |line, memo|
            sha, ref = line.split
            next unless SHA_RE.match?(sha.to_s)
            next unless ref.to_s.start_with?("refs/tags/")

            peeled = ref.end_with?("^{}")
            tag = ref.sub(%r{\Arefs/tags/}, "").sub(/\^\{\}\z/, "")
            next unless VersionRubric.parse(tag)

            memo[tag] = sha if peeled || !memo.key?(tag)
          end
        rescue IOError, SystemCallError
          nil
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
          @last_request_error = nil

          response = nil
          retries = 0
          loop do
            request = Net::HTTP::Get.new(uri)
            request["Accept"] = "application/vnd.github+json"
            request["User-Agent"] = @user_agent
            request["X-GitHub-Api-Version"] = "2022-11-28"
            request["Authorization"] = "Bearer #{@token}" if @token && !@token.empty?

            begin
              response = http_request(uri, request)
            rescue IOError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout => error
              if retries < HTTP_RETRY_LIMIT
                retries += 1
                sleep(retry_delay(nil, retries))
                next
              end

              @last_request_error = "GitHub request failed for #{path}: #{error.class}: #{error.message}"
              return nil
            end

            if response.code.to_i.between?(300, 399)
              redirects -= 1
              return nil if redirects.negative?

              location = response["location"].to_s
              return nil if location.empty?

              uri = URI.join(uri.to_s, location)
              next
            end

            status = response.code.to_i
            unless status == 200
              if RETRYABLE_HTTP_STATUS_CODES.include?(status) && retries < HTTP_RETRY_LIMIT
                retries += 1
                sleep(retry_delay(response, retries))
                next
              end

              @last_request_error = response_error(response, path)
              return nil
            end

            begin
              return JSON.parse(response.body)
            rescue JSON::ParserError
              @last_request_error = "GitHub returned invalid JSON for #{path}"
              return nil
            end
          end
        end

        def retry_delay(response, attempt)
          retry_after = response ? response["retry-after"].to_f : 0.0
          return retry_after.clamp(0.0, 2.0) if retry_after.positive?

          0.25 * (2**(attempt - 1))
        end

        def response_error(response, path)
          status = response.code.to_i
          body = begin
            JSON.parse(response.body.to_s)
          rescue JSON::ParserError
            nil
          end
          message = body.is_a?(Hash) ? body["message"].to_s : ""
          detail = message.empty? ? "response body was not a GitHub API error object" : message
          "GitHub API returned HTTP #{status} for #{path}: #{detail}"
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
