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
end
