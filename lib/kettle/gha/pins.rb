# frozen_string_literal: true

require "version_gem"

require_relative "pins/version_rubric"
require_relative "pins/version"

module Kettle
  module Gha
    module Pins
      class Error < StandardError; end
    end
  end
end

Kettle::Gha::Pins::Version.class_eval do
  extend VersionGem::Basic
end
