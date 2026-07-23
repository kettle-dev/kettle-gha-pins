# frozen_string_literal: true

require "version_gem"

require_relative "pins/version_rubric"
require_relative "pins/version"

module Kettle
  module Gha
    module Pins
      class Error < StandardError; end

      API_BASE = "https://api.github.com"
      RELEASE_PATH = "releases/latest"
      SHA_RE = /\A[0-9a-f]{40}\z/i
      WEAK_SHA_RE = /\A[0-9a-f]{7,39}\z/i

      NON_SHA_REASON = "convert_to_sha"
      STALE_SHA_REASON = "upgrade_to_latest_release_sha"
      UPGRADE_REASON = "upgrade_to_allowed_release"
      DEFAULT_UPGRADE_LEVEL = VersionRubric::DEFAULT_UPGRADE_LEVEL
      DEFAULT_CACHE_TTL_SECONDS = 24 * 60 * 60
      DEFAULT_HTTP_OPEN_TIMEOUT_SECONDS = 5
      DEFAULT_HTTP_READ_TIMEOUT_SECONDS = 10
      DEFAULT_HTTP_REFRESH_TIMEOUT_SECONDS = 20
      VALID_UPGRADE_LEVELS = VersionRubric::VALID_UPGRADE_LEVELS

      autoload :CacheProgress, "kettle/gha/pins/cache_progress"
      autoload :CLI, "kettle/gha/pins/cli"
    end
  end
end

require_relative "pins/action_resolver"
require_relative "pins/github_client"
require_relative "pins/persistent_action_cache"

Kettle::Gha::Pins::Version.class_eval do
  extend VersionGem::Basic
end
