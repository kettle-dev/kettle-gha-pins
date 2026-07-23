# frozen_string_literal: true

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

    it "uses the patch policy when callers provide an invalid upgrade level" do
      expect(described_class.choose_upgrade_target("v1.2.0", versions, "garbage")).to include(version: "1.2.3")
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

    it "persists release versions and ref SHAs with the historical cache shape" do
      cache = described_class.new(path: path, clock: clock)
      cache.write_versions(
        "codecov/codecov-action",
        [
          {
            tag: "v7.0.0",
            version_obj: Gem::Version.new("7.0.0"),
            version: "7.0.0",
            sha: "a" * 40
          }
        ]
      )
      cache.write_ref_sha("codecov/codecov-action", "v7.0.0", "a" * 40)

      reloaded = described_class.new(path: path, clock: clock)

      expect(reloaded.versions_for_repo("codecov/codecov-action")).to contain_exactly(
        include(tag: "v7.0.0", version: "7.0.0", sha: "a" * 40)
      )
      expect(reloaded.ref_sha("codecov/codecov-action", "v7.0.0")).to eq("a" * 40)
    end
  end

  describe Kettle::Gha::Pins::GitHubClient do
    let(:response_class) do
      Struct.new(:code, :body) do
        def [](key)
          nil
        end
      end
    end

    it "resolves release tags through the GitHub release and tag APIs" do
      client = described_class.new(token: nil, api_base: "https://api.example.test", user_agent: "spec")
      releases = response_class.new("200", JSON.generate([{"tag_name" => "v7.0.0"}]))
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

      expect(versions).to contain_exactly(include(tag: "v7.0.0", version: "7.0.0", sha: "a" * 40))
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
          sha: "b" * 40
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
      expect(first.fetch(:updates)).to include(sha: "b" * 40, version: "1.0.1")
      expect(second.fetch(:updates)).to include(sha: "b" * 40, version: "1.0.1")
    end
  end
end
