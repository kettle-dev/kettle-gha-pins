# frozen_string_literal: true

require "stringio"

RSpec.describe Kettle::Gha::Pins do
  it "has a version number" do
    expect(Kettle::Gha::Pins::VERSION).not_to be_nil
  end

  describe Kettle::Gha::Pins::VersionRubric do
    let(:versions) do
      [
        {tag: "v2.0.0", version_obj: Gem::Version.new("2.0.0"), version: "2.0.0", sha: "b" * 40},
        {tag: "v1.2.3", version_obj: Gem::Version.new("1.2.3"), version: "1.2.3", sha: "a" * 40},
        {tag: "v1.2.0", version_obj: Gem::Version.new("1.2.0"), version: "1.2.0", sha: "7" * 40}
      ]
    end

    it "parses concrete and major-line action release tags" do
      expect(described_class.parse("v1.2.3")).to eq(Gem::Version.new("1.2.3"))
      expect(described_class.parse("v2")).to eq(Gem::Version.new("2"))
      expect(described_class.parse("bad-tag")).to be_nil
      expect(described_class.parse("1.0.0-")).to be_nil
    end

    it "returns nil entries for values that are not action release tags" do
      expect(described_class.entry(tag: "codeql-bundle-v2.25.6")).to be_nil
    end

    it "canonicalizes equivalent major-line and concrete release tags to the explicit release" do
      releases = described_class.build_release_versions(
        release_tags: ["v7.0.0"],
        tag_shas: {
          "v7" => "a" * 40,
          "v7.0.0" => "a" * 40
        }
      )

      expect(releases).to contain_exactly(
        include(tag: "v7.0.0", version: "7.0.0", sha: "a" * 40)
      )
    end

    it "keeps a moving major-line tag when it points at a different SHA" do
      releases = described_class.build_release_versions(
        release_tags: ["v7.0.0", "v7.0.1"],
        tag_shas: {
          "v7.0.0" => "a" * 40,
          "v7" => "b" * 40,
          "v7.0.1" => "b" * 40
        }
      )

      expect(releases).to match([
        include(tag: "v7.0.1", version: "7.0.1", sha: "b" * 40),
        include(tag: "v7.0.0", version: "7.0.0", sha: "a" * 40),
        include(tag: "v7", version: "7", sha: "b" * 40)
      ])
    end

    it "keeps equivalent version spellings separate when either SHA is unknown" do
      releases = described_class.build_release_versions(
        release_tags: ["v7.0.0"],
        tag_shas: {
          "v7" => nil,
          "v7.0.0" => "a" * 40
        }
      )

      expect(releases).to contain_exactly(
        include(tag: "v7", version: "7", sha: nil),
        include(tag: "v7.0.0", version: "7.0.0", sha: "a" * 40)
      )
    end

    it "selects upgrade targets by patch, minor, and major policy" do
      expect(described_class.choose_upgrade_target("v1.2.0", versions, "patch")).to include(version: "1.2.3")
      expect(described_class.choose_upgrade_target("v1.2.0", versions, "minor")).to include(version: "1.2.3")
      expect(described_class.choose_upgrade_target("v1.2.0", versions, "major")).to include(version: "2.0.0")
    end

    it "uses the default major policy when callers provide an invalid upgrade level" do
      expect(described_class.choose_upgrade_target("v1.2.0", versions, "garbage")).to include(version: "2.0.0")
      expect(described_class.send(:allowed_by_level?, "1.2.0", Gem::Version.new("1.2.0"), versions.first, "custom")).to be(true)
    end

    it "only upgrades major-line tags under the major policy" do
      major_line_versions = [
        {tag: "v3", version_obj: Gem::Version.new("3"), version: "3", sha: "c" * 40},
        {tag: "v2", version_obj: Gem::Version.new("2"), version: "2", sha: "b" * 40}
      ]

      expect(described_class.choose_upgrade_target("v2", major_line_versions, "major")).to include(version: "3")
      expect(described_class.choose_upgrade_target("v2", major_line_versions, "minor")).to be_nil
      expect(described_class.choose_upgrade_target("v2", major_line_versions, "patch")).to be_nil
    end

    it "reports the latest higher release even when policy writes a narrower target" do
      expect(described_class.latest_outdated_target("v1.2.0", versions)).to include(version: "2.0.0")
    end

    it "returns nil targets when the current version cannot be parsed" do
      expect(described_class.choose_upgrade_target("branch-name", versions, "major")).to be_nil
      expect(described_class.latest_outdated_target("branch-name", versions)).to be_nil
    end

    it "does not upgrade stable pins to prerelease-only tags" do
      prerelease_versions = [
        {tag: "v1.3.0.pre", version_obj: Gem::Version.new("1.3.0.pre"), version: "1.3.0.pre", sha: "p" * 40},
        {tag: "v1.2.0", version_obj: Gem::Version.new("1.2.0"), version: "1.2.0", sha: "7" * 40}
      ]

      expect(described_class.choose_upgrade_target("v1.2.0", prerelease_versions, "major")).to be_nil
      expect(described_class.latest_outdated_target("v1.2.0", prerelease_versions)).to be_nil
    end

    it "allows prerelease pins to advance to newer prerelease tags" do
      prerelease_versions = [
        {tag: "v1.3.0.pre", version_obj: Gem::Version.new("1.3.0.pre"), version: "1.3.0.pre", sha: "p" * 40},
        {tag: "v1.2.0.pre", version_obj: Gem::Version.new("1.2.0.pre"), version: "1.2.0.pre", sha: "q" * 40}
      ]

      expect(described_class.choose_upgrade_target("v1.2.0.pre", prerelease_versions, "minor")).to include(version: "1.3.0.pre")
      expect(described_class.latest_outdated_target("v1.2.0.pre", prerelease_versions)).to include(version: "1.3.0.pre")
    end
  end

  describe Kettle::Gha::Pins::PersistentActionCache do
    let(:clock_time) { Time.utc(2026, 7, 22, 12, 0, 0) }
    let(:clock) { -> { clock_time } }
    let(:path) { File.join(Dir.mktmpdir, "gha-sha-pins-cache.json") }

    after do
      FileUtils.rm_rf(File.dirname(path))
    end

    it "builds the default path from state home and tolerates missing home directories" do
      state_home = File.join(File.dirname(path), "state")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("XDG_STATE_HOME").and_return(state_home)

      expect(described_class.default_path).to eq(File.join(state_home, "kettle-dev", "gha-sha-pins-cache.json"))

      allow(ENV).to receive(:[]).with("XDG_STATE_HOME").and_return(nil)
      allow(Dir).to receive(:home).and_raise(ArgumentError)
      expect(described_class.default_path).to be_nil
    end

    it "persists release versions with release timestamps and ref SHAs" do
      cache = described_class.new(path: path, clock: clock)
      cache.write_versions(
        "codecov/codecov-action",
        [
          {
            tag: "v7.0.0",
            version_obj: Gem::Version.new("7.0.0"),
            version: "7.0.0",
            sha: "a" * 40,
            released_at: "2026-07-22T12:00:00Z"
          }
        ]
      )
      cache.write_ref_sha("codecov/codecov-action", "v7.0.0", "a" * 40)

      reloaded = described_class.new(path: path, clock: clock)

      expect(reloaded.versions_for_repo("codecov/codecov-action")).to contain_exactly(
        include(tag: "v7.0.0", version: "7.0.0", sha: "a" * 40, released_at: "2026-07-22T12:00:00Z")
      )
      expect(reloaded.to_h.dig("actions", "codecov/codecov-action", "targets", "major", "*", "released_at")).to eq("2026-07-22T12:00:00Z")
      expect(reloaded.ref_sha("codecov/codecov-action", "v7.0.0")).to eq("a" * 40)
    end

    it "returns nil for missing, empty, stale, and invalid cache entries" do
      stale_clock = -> { clock_time - (25 * 60 * 60) }
      cache = described_class.new(path: path, clock: stale_clock)
      cache.write_versions(
        "actions/checkout",
        [
          {
            tag: "v1.0.0",
            version_obj: Gem::Version.new("1.0.0"),
            version: "1.0.0",
            sha: "a" * 40
          }
        ]
      )
      cache.write_ref_sha("actions/checkout", "v1.0.0", "a" * 40)
      reloaded = described_class.new(path: path, clock: clock)

      expect(reloaded.versions_for_repo("missing/action")).to be_nil
      expect(reloaded.versions_for_repo("actions/checkout")).to be_nil
      expect(reloaded.versions_for_repo("actions/checkout", fresh: false)).to contain_exactly(include(version: "1.0.0"))
      expect(reloaded.ref_sha("actions/checkout", "missing")).to be_nil
      expect(reloaded.ref_sha("actions/checkout", "v1.0.0")).to be_nil
      expect(reloaded.ref_sha("actions/checkout", "v1.0.0", fresh: false)).to eq("a" * 40)
    end

    it "ignores invalid writes and invalid serialized entries" do
      cache = described_class.new(path: path, clock: clock)

      no_path_cache = described_class.new(path: "", clock: clock)
      expect { no_path_cache.write_versions("actions/checkout", [{version: "1.0.0"}]) }.not_to change { File.exist?(path) }
      expect { no_path_cache.write_ref_sha("actions/checkout", "v1.0.0", "a" * 40) }.not_to change { File.exist?(path) }
      expect { cache.write_versions("", [{version: "1.0.0"}]) }.not_to change { File.exist?(path) }
      expect { cache.write_versions("actions/checkout", [{version: ""}]) }.to change { File.exist?(path) }.from(false).to(true)
      expect(cache.versions_for_repo("actions/checkout", fresh: false)).to be_nil
      expect { cache.write_ref_sha("actions/checkout", "", "a" * 40) }.not_to change { File.exist?(path) }

      FileUtils.mkdir_p(File.dirname(path))
      File.write(
        path,
        JSON.generate(
          "version" => described_class::VERSION,
          "actions" => {
            "actions/checkout" => {
              "versions" => {
                "bad" => {"tag" => "bad", "version" => "bad", "sha" => "a" * 40, "cached_at" => clock_time.iso8601}
              },
              "refs" => {
                "blank" => {"sha" => "", "cached_at" => clock_time.iso8601},
                "invalid-time" => {"sha" => "b" * 40, "cached_at" => "not-time"}
              }
            }
          }
        )
      )

      reloaded = described_class.new(path: path, clock: clock)

      expect(reloaded.versions_for_repo("actions/checkout")).to be_empty
      expect(reloaded.ref_sha("actions/checkout", "blank")).to be_nil
      expect(reloaded.ref_sha("actions/checkout", "invalid-time")).to be_nil
    end

    it "falls back to empty data for unreadable, malformed, and old cache files" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{")
      expect(described_class.new(path: path).to_h).to eq("version" => described_class::VERSION, "actions" => {})

      File.write(path, JSON.generate("version" => described_class::VERSION - 1, "actions" => {}))
      expect(described_class.new(path: path).to_h).to eq("version" => described_class::VERSION, "actions" => {})

      File.write(path, JSON.generate("version" => described_class::VERSION, "actions" => []))
      expect(described_class.new(path: path).to_h).to eq("version" => described_class::VERSION, "actions" => {})

      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with(path).and_return(true)
      allow(File).to receive(:read).with(path).and_raise(Errno::EACCES)
      expect(described_class.new(path: path).to_h).to eq("version" => described_class::VERSION, "actions" => {})
    end

    it "rejects mixed-freshness version caches" do
      stale_clock = -> { clock_time - (25 * 60 * 60) }
      cache = described_class.new(path: path, clock: stale_clock)
      cache.write_versions(
        "actions/checkout",
        [{tag: "v1.0.0", version_obj: Gem::Version.new("1.0.0"), version: "1.0.0", sha: "a" * 40}]
      )

      fresh_cache = described_class.new(path: path, clock: clock)
      fresh_cache.write_versions(
        "actions/checkout",
        [{tag: "v1.0.1", version_obj: Gem::Version.new("1.0.1"), version: "1.0.1", sha: "b" * 40}]
      )

      reloaded = described_class.new(path: path, clock: clock)

      expect(reloaded.versions_for_repo("actions/checkout")).to be_nil
      expect(reloaded.versions_for_repo("actions/checkout", fresh: false).map { |entry| entry[:version] }).to eq(%w[1.0.1 1.0.0])
    end
  end

  describe Kettle::Gha::Pins::GitHubClient do
    let(:response_class) do
      Struct.new(:code, :body) do
        attr_writer :location

        def [](key)
          (key == "location") ? @location : nil
        end
      end
    end

    it "resolves release tags through the GitHub release and tag APIs" do
      client = described_class.new(token: nil, api_base: "https://api.example.test", user_agent: "spec")
      releases = response_class.new("200", JSON.generate([{"tag_name" => "v7.0.0", "published_at" => "2026-07-22T12:00:00Z"}]))
      tags = response_class.new(
        "200",
        JSON.generate(
          [
            {"ref" => "refs/tags/v7", "object" => {"type" => "commit", "sha" => "a" * 40}},
            {"ref" => "refs/tags/v7.0.0", "object" => {"type" => "commit", "sha" => "a" * 40}}
          ]
        )
      )
      allow(client).to receive(:http_request).and_return(releases, tags)

      versions = client.versions_for_repo("codecov/codecov-action")

      expect(versions).to contain_exactly(include(tag: "v7.0.0", version: "7.0.0", sha: "a" * 40, released_at: "2026-07-22T12:00:00Z"))
    end

    it "uses fresh and stale persistent release cache entries" do
      cache = instance_double(Kettle::Gha::Pins::PersistentActionCache)
      versions = [{tag: "v1.0.0", version_obj: Gem::Version.new("1.0.0"), version: "1.0.0", sha: "a" * 40}]
      allow(cache).to receive(:versions_for_repo).with("actions/checkout", fresh: true).and_return(versions)
      client = described_class.new(token: nil, api_base: "https://api.example.test", user_agent: "spec", persistent_cache: cache)

      expect(client.versions_for_repo("")).to be_empty
      expect(client.versions_for_repo("actions/checkout")).to eq(versions)
      expect(client.versions_for_repo("actions/checkout")).to eq(versions)
      expect(cache).to have_received(:versions_for_repo).once
    end

    it "falls back to stale persistent release cache on refresh failures and timeouts" do
      cache = instance_double(Kettle::Gha::Pins::PersistentActionCache)
      stale = [{tag: "v1.0.0", version_obj: Gem::Version.new("1.0.0"), version: "1.0.0", sha: "a" * 40}]
      allow(cache).to receive(:versions_for_repo).with("actions/checkout", fresh: true).and_return(nil)
      allow(cache).to receive(:versions_for_repo).with("actions/checkout", fresh: false).and_return(stale)
      client = described_class.new(token: nil, api_base: "https://api.example.test", user_agent: "spec", persistent_cache: cache)
      allow(client).to receive(:request_json).and_return("not releases")

      expect(client.versions_for_repo("actions/checkout")).to eq(stale)

      timeout_client = described_class.new(token: nil, api_base: "https://api.example.test", user_agent: "spec", persistent_cache: cache)
      allow(timeout_client).to receive(:request_json).and_raise(Timeout::Error)

      expect(timeout_client.versions_for_repo("actions/checkout")).to eq(stale)

      no_cache_client = described_class.new(token: nil, api_base: "https://api.example.test", user_agent: "spec")
      allow(no_cache_client).to receive_messages(request_json: [], tag_ref_shas: nil)
      expect(no_cache_client.versions_for_repo("actions/checkout")).to be_empty
    end

    it "resolves and caches commit SHAs with stale fallback" do
      cache = instance_double(Kettle::Gha::Pins::PersistentActionCache)
      allow(cache).to receive(:ref_sha).with("actions/checkout", "v1", fresh: true).and_return(nil)
      allow(cache).to receive(:ref_sha).with("actions/checkout", "v1", fresh: false).and_return("b" * 40)
      allow(cache).to receive(:write_ref_sha)
      client = described_class.new(token: nil, api_base: "https://api.example.test", user_agent: "spec", persistent_cache: cache)
      allow(client).to receive(:request_json).and_return({"sha" => "a" * 45}, {})

      expect(client.commit_sha("", "v1")).to be_nil
      expect(client.commit_sha("actions/checkout", "")).to be_nil
      expect(client.commit_sha("actions/checkout", "v1")).to eq("a" * 40)
      expect(client.commit_sha("actions/checkout", "v1")).to eq("a" * 40)
      expect(cache).to have_received(:write_ref_sha).once.with("actions/checkout", "v1", "a" * 40)

      fallback_client = described_class.new(token: nil, api_base: "https://api.example.test", user_agent: "spec", persistent_cache: cache)
      allow(fallback_client).to receive(:request_json).and_return({})
      expect(fallback_client.commit_sha("actions/checkout", "v1")).to eq("b" * 40)

      no_cache_client = described_class.new(token: nil, api_base: "https://api.example.test", user_agent: "spec")
      allow(no_cache_client).to receive(:request_json).and_return({})
      expect(no_cache_client.commit_sha("actions/checkout", "v2")).to be_nil
    end

    it "handles latest release lookup and private ref helpers" do
      client = described_class.new(token: nil, api_base: "https://api.example.test", user_agent: "spec")
      allow(client).to receive(:versions_for_repo).and_return(
        [
          {tag: "v2.0.0", version_obj: Gem::Version.new("2.0.0"), version: "2.0.0", sha: ""},
          {tag: "v1.0.0", version_obj: Gem::Version.new("1.0.0"), version: "1.0.0", sha: "a" * 40}
        ]
      )
      allow(client).to receive(:commit_sha).with("actions/checkout", "v2.0.0").and_return("b" * 40)

      expect(client.release_latest_sha("actions/checkout")).to eq("b" * 40)

      allow(client).to receive(:versions_for_repo).and_return([])
      expect(client.release_latest_sha("actions/checkout")).to be_nil
    end

    it "handles tag refs, annotated tags, redirects, invalid JSON, and request errors" do
      client = described_class.new(token: "secret", api_base: "https://api.example.test", user_agent: "spec")
      tags = response_class.new(
        "200",
        JSON.generate(
          [
            {"ref" => "refs/heads/main", "object" => {"type" => "commit", "sha" => "x" * 40}},
            {"ref" => "refs/tags/v1.0.0", "object" => {"type" => "commit", "sha" => "a" * 40}},
            {"ref" => "refs/tags/v1.0.1", "object" => {"type" => "tag", "sha" => "b" * 40}},
            {"ref" => "refs/tags/not-version", "object" => {"type" => "commit", "sha" => "c" * 40}},
            {"ref" => "refs/tags/v1.0.2", "object" => nil}
          ]
        )
      )
      allow(client).to receive(:request_json).and_return(JSON.parse(tags.body))

      expect(client.send(:tag_ref_shas, "actions/checkout")).to eq("v1.0.0" => "a" * 40, "v1.0.1" => nil)

      allow(client).to receive(:request_json).and_return({"object" => {"type" => "commit", "sha" => "d" * 40}}, {}, {"object" => {"type" => "tree"}})
      expect(client.send(:annotated_tag_commit_sha, "actions/checkout", "")).to be_nil
      expect(client.send(:annotated_tag_commit_sha, "actions/checkout", "b" * 40)).to eq("d" * 40)
      expect(client.send(:annotated_tag_commit_sha, "actions/checkout", "b" * 40)).to be_nil
      expect(client.send(:annotated_tag_commit_sha, "actions/checkout", "b" * 40)).to be_nil

      redirect = response_class.new("302", "")
      redirect.location = "/redirected"
      ok = response_class.new("200", JSON.generate("ok" => true))
      invalid = response_class.new("200", "not json")
      missing = response_class.new("404", "{}")
      request_client = described_class.new(token: "secret", api_base: "https://api.example.test", user_agent: "spec")
      allow(request_client).to receive(:http_request).and_return(redirect, ok, invalid, missing)

      expect(request_client.send(:request_json, "/first")).to eq("ok" => true)
      expect(request_client.send(:request_json, "/invalid")).to be_nil
      expect(request_client.send(:request_json, "/missing")).to be_nil

      allow(request_client).to receive(:http_request).and_raise(Net::ReadTimeout)
      expect(request_client.send(:request_json, "/timeout")).to be_nil

      redirects = Array.new(4) do
        response = response_class.new("302", "")
        response.location = "/again"
        response
      end
      allow(request_client).to receive(:http_request).and_return(*redirects)
      expect(request_client.send(:request_json, "/redirect-loop")).to be_nil

      empty_location = response_class.new("302", "")
      allow(request_client).to receive(:http_request).and_return(empty_location)
      expect(request_client.send(:request_json, "/redirect-nowhere")).to be_nil
    end

    it "configures HTTP without ssl timeout when unavailable" do
      client = described_class.new(token: nil, api_base: "https://api.example.test", user_agent: "spec", open_timeout: 1, read_timeout: 2)
      http = instance_double(Net::HTTP)
      request = instance_double(Net::HTTP::Get)
      allow(http).to receive(:use_ssl=).with(true)
      allow(http).to receive(:open_timeout=).with(1)
      allow(http).to receive(:read_timeout=).with(2)
      allow(http).to receive(:respond_to?).with(:ssl_timeout=).and_return(false)
      allow(http).to receive(:start).and_yield(http)
      allow(http).to receive(:request).with(request).and_return("response")
      allow(Net::HTTP).to receive(:new).with("api.example.test", 443).and_return(http)

      expect(client.send(:http_request, URI("https://api.example.test/repos/foo/bar"), request)).to eq("response")
    end
  end

  describe Kettle::Gha::Pins::ActionResolver do
    let(:client) do
      instance_double(
        Kettle::Gha::Pins::GitHubClient,
        commit_sha: "a" * 40
      )
    end

    it "plans version comment normalization using the shared v7 to v7.0.0 rubric" do
      versions = [
        {
          tag: "v7.0.0",
          version_obj: Gem::Version.new("7.0.0"),
          version: "7.0.0",
          sha: "a" * 40
        }
      ]

      plan = described_class.determine_upgrade_plan(
        old_ref: "a" * 40,
        repo_ref: "codecov/codecov-action",
        versions: versions,
        upgrade_level: "major",
        client: client
      )

      expect(plan).to include(is_outdated: false, updates: nil, current_version: "7.0.0")
    end

    it "resolves versions once per action repo through a caller-provided cache" do
      versions = [
        {
          tag: "v1.0.1",
          version_obj: Gem::Version.new("1.0.1"),
          version: "1.0.1",
          sha: "b" * 40,
          released_at: "2026-07-22T12:00:00Z"
        },
        {
          tag: "v1.0.0",
          version_obj: Gem::Version.new("1.0.0"),
          version: "1.0.0",
          sha: "a" * 40
        }
      ]
      client = instance_double(Kettle::Gha::Pins::GitHubClient, versions_for_repo: versions)
      cache = {}

      first = described_class.resolve_action_plan(
        cache: cache,
        client: client,
        repo_ref: "actions/checkout",
        old_ref: "a" * 40,
        upgrade_level: "major"
      )
      second = described_class.resolve_action_plan(
        cache: cache,
        client: client,
        repo_ref: "actions/checkout",
        old_ref: "a" * 40,
        upgrade_level: "major"
      )

      expect(client).to have_received(:versions_for_repo).once
      expect(first.fetch(:updates)).to include(sha: "b" * 40, version: "1.0.1", released_at: "2026-07-22T12:00:00Z")
      expect(second.fetch(:updates)).to include(sha: "b" * 40, version: "1.0.1")
    end

    it "handles empty refs, mutable refs, unresolved version refs, and stale SHA pins" do
      versions = [
        {tag: "v2.0.0", version_obj: Gem::Version.new("2.0.0"), version: "2.0.0", sha: "b" * 40},
        {tag: "v1.0.0", version_obj: Gem::Version.new("1.0.0"), version: "1.0.0", sha: "a" * 40}
      ]
      client = instance_double(Kettle::Gha::Pins::GitHubClient)
      allow(client).to receive(:commit_sha).with("actions/checkout", "main").and_return("c" * 40)
      allow(client).to receive(:commit_sha).with("actions/checkout", "1.0.0").and_return(nil)

      expect(described_class.determine_upgrade_plan(
        old_ref: " ",
        repo_ref: "actions/checkout",
        versions: versions,
        upgrade_level: "major",
        client: client
      )).to include(is_outdated: false, updates: nil, current_version: nil)

      mutable = described_class.determine_upgrade_plan(
        old_ref: "main",
        repo_ref: "actions/checkout",
        versions: versions,
        upgrade_level: "major",
        client: client
      )
      expect(mutable.fetch(:updates)).to include(sha: "c" * 40, reason: Kettle::Gha::Pins::NON_SHA_REASON)

      unresolved = described_class.determine_upgrade_plan(
        old_ref: "1.0.0",
        repo_ref: "actions/checkout",
        versions: versions,
        upgrade_level: "patch",
        client: client
      )
      expect(unresolved.fetch(:updates)).to include(sha: "a" * 40, reason: Kettle::Gha::Pins::NON_SHA_REASON)

      stale = described_class.determine_upgrade_plan(
        old_ref: "c" * 40,
        repo_ref: "actions/checkout",
        versions: versions,
        upgrade_level: "major",
        client: client
      )
      expect(stale.fetch(:updates)).to include(sha: "b" * 40, version: "2.0.0", reason: Kettle::Gha::Pins::STALE_SHA_REASON)
    end

    it "covers matching and SHA helper edge cases" do
      entry = {tag: "v1.0.0", version_obj: Gem::Version.new("1.0.0"), version: "1.0.0", sha: ""}
      client = instance_double(Kettle::Gha::Pins::GitHubClient, commit_sha: "a" * 40)

      expect(described_class.matching_version_entry([entry], "v1.0.0", nil, client, "actions/checkout")).to eq(entry)
      expect(described_class.matching_version_entry([entry], "main", nil, client, "actions/checkout")).to be_nil
      expect(described_class.version_entry_sha(nil, client, "actions/checkout")).to be_nil
      expect(described_class.version_entry_sha(entry, client, "actions/checkout")).to eq("a" * 40)
      expect(described_class.short_sha?(nil)).to be(false)
      expect(described_class.short_sha?("a" * 12)).to be(true)
      expect(described_class.stale_sha?(nil, "a" * 40)).to be(false)
      expect(described_class.stale_sha?("a" * 12, "a" * 40)).to be(false)
      expect(described_class.stale_sha?("b" * 12, "a" * 40)).to be(true)
    end

    it "keeps already-current refs clean across version, mutable, and SHA flows" do
      versions = [
        {tag: "v1.0.0", version_obj: Gem::Version.new("1.0.0"), version: "1.0.0", sha: "a" * 40}
      ]
      client = instance_double(Kettle::Gha::Pins::GitHubClient)
      allow(client).to receive(:commit_sha).with("actions/checkout", "main").and_return("a" * 40)
      allow(client).to receive(:commit_sha).with("actions/checkout", "v1.0.0").and_return("a" * 40)

      expect(described_class.determine_upgrade_plan(
        old_ref: "v1.0.0",
        repo_ref: "actions/checkout",
        versions: versions,
        upgrade_level: "major",
        client: client
      )).to include(is_outdated: false, updates: nil, current_version: "1.0.0", latest_outdated: nil)

      expect(described_class.determine_upgrade_plan(
        old_ref: "main",
        repo_ref: "actions/checkout",
        versions: [],
        upgrade_level: "major",
        client: client
      )).to include(updates: {sha: "a" * 40, version: nil, reason: Kettle::Gha::Pins::NON_SHA_REASON})

      expect(described_class.determine_upgrade_plan(
        old_ref: "a" * 40,
        repo_ref: "actions/checkout",
        versions: [],
        upgrade_level: "major",
        client: client
      )).to include(is_outdated: false, updates: nil, latest_outdated: nil)
    end
  end

  describe Kettle::Gha::Pins::CacheProgress do
    it "counts cached, live, and skipped events with optional progress bars" do
      output = StringIO.new

      progress = described_class.new(
        total: 3,
        cached_title: "Cached",
        live_title: "Live",
        skipped_title: "Skipped",
        output: output
      )

      progress.cached
      progress.live
      progress.skipped

      expect(progress.cached_count).to eq(1)
      expect(progress.live_count).to eq(1)
      expect(progress.skipped_count).to eq(1)
      expect(output.string).to include("Cached")

      disabled = described_class.new(total: 0, cached_title: "Cached", live_title: "Live", output: output, enabled: false)
      disabled.cached
      disabled.skipped

      expect(disabled.cached_count).to eq(1)
      expect(disabled.skipped_count).to eq(1)
    end
  end
end
