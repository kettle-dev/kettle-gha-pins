# frozen_string_literal: true

require "json"
require "stringio"

# rubocop:disable RSpec/VerifiedDoubles, RSpec/MessageSpies, ThreadSafety/ClassInstanceVariable

RSpec.describe Kettle::Gha::Pins::CLI do
  let(:workflow_root) { Dir.mktmpdir }
  let(:workflow_path) { File.join(workflow_root, ".github", "workflows", "ci.yml") }

  before do
    FileUtils.mkdir_p(File.dirname(workflow_path))
    File.write(
      workflow_path,
      <<~YAML
        name: ci
        on: [push]
        jobs:
          test:
            runs-on: ubuntu-latest
            steps:
              - uses: foo/bar@v1.2.0
      YAML
    )
  end

  after do
    FileUtils.rm_rf(workflow_root)
  end

  def stub_github_client(versions:, commit_shas: {})
    client = instance_double(described_class::GitHubClient)
    allow(described_class::GitHubClient).to receive(:new).and_return(client)
    allow(client).to receive(:versions_for_repo).and_return(versions)
    allow(client).to receive(:commit_sha) do |_repo, ref|
      commit_shas[ref]
    end
    client
  end

  describe "CLI options" do
    it "defaults --upgrade to major" do
      cli = described_class.new(["--root", workflow_root])
      cli.send(:parse!)
      expect(cli.instance_variable_get(:@options)[:upgrade]).to eq("major")
    end

    it "defaults cooldown days to zero" do
      cli = described_class.new(["--root", workflow_root])
      cli.send(:parse!)
      expect(cli.instance_variable_get(:@options)[:cooldown_days]).to eq(0)
    end

    it "accepts --cooldown-days" do
      cli = described_class.new(["--root", workflow_root, "--cooldown-days", "3"])
      cli.send(:parse!)
      expect(cli.instance_variable_get(:@options)[:cooldown_days]).to eq(3)
    end

    it "aborts on negative --cooldown-days values", :real_exit_adapter do
      cli = described_class.new(["--root", workflow_root, "--cooldown-days", "-1"])

      expect { cli.send(:parse!) }.to raise_error(SystemExit)
    end

    it "accepts --refresh-cache and --cache-path" do
      cache_path = File.join(workflow_root, "gha-cache.json")
      cli = described_class.new(["--root", workflow_root, "--refresh-cache", "--cache-path", cache_path])

      cli.send(:parse!)

      options = cli.instance_variable_get(:@options)
      expect(options[:refresh_cache]).to be(true)
      expect(options[:cache_path]).to eq(cache_path)
    end

    it "defaults to the current project's .github/workflows directory" do
      allow(Dir).to receive(:pwd).and_return(workflow_root)
      cli = described_class.new([])
      cli.send(:parse!)

      expect(cli.instance_variable_get(:@options)[:root]).to eq(File.join(workflow_root, ".github", "workflows"))
    end

    it "accepts major, minor, and patch for --upgrade", :real_exit_adapter do
      cli_major = described_class.new(["--upgrade", "major", "--root", workflow_root])
      cli_minor = described_class.new(["--upgrade", "minor", "--root", workflow_root])
      cli_patch = described_class.new(["--upgrade", "patch", "--root", workflow_root])

      expect { cli_major.send(:parse!) }.not_to raise_error
      expect(cli_major.instance_variable_get(:@options)[:upgrade]).to eq("major")

      expect { cli_minor.send(:parse!) }.not_to raise_error
      expect(cli_minor.instance_variable_get(:@options)[:upgrade]).to eq("minor")

      expect { cli_patch.send(:parse!) }.not_to raise_error
      expect(cli_patch.instance_variable_get(:@options)[:upgrade]).to eq("patch")
    end

    it "aborts on invalid --upgrade values", :real_exit_adapter do
      cli = described_class.new(["--upgrade", "garbage", "--root", workflow_root])

      expect { cli.send(:parse!) }.to raise_error(SystemExit)
    end

    it "aborts on invalid skip patterns", :real_exit_adapter do
      cli = described_class.new(["--skip-pattern", "["])

      expect { cli.send(:parse!) }.to raise_error(SystemExit)
    end

    it "prints help and exits", :real_exit_adapter do
      cli = described_class.new(["--help"])

      expect { cli.send(:parse!) }.to output(/Usage: kettle-gha-pins/).to_stdout.and raise_error(SystemExit)
    end
  end

  describe "workflow discovery" do
    it "scans only the selected workflow directory when given a project root" do
      nested_workflow = File.join(workflow_root, "tmp", "template_test", "destination", ".github", "workflows", "ci.yml")
      FileUtils.mkdir_p(File.dirname(nested_workflow))
      File.write(nested_workflow, File.read(workflow_path))
      cli = described_class.new(["--root", workflow_root])

      expect(cli.send(:discover_workflow_files, workflow_root, Set.new)).to eq([workflow_path])
    end

    it "accepts a workflow directory as the analysis root" do
      workflow_dir = File.dirname(workflow_path)
      cli = described_class.new(["--root", workflow_dir])

      expect(cli.send(:discover_workflow_files, workflow_dir, Set.new)).to eq([workflow_path])
    end

    it "skips non-files and rejected workflow paths" do
      workflow_dir = File.dirname(workflow_path)
      skipped_path = File.join(workflow_dir, "skip.yml")
      FileUtils.mkdir_p(File.join(workflow_dir, "dir.yml"))
      File.write(skipped_path, File.read(workflow_path))
      cli = described_class.new(["--root", workflow_dir])

      expect(cli.send(:discover_workflow_files, workflow_dir, Set[/skip/])).to eq([workflow_path])
    end
  end

  describe "upgrade planning helpers" do
    let(:versions) do
      [
        {
          tag: "v1.2.0",
          version_obj: Gem::Version.new("1.2.0"),
          version: "1.2.0",
          sha: "777"
        },
        {
          tag: "v1.3.0",
          version_obj: Gem::Version.new("1.3.0"),
          version: "1.3.0",
          sha: "999"
        },
        {
          tag: "v1.2.3",
          version_obj: Gem::Version.new("1.2.3"),
          version: "1.2.3",
          sha: "aaa"
        },
        {
          tag: "v2.0.0",
          version_obj: Gem::Version.new("2.0.0"),
          version: "2.0.0",
          sha: "bbb"
        }
      ]
    end

    let(:client) { described_class::GitHubClient.new(token: nil, api_base: described_class::API_BASE, user_agent: "kettle-gha-pins") }
    let(:dummy_cli) { described_class.new(["--root", workflow_root]) }

    before do
      allow(client).to receive(:commit_sha).and_return("777")
    end

    it "selects minor-compatible upgrade target for minor strategy" do
      plan = dummy_cli.send(:determine_upgrade_plan, old_ref: "v1.2.0", repo_ref: "foo/bar", versions: versions, upgrade_level: "minor", client: client)
      expect(plan[:updates][:sha]).to eq("999")
      expect(plan[:updates][:version]).to eq("1.3.0")
      expect(plan[:reason]).to eq(described_class::UPGRADE_REASON)
      expect(plan[:current_version]).to eq("1.2.0")
      expect(plan[:is_outdated]).to be(true)
    end

    it "selects any higher version for major strategy" do
      plan = dummy_cli.send(:determine_upgrade_plan, old_ref: "v1.2.0", repo_ref: "foo/bar", versions: versions, upgrade_level: "major", client: client)
      expect(plan[:updates][:sha]).to eq("bbb")
      expect(plan[:updates][:version]).to eq("2.0.0")
      expect(plan[:reason]).to eq(described_class::UPGRADE_REASON)
    end

    it "selects major-line tag upgrades only for major strategy" do
      major_line_versions = [
        {tag: "v3", version_obj: Gem::Version.new("3"), version: "3", sha: "c" * 40},
        {tag: "v2", version_obj: Gem::Version.new("2"), version: "2", sha: "b" * 40}
      ]

      major_plan = dummy_cli.send(:determine_upgrade_plan, old_ref: "v2", repo_ref: "foo/bar", versions: major_line_versions, upgrade_level: "major", client: client)
      minor_plan = dummy_cli.send(:determine_upgrade_plan, old_ref: "v2", repo_ref: "foo/bar", versions: major_line_versions, upgrade_level: "minor", client: client)
      patch_plan = dummy_cli.send(:determine_upgrade_plan, old_ref: "v2", repo_ref: "foo/bar", versions: major_line_versions, upgrade_level: "patch", client: client)

      expect(major_plan[:updates]).to include(sha: "c" * 40, version: "3", reason: described_class::UPGRADE_REASON)
      expect(minor_plan[:updates]).to be_nil
      expect(patch_plan[:updates]).to be_nil
    end

    it "selects latest patch for patch strategy" do
      plan = dummy_cli.send(:determine_upgrade_plan, old_ref: "v1.2.0", repo_ref: "foo/bar", versions: versions, upgrade_level: "patch", client: client)
      expect(plan[:updates][:sha]).to eq("aaa")
      expect(plan[:updates][:version]).to eq("1.2.3")
      expect(plan[:reason]).to eq(described_class::UPGRADE_REASON)
      expect(plan[:latest_outdated][:version]).to eq("2.0.0")
    end

    it "parses release tags and matches version-like values" do
      expect(dummy_cli.send(:parse_release_version, "v1.2.3")).to eq(Gem::Version.new("1.2.3"))
      expect(dummy_cli.send(:parse_release_version, "v2")).to eq(Gem::Version.new("2"))
      expect(dummy_cli.send(:parse_release_version, "bad-tag")).to be_nil
    end

    it "delegates release version parsing to kettle-gha-pins" do
      allow(Kettle::Gha::Pins::VersionRubric).to receive(:parse).and_call_original

      expect(dummy_cli.send(:parse_release_version, "v1.2.3")).to eq(Gem::Version.new("1.2.3"))

      expect(Kettle::Gha::Pins::VersionRubric).to have_received(:parse).with("v1.2.3")
    end

    it "falls back to source scanning for Psych nodes without location APIs" do
      text = <<~YAML
        jobs:
          test:
            steps:
              - uses: foo/bar@v1.2.0
      YAML

      expect(dummy_cli.send(:fallback_uses_location, text, "foo/bar@v1.2.0", {})).to eq([3, 14])
    end

    it "falls back to zero location when source scanning cannot locate a scalar" do
      expect(dummy_cli.send(:fallback_uses_location, nil, "foo/bar@v1.2.0", {})).to eq([0, 0])
      expect(dummy_cli.send(:fallback_uses_location, "uses: foo/bar@v1.2.0\nuses: foo/bar@v1.2.0\n", "foo/bar@v1.2.0", {0 => true})).to eq([1, 6])
      expect(dummy_cli.send(:fallback_uses_location, "uses: other/action@v1\n", "foo/bar@v1.2.0", {})).to eq([0, 0])
    end

    it "classifies only external GitHub action refs" do
      expect(dummy_cli.send(:classify_action_ref, nil)).to be_nil
      expect(dummy_cli.send(:classify_action_ref, " ")).to be_nil
      expect(dummy_cli.send(:classify_action_ref, "./local/action")).to be_nil
      expect(dummy_cli.send(:classify_action_ref, "../local/action")).to be_nil
      expect(dummy_cli.send(:classify_action_ref, "/abs/action")).to be_nil
      expect(dummy_cli.send(:classify_action_ref, "docker://alpine:latest")).to be_nil
      expect(dummy_cli.send(:classify_action_ref, "foo/bar@${{ matrix.ref }}")).to be_nil
      expect(dummy_cli.send(:classify_action_ref, "foo/bar")).to be_nil
      expect(dummy_cli.send(:classify_action_ref, "@v1")).to be_nil
      expect(dummy_cli.send(:classify_action_ref, "foo/@v1")).to be_nil
      expect(dummy_cli.send(:classify_action_ref, "foo//path@v1")).to be_nil
      expect(dummy_cli.send(:classify_action_ref, "foo/bar/path@v1")).to include(
        value: "foo/bar/path@v1",
        action: include(owner: "foo", repo: "bar", path: "path", ref: "v1")
      )
    end

    it "covers scalar parsing, quoting, replacement, and compatibility delegators" do
      expect(dummy_cli.send(:extract_scalar_token, nil)).to be_nil
      expect(dummy_cli.send(:extract_scalar_token, "")).to be_nil
      expect(dummy_cli.send(:extract_scalar_token, %("foo/\\"bar@v1" # v1))).to include(token: "foo/\"bar@v1", quote: :double)
      expect(dummy_cli.send(:extract_scalar_token, "'foo/bar@v1''s' # v1")).to include(token: "foo/bar@v1's", quote: :single)
      expect(dummy_cli.send(:extract_scalar_token, "foo/bar@v1 # v1")).to include(token: "foo/bar@v1", quote: :plain)
      expect(dummy_cli.send(:extract_scalar_token, "# comment")).to be_nil

      expect(dummy_cli.send(:normalize_quote_scalar, "foo/bar@sha", :plain)).to eq("foo/bar@sha")
      expect(dummy_cli.send(:normalize_quote_scalar, "foo/bar@sha's", :single)).to eq("'foo/bar@sha''s'")
      expect(dummy_cli.send(:normalize_quote_scalar, "foo/\"bar@sha", :double)).to eq(%("foo/\\"bar@sha"))
      expect(dummy_cli.send(:render_replacement, "foo/bar", "sha", :plain)).to be_nil
      expect(dummy_cli.send(:compute_updates, "same", "same", "reason", "foo/bar")).to be_nil
      expect(dummy_cli.send(:compute_updates, "same", "", "reason", "foo/bar")).to be_nil

      expect(dummy_cli.send(:matching_version_entry, [], "v1", nil, client, "foo/bar")).to be_nil
      expect(dummy_cli.send(:choose_upgrade_target, "1.2.0", versions, "patch")).to include(version: "1.2.3")
      expect(dummy_cli.send(:major_line_version?, "2")).to be(true)
      expect(dummy_cli.send(:latest_outdated_target, "1.2.0", versions)).to include(version: "2.0.0")
      expect(dummy_cli.send(:version_entry_sha, nil, client, "foo/bar")).to be_nil
      expect(dummy_cli.send(:release_version_sort_key, versions.first)).to be_an(Array)
      expect(dummy_cli.send(:short_sha?, "a" * 12)).to be(true)
      expect(dummy_cli.send(:non_sha?, "v1")).to be(true)
      expect(dummy_cli.send(:stale_sha?, "a", "abc")).to be(false)
    end

    it "returns nil for malformed replacement line coordinates and mismatched tokens" do
      text = "  - uses: foo/bar@v1 # v1\n"

      expect(dummy_cli.send(:version_comment_from_line, text, 5, 0, "foo/bar@v1")).to be_nil
      expect(dummy_cli.send(:version_comment_from_line, text, 0, 200, "foo/bar@v1")).to be_nil
      expect(dummy_cli.send(:version_comment_from_line, "# comment\n", 0, 0, "foo/bar@v1")).to be_nil
      expect(dummy_cli.send(:version_comment_from_line, text, 0, 10, "other/action@v1")).to be_nil
      expect(dummy_cli.send(:build_replacement_from_line, text, 5, 0, "foo/bar@v1", "sha")).to be_nil
      expect(dummy_cli.send(:build_replacement_from_line, text, 0, 200, "foo/bar@v1", "sha")).to be_nil
      expect(dummy_cli.send(:build_replacement_from_line, "# comment\n", 0, 0, "foo/bar@v1", "sha")).to be_nil
      expect(dummy_cli.send(:build_replacement_from_line, text, 0, 10, "other/action@v1", "sha")).to be_nil
      expect(dummy_cli.send(:build_replacement_from_line, "foobar\n", 0, 0, "foobar", "sha")).to be_nil

      quoted_text = '  - uses: "foo/bar@v1"' + "\n"
      content_col = quoted_text.index("foo/bar@v1")
      replacement = dummy_cli.send(:build_replacement_from_line, quoted_text, 0, content_col, "foo/bar@v1", "sha")
      expect(replacement).to include(start: content_col - 1, new_scalar: %("foo/bar@sha"))

      unchanged = dummy_cli.send(:apply_edits, "one\n", [{line: 5, start: 0, end: 1, new_scalar: "x"}])
      expect(unchanged).to include(changed: false, text: "one\n")
    end

    it "reports higher-version outdated info even when patch is the write target" do
      plan = dummy_cli.send(:determine_upgrade_plan, old_ref: "v1.2.0", repo_ref: "foo/bar", versions: versions, upgrade_level: "patch", client: client)

      expect(plan[:updates][:version]).to eq("1.2.3")
      expect(plan[:latest_outdated][:version]).to eq("2.0.0")
      expect(plan[:is_outdated]).to be(true)
    end

    it "does not upgrade stable pins to prerelease-only tags" do
      prerelease_versions = [
        {tag: "v1.3.0.pre", version_obj: Gem::Version.new("1.3.0.pre"), version: "1.3.0.pre", sha: "pre"},
        {tag: "v1.2.0", version_obj: Gem::Version.new("1.2.0"), version: "1.2.0", sha: "777"}
      ]

      plan = dummy_cli.send(:determine_upgrade_plan, old_ref: "v1.2.0", repo_ref: "foo/bar", versions: prerelease_versions, upgrade_level: "major", client: client)

      expect(plan[:updates]).to be_nil
      expect(plan[:latest_outdated]).to be_nil
      expect(plan[:is_outdated]).to be(false)
    end

    it "does not treat a version-equivalent but unresolved ref as a valid release tag" do
      allow(client).to receive(:commit_sha).with("foo/bar", "1.2.3").and_return(nil)

      plan = dummy_cli.send(:determine_upgrade_plan, old_ref: "1.2.3", repo_ref: "foo/bar", versions: versions, upgrade_level: "patch", client: client)

      expect(plan[:updates]).to include(sha: "aaa", version: nil, reason: described_class::NON_SHA_REASON)
      expect(plan[:current_version]).to eq("1.2.3")
      expect(plan[:is_outdated]).to be(true)
    end
  end

  describe described_class::GitHubClient do
    it "follows GitHub API redirects for transferred action repositories" do
      client = described_class.new(token: nil, api_base: Kettle::Gha::Pins::CLI::API_BASE, user_agent: "kettle-gha-pins")
      redirect = instance_double(Net::HTTPMovedPermanently, code: "301")
      success = instance_double(Net::HTTPOK, code: "200", body: JSON.generate("ok" => true))
      first_http = instance_double(Net::HTTP)
      second_http = instance_double(Net::HTTP)
      allow(redirect).to receive(:[]).with("location").and_return("https://api.github.com/repositories/123/releases")
      [first_http, second_http].each do |http|
        allow(http).to receive(:use_ssl=).with(true)
        allow(http).to receive(:open_timeout=).with(Kettle::Gha::Pins::CLI::DEFAULT_HTTP_OPEN_TIMEOUT_SECONDS)
        allow(http).to receive(:read_timeout=).with(Kettle::Gha::Pins::CLI::DEFAULT_HTTP_READ_TIMEOUT_SECONDS)
        allow(http).to receive(:respond_to?).with(:ssl_timeout=).and_return(true)
        allow(http).to receive(:ssl_timeout=).with(Kettle::Gha::Pins::CLI::DEFAULT_HTTP_OPEN_TIMEOUT_SECONDS)
      end
      allow(first_http).to receive(:start).and_yield(first_http)
      allow(second_http).to receive(:start).and_yield(second_http)
      allow(first_http).to receive(:request).and_return(redirect)
      allow(second_http).to receive(:request).and_return(success)
      allow(Net::HTTP).to receive(:new).and_return(first_http, second_http)

      expect(client.send(:request_json, "/repos/old/action/releases")).to eq("ok" => true)
    end

    it "bounds live GitHub refreshes and falls back to stale cache on timeout", freeze: Time.utc(2026, 6, 8, 12, 0, 1) do
      cache_path = File.join(workflow_root, "gha-cache.json")
      Timecop.freeze(Time.utc(2026, 6, 7, 11, 59, 0)) do
        Kettle::Gha::Pins::CLI::PersistentActionCache.new(path: cache_path).write_versions(
          "foo/bar",
          [{tag: "v1.2.0", version_obj: Gem::Version.new("1.2.0"), version: "1.2.0", sha: "a" * 40}]
        )
      end
      client = described_class.new(
        token: nil,
        api_base: Kettle::Gha::Pins::CLI::API_BASE,
        user_agent: "kettle-gha-pins",
        persistent_cache: Kettle::Gha::Pins::CLI::PersistentActionCache.new(path: cache_path),
        open_timeout: 1,
        read_timeout: 2
      )
      http = instance_double(Net::HTTP)
      allow(http).to receive(:use_ssl=).with(true)
      allow(http).to receive(:open_timeout=).with(1)
      allow(http).to receive(:read_timeout=).with(2)
      allow(http).to receive(:respond_to?).with(:ssl_timeout=).and_return(true)
      allow(http).to receive(:ssl_timeout=).with(1)
      allow(http).to receive(:start).and_raise(Timeout::Error, "execution expired")
      allow(Net::HTTP).to receive(:new).with("api.github.com", 443).and_return(http)

      versions = client.versions_for_repo("foo/bar")

      expect(versions.map { |entry| entry[:version] }).to eq(["1.2.0"])
    end

    it "loads release tag SHAs through matching refs instead of resolving every release commit" do
      client = described_class.new(token: nil, api_base: Kettle::Gha::Pins::CLI::API_BASE, user_agent: "kettle-gha-pins")
      releases = [
        {"tag_name" => "v1.2.0", "prerelease" => false},
        {"tag_name" => "v1.3.0", "prerelease" => false}
      ]
      refs = [
        {"ref" => "refs/tags/v1.2.0", "object" => {"type" => "commit", "sha" => "a" * 40}},
        {"ref" => "refs/tags/v1.3.0", "object" => {"type" => "commit", "sha" => "b" * 40}}
      ]
      allow(client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return(releases)
      allow(client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return(refs)
      expect(client).not_to receive(:commit_sha)

      versions = client.versions_for_repo("foo/bar")

      expect(versions.map { |entry| entry[:sha] }).to contain_exactly("a" * 40, "b" * 40)
    end

    it "includes version-like and major-line tags that do not have GitHub releases" do
      client = described_class.new(token: nil, api_base: Kettle::Gha::Pins::CLI::API_BASE, user_agent: "kettle-gha-pins")
      allow(client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return([
        {"tag_name" => "v1.0.0", "prerelease" => false}
      ])
      allow(client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return([
        {"ref" => "refs/tags/v1.0.0", "object" => {"type" => "commit", "sha" => "a" * 40}},
        {"ref" => "refs/tags/v1.0.1", "object" => {"type" => "commit", "sha" => "b" * 40}},
        {"ref" => "refs/tags/v1", "object" => {"type" => "commit", "sha" => "c" * 40}},
        {"ref" => "refs/tags/v2", "object" => {"type" => "commit", "sha" => "d" * 40}}
      ])

      versions = client.versions_for_repo("foo/bar")

      expect(versions).to match([
        include(tag: "v2", version: "2", sha: "d" * 40),
        include(tag: "v1.0.1", version: "1.0.1", sha: "b" * 40),
        include(tag: "v1.0.0", version: "1.0.0", sha: "a" * 40),
        include(tag: "v1", version: "1", sha: "c" * 40)
      ])
    end

    it "canonicalizes equivalent release and major-line tags to the more explicit version spelling" do
      client = described_class.new(token: nil, api_base: Kettle::Gha::Pins::CLI::API_BASE, user_agent: "kettle-gha-pins")
      allow(client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return([
        {"tag_name" => "v7.0.0", "prerelease" => false}
      ])
      allow(client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return([
        {"ref" => "refs/tags/v7", "object" => {"type" => "commit", "sha" => "a" * 40}},
        {"ref" => "refs/tags/v7.0.0", "object" => {"type" => "commit", "sha" => "a" * 40}}
      ])

      versions = client.versions_for_repo("foo/bar")

      expect(versions).to contain_exactly(
        include(tag: "v7.0.0", version: "7.0.0", sha: "a" * 40)
      )
    end

    it "prefers the concrete patch tag when a moving major-line tag points to the same SHA" do
      client = described_class.new(token: nil, api_base: Kettle::Gha::Pins::CLI::API_BASE, user_agent: "kettle-gha-pins")
      allow(client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return([
        {"tag_name" => "v7.0.0", "prerelease" => false},
        {"tag_name" => "v7.0.1", "prerelease" => false}
      ])
      allow(client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return([
        {"ref" => "refs/tags/v7.0.0", "object" => {"type" => "commit", "sha" => "a" * 40}},
        {"ref" => "refs/tags/v7", "object" => {"type" => "commit", "sha" => "b" * 40}},
        {"ref" => "refs/tags/v7.0.1", "object" => {"type" => "commit", "sha" => "b" * 40}}
      ])

      versions = client.versions_for_repo("foo/bar")

      expect(versions).to match([
        include(tag: "v7.0.1", version: "7.0.1", sha: "b" * 40),
        include(tag: "v7.0.0", version: "7.0.0", sha: "a" * 40),
        include(tag: "v7", version: "7", sha: "b" * 40)
      ])
    end

    it "does not canonicalize equivalent version spellings when the tag SHA is unknown" do
      client = described_class.new(token: nil, api_base: Kettle::Gha::Pins::CLI::API_BASE, user_agent: "kettle-gha-pins")
      allow(client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return([
        {"tag_name" => "v7.0.0", "prerelease" => false}
      ])
      allow(client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return([
        {"ref" => "refs/tags/v7", "object" => {"type" => "tag", "sha" => "a" * 40}},
        {"ref" => "refs/tags/v7.0.0", "object" => {"type" => "commit", "sha" => "b" * 40}}
      ])

      versions = client.versions_for_repo("foo/bar")

      expect(versions).to contain_exactly(
        include(tag: "v7", version: "7", sha: nil),
        include(tag: "v7.0.0", version: "7.0.0", sha: "b" * 40)
      )
    end

    it "defers annotated tag commit resolution until a specific version is needed" do
      client = described_class.new(token: nil, api_base: Kettle::Gha::Pins::CLI::API_BASE, user_agent: "kettle-gha-pins")
      allow(client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return([
        {"tag_name" => "v1.0.0", "prerelease" => false}
      ])
      allow(client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return([
        {"ref" => "refs/tags/v1.0.0", "object" => {"type" => "tag", "sha" => "1" * 40}},
        {"ref" => "refs/tags/v1.0.1", "object" => {"type" => "tag", "sha" => "2" * 40}}
      ])
      expect(client).not_to receive(:request_json).with(%r{/repos/foo/bar/git/tags/})

      versions = client.versions_for_repo("foo/bar")

      expect(versions.map { |entry| entry[:version] }).to eq(%w[1.0.1 1.0.0])
      expect(versions.map { |entry| entry[:sha] }).to eq([nil, nil])
      allow(client).to receive(:request_json).with("/repos/foo/bar/commits/v1.0.1").and_return({"sha" => "b" * 40})

      expect(client.commit_sha("foo/bar", "v1.0.1")).to eq("b" * 40)
    end

    it "does not dereference annotated tags that cannot be action release versions" do
      client = described_class.new(token: nil, api_base: Kettle::Gha::Pins::CLI::API_BASE, user_agent: "kettle-gha-pins")
      allow(client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return([
        {"tag_name" => "v1.0.0", "prerelease" => false}
      ])
      allow(client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return([
        {"ref" => "refs/tags/v1.0.0", "object" => {"type" => "commit", "sha" => "a" * 40}},
        {"ref" => "refs/tags/codeql-bundle-v2.25.6", "object" => {"type" => "tag", "sha" => "1" * 40}}
      ])
      expect(client).not_to receive(:request_json).with("/repos/foo/bar/git/tags/#{"1" * 40}")

      versions = client.versions_for_repo("foo/bar")

      expect(versions.map { |entry| entry[:version] }).to eq(["1.0.0"])
      expect(versions.map { |entry| entry[:sha] }).to eq(["a" * 40])
    end

    it "includes prerelease tags so existing prerelease pins are not downgraded" do
      client = described_class.new(token: nil, api_base: Kettle::Gha::Pins::CLI::API_BASE, user_agent: "kettle-gha-pins")
      allow(client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return([
        {"tag_name" => "v2.3.7", "prerelease" => true},
        {"tag_name" => "v2.3.6", "prerelease" => false}
      ])
      allow(client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return([
        {"ref" => "refs/tags/v2.3.7", "object" => {"type" => "commit", "sha" => "b" * 40}},
        {"ref" => "refs/tags/v2.3.6", "object" => {"type" => "commit", "sha" => "a" * 40}}
      ])

      versions = client.versions_for_repo("foo/bar")

      expect(versions.map { |entry| entry[:version] }).to eq(%w[2.3.7 2.3.6])
      expect(versions.map { |entry| entry[:sha] }).to eq(["b" * 40, "a" * 40])
    end

    it "uses fresh persistent cache entries without GitHub API calls", freeze: Time.utc(2026, 6, 8, 12, 0, 0) do
      cache = Kettle::Gha::Pins::CLI::PersistentActionCache.new(
        path: File.join(workflow_root, "gha-cache.json")
      )
      cache.write_versions(
        "foo/bar",
        [
          {tag: "v1.2.3", version_obj: Gem::Version.new("1.2.3"), version: "1.2.3", sha: "a" * 40},
          {tag: "v1.3.0", version_obj: Gem::Version.new("1.3.0"), version: "1.3.0", sha: "b" * 40},
          {tag: "v2.0.0", version_obj: Gem::Version.new("2.0.0"), version: "2.0.0", sha: "c" * 40}
        ]
      )
      client = described_class.new(
        token: nil,
        api_base: Kettle::Gha::Pins::CLI::API_BASE,
        user_agent: "kettle-gha-pins",
        persistent_cache: cache
      )
      expect(client).not_to receive(:request_json)

      versions = client.versions_for_repo("foo/bar")

      expect(versions.map { |entry| entry[:version] }).to eq(%w[2.0.0 1.3.0 1.2.3])
    end

    it "reports persistent cache hits as cached action checks", freeze: Time.utc(2026, 6, 8, 12, 0, 0) do
      File.write(
        workflow_path,
        <<~YAML
          name: ci
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: foo/bar@v1.2.3
        YAML
      )
      cache_path = File.join(workflow_root, "gha-cache.json")
      Kettle::Gha::Pins::CLI::PersistentActionCache.new(path: cache_path).write_versions(
        "foo/bar",
        [
          {tag: "v1.2.3", version_obj: Gem::Version.new("1.2.3"), version: "1.2.3", sha: "a" * 40},
          {tag: "v1.3.0", version_obj: Gem::Version.new("1.3.0"), version: "1.3.0", sha: "b" * 40}
        ]
      )
      cli_client = Kettle::Gha::Pins::CLI::GitHubClient.new(
        token: nil,
        api_base: Kettle::Gha::Pins::CLI::API_BASE,
        user_agent: "kettle-gha-pins",
        persistent_cache: Kettle::Gha::Pins::CLI::PersistentActionCache.new(path: cache_path)
      )
      allow(Kettle::Gha::Pins::CLI::GitHubClient).to receive(:new).and_return(cli_client)
      expect(cli_client).not_to receive(:request_json)
      err = StringIO.new

      cli = Kettle::Gha::Pins::CLI.new(["--root", workflow_root, "--upgrade", "minor", "--cache-path", cache_path], err: err)
      expect(cli.run!).to eq(0)

      expect(err.string).to include("Action resolution checks: 1 cached, 0 live.")
    end

    it "bypasses fresh cache when refreshing and preserves unrelated cached actions", freeze: Time.utc(2026, 6, 8, 12, 5, 0) do
      cache_path = File.join(workflow_root, "gha-cache.json")
      cache = Kettle::Gha::Pins::CLI::PersistentActionCache.new(path: cache_path)
      cache.write_versions(
        "other/action",
        [{tag: "v9.0.0", version_obj: Gem::Version.new("9.0.0"), version: "9.0.0", sha: "9" * 40}]
      )
      cache.write_versions(
        "foo/bar",
        [{tag: "v1.2.0", version_obj: Gem::Version.new("1.2.0"), version: "1.2.0", sha: "a" * 40}]
      )
      client = described_class.new(
        token: nil,
        api_base: Kettle::Gha::Pins::CLI::API_BASE,
        user_agent: "kettle-gha-pins",
        persistent_cache: Kettle::Gha::Pins::CLI::PersistentActionCache.new(path: cache_path),
        refresh_cache: true
      )
      allow(client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return([
        {"tag_name" => "v1.2.3", "prerelease" => false},
        {"tag_name" => "v1.3.0", "prerelease" => false},
        {"tag_name" => "v2.0.0", "prerelease" => false}
      ])
      allow(client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return([
        {"ref" => "refs/tags/v1.2.3", "object" => {"type" => "commit", "sha" => "b" * 40}},
        {"ref" => "refs/tags/v1.3.0", "object" => {"type" => "commit", "sha" => "c" * 40}},
        {"ref" => "refs/tags/v2.0.0", "object" => {"type" => "commit", "sha" => "d" * 40}}
      ])

      versions = client.versions_for_repo("foo/bar")
      cached = JSON.parse(File.read(cache_path))

      expect(versions.map { |entry| entry[:version] }).to eq(%w[2.0.0 1.3.0 1.2.3])
      expect(cached.fetch("actions")).to include("other/action")
      expect(cached.dig("actions", "foo/bar", "versions")).to include("1.2.0", "1.2.3", "1.3.0", "2.0.0")
      expect(cached.dig("actions", "foo/bar", "targets", "patch", "1.2", "version")).to eq("1.2.3")
      expect(cached.dig("actions", "foo/bar", "targets", "minor", "1", "version")).to eq("1.3.0")
      expect(cached.dig("actions", "foo/bar", "targets", "major", "*", "version")).to eq("2.0.0")
    end

    it "caches major-line tags as major-only targets", freeze: Time.utc(2026, 6, 8, 12, 5, 0) do
      cache_path = File.join(workflow_root, "gha-cache.json")
      client = described_class.new(
        token: nil,
        api_base: Kettle::Gha::Pins::CLI::API_BASE,
        user_agent: "kettle-gha-pins",
        persistent_cache: Kettle::Gha::Pins::CLI::PersistentActionCache.new(path: cache_path)
      )
      allow(client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return([
        {"tag_name" => "v2", "prerelease" => false}
      ])
      allow(client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return([
        {"ref" => "refs/tags/v2", "object" => {"type" => "commit", "sha" => "b" * 40}}
      ])

      versions = client.versions_for_repo("foo/bar")
      cached = JSON.parse(File.read(cache_path))

      expect(versions.map { |entry| entry[:version] }).to eq(["2"])
      expect(cached.dig("actions", "foo/bar", "versions")).to include("2")
      expect(cached.dig("actions", "foo/bar", "targets", "patch")).to eq({})
      expect(cached.dig("actions", "foo/bar", "targets", "minor")).to eq({})
      expect(cached.dig("actions", "foo/bar", "targets", "major", "*", "version")).to eq("2")
    end

    it "ignores persistent cache entries from older schemas", freeze: Time.utc(2026, 6, 8, 12, 5, 0) do
      cache_path = File.join(workflow_root, "gha-cache.json")
      File.write(
        cache_path,
        JSON.pretty_generate(
          "version" => Kettle::Gha::Pins::CLI::PersistentActionCache::VERSION - 1,
          "actions" => {
            "foo/bar" => {
              "versions" => {
                "1.0.0" => {
                  "tag" => "v1.0.0",
                  "version" => "1.0.0",
                  "sha" => "a" * 40,
                  "cached_at" => "2026-06-08T12:00:00Z"
                }
              }
            }
          }
        )
      )
      client = described_class.new(
        token: nil,
        api_base: Kettle::Gha::Pins::CLI::API_BASE,
        user_agent: "kettle-gha-pins",
        persistent_cache: Kettle::Gha::Pins::CLI::PersistentActionCache.new(path: cache_path)
      )
      allow(client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return([
        {"tag_name" => "v1.0.1", "prerelease" => false}
      ])
      allow(client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return([
        {"ref" => "refs/tags/v1.0.1", "object" => {"type" => "commit", "sha" => "b" * 40}}
      ])

      versions = client.versions_for_repo("foo/bar")

      expect(versions.map { |entry| entry[:version] }).to eq(["1.0.1"])
    end

    it "refreshes stale persistent cache entries after the TTL", freeze: Time.utc(2026, 6, 8, 12, 0, 1) do
      cache_path = File.join(workflow_root, "gha-cache.json")
      Timecop.freeze(Time.utc(2026, 6, 7, 11, 59, 0)) do
        Kettle::Gha::Pins::CLI::PersistentActionCache.new(path: cache_path).write_versions(
          "foo/bar",
          [{tag: "v1.2.0", version_obj: Gem::Version.new("1.2.0"), version: "1.2.0", sha: "a" * 40}]
        )
      end
      client = described_class.new(
        token: nil,
        api_base: Kettle::Gha::Pins::CLI::API_BASE,
        user_agent: "kettle-gha-pins",
        persistent_cache: Kettle::Gha::Pins::CLI::PersistentActionCache.new(path: cache_path)
      )
      allow(client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return([
        {"tag_name" => "v1.2.1", "prerelease" => false}
      ])
      allow(client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return([
        {"ref" => "refs/tags/v1.2.1", "object" => {"type" => "commit", "sha" => "b" * 40}}
      ])

      versions = client.versions_for_repo("foo/bar")

      expect(versions.map { |entry| entry[:version] }).to eq(["1.2.1"])
    end

    it "persists live commit SHA lookups for reuse by the next client run", freeze: Time.utc(2026, 6, 8, 12, 0, 0) do
      cache_path = File.join(workflow_root, "gha-cache.json")
      cache = Kettle::Gha::Pins::CLI::PersistentActionCache.new(path: cache_path)
      first_client = described_class.new(
        token: nil,
        api_base: Kettle::Gha::Pins::CLI::API_BASE,
        user_agent: "kettle-gha-pins",
        persistent_cache: cache
      )
      allow(first_client).to receive(:request_json).with("/repos/foo/bar/commits/v1.2.3").and_return({"sha" => "a" * 40})

      expect(first_client.commit_sha("foo/bar", "v1.2.3")).to eq("a" * 40)

      second_client = described_class.new(
        token: nil,
        api_base: Kettle::Gha::Pins::CLI::API_BASE,
        user_agent: "kettle-gha-pins",
        persistent_cache: Kettle::Gha::Pins::CLI::PersistentActionCache.new(path: cache_path)
      )
      expect(second_client).not_to receive(:request_json)

      expect(second_client.commit_sha("foo/bar", "v1.2.3")).to eq("a" * 40)
      expect(JSON.parse(File.read(cache_path)).dig("actions", "foo/bar", "refs", "v1.2.3", "sha")).to eq("a" * 40)
    end
  end

  describe "run! output" do
    let(:client_versions) do
      [
        {
          tag: "v1.3.0",
          version_obj: Gem::Version.new("1.3.0"),
          version: "1.3.0",
          sha: "bbb",
          released_at: "2026-07-22T12:00:00Z"
        },
        {
          tag: "v2.0.0",
          version_obj: Gem::Version.new("2.0.0"),
          version: "2.0.0",
          sha: "ccc",
          released_at: "2026-07-01T12:00:00Z"
        },
        {
          tag: "v1.2.0",
          version_obj: Gem::Version.new("1.2.0"),
          version: "1.2.0",
          sha: "aaa"
        }
      ]
    end

    before do
      stub_github_client(
        versions: client_versions,
        commit_shas: {
          "v1.2.0" => "aaa",
          "v1.3.0" => "bbb",
          "v2.0.0" => "ccc"
        }
      )
    end

    it "emits JSON report with outdated_pins and version-equivalent values" do
      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor", "--json"])

      payload = nil
      expect do
        cli.run!
      end.to output(satisfy { |stdout|
        payload = JSON.parse(stdout)
      }).to_stdout

      expect(payload.fetch("outdated_pins")).to contain_exactly(
        a_hash_including(
          "path" => workflow_path,
          "line" => 7,
          "action" => "foo/bar",
          "old_ref" => "v1.2.0",
          "old_version" => "1.2.0",
          "new_ref" => "ccc",
          "new_version" => "2.0.0",
          "upgrade_level" => "minor",
          "reason" => described_class::UPGRADE_REASON
        )
      )
      expect(payload.fetch("planned_changes").first["old_version"]).to eq("1.2.0")
      expect(payload.fetch("planned_changes").first["new_version"]).to eq("1.3.0")
    end

    it "runs with no persistent cache when cache path is blank" do
      cli = described_class.new(["--root", workflow_root, "--json", "--cache-path", ""])

      expect(cli.run!).to eq(0)
      expect(described_class::GitHubClient).to have_received(:new).with(
        hash_including(persistent_cache: nil)
      )
    end

    it "persists dry-run cache data for the next write run", freeze: Time.utc(2026, 7, 23, 12, 0, 0) do
      File.write(
        workflow_path,
        <<~YAML
          name: ci
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: foo/bar@v1.2.0 # v1.2.0
        YAML
      )
      cache_path = File.join(workflow_root, "gha-cache.json")
      allow(described_class::GitHubClient).to receive(:new).and_call_original
      first_client = described_class::GitHubClient.new(
        token: nil,
        api_base: described_class::API_BASE,
        user_agent: "kettle-gha-pins",
        persistent_cache: described_class::PersistentActionCache.new(path: cache_path)
      )
      second_client = described_class::GitHubClient.new(
        token: nil,
        api_base: described_class::API_BASE,
        user_agent: "kettle-gha-pins",
        persistent_cache: described_class::PersistentActionCache.new(path: cache_path)
      )
      allow(described_class::GitHubClient).to receive(:new).and_return(first_client, second_client)
      allow(first_client).to receive(:request_json).with("/repos/foo/bar/releases?per_page=100").and_return([
        {"tag_name" => "v1.2.0", "published_at" => "2026-07-01T12:00:00Z"},
        {"tag_name" => "v1.3.0", "published_at" => "2026-07-22T12:00:00Z"}
      ])
      allow(first_client).to receive(:request_json).with("/repos/foo/bar/git/matching-refs/tags/").and_return([
        {"ref" => "refs/tags/v1.2.0", "object" => {"type" => "commit", "sha" => "a" * 40}},
        {"ref" => "refs/tags/v1.3.0", "object" => {"type" => "commit", "sha" => "b" * 40}}
      ])
      allow(first_client).to receive(:request_json).with("/repos/foo/bar/commits/v1.2.0").and_return({"sha" => "a" * 40})
      expect(second_client).not_to receive(:request_json)

      dry_run = described_class.new(["--root", workflow_root, "--upgrade", "minor", "--cache-path", cache_path])
      write_run = described_class.new(["--root", workflow_root, "--upgrade", "minor", "--cache-path", cache_path, "--write"])

      expect(dry_run.run!).to eq(0)
      expect(JSON.parse(File.read(cache_path)).dig("actions", "foo/bar", "targets", "minor", "1", "version")).to eq("1.3.0")
      expect(write_run.run!).to eq(0)
      expect(File.read(workflow_path)).to include("uses: foo/bar@#{"b" * 40} # v1.3.0")
    end

    it "emits human text report with version-equivalent outdated pins summary" do
      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor"])

      expect do
        cli.run!
      end.to output(
        %r{Outdated actions \(1\):\nAction Current Latest Location Reason\nfoo/bar 1\.2\.0 1\.3\.0 #{Regexp.escape(workflow_path)}:\d+ #{Regexp.escape(described_class::UPGRADE_REASON)}}
      ).to_stdout
    end

    it "handles workflow files without external action refs" do
      File.write(
        workflow_path,
        <<~YAML
          name: ci
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: ./local-action
        YAML
      )
      cli = described_class.new(["--root", workflow_root])

      expect do
        expect(cli.run!).to eq(0)
      end.to output(/Outdated actions: none/).to_stdout
    end

    it "fails in check mode and recommends the write command when updates are needed" do
      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor", "--check"])

      expect do
        expect(cli.run!).to eq(3)
      end.to output(/Outdated actions \(1\):.*Recommended fix: kettle-gha-pins --write --upgrade minor/m).to_stdout
    end

    it "warns without failing check mode for fresh release upgrades inside cooldown" do
      clock = -> { Time.utc(2026, 7, 23, 12, 0, 0) }
      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor", "--check", "--cooldown-days", "3"], clock: clock)

      expect do
        expect(cli.run!).to eq(0)
      end.to output(/Cooldown warnings \(1\):.*foo\/bar 1\.2\.0 1\.3\.0 .*2026-07-25T12:00:00Z.*Outdated actions: none.*No change candidates found\./m).to_stdout
    end

    it "emits cooldown warnings in JSON reports" do
      clock = -> { Time.utc(2026, 7, 23, 12, 0, 0) }
      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor", "--check", "--cooldown-days", "3", "--json"], clock: clock)

      payload = nil
      expect do
        expect(cli.run!).to eq(0)
      end.to output(satisfy { |stdout|
        payload = JSON.parse(stdout)
      }).to_stdout

      expect(payload.fetch("planned_changes")).to be_empty
      expect(payload.fetch("cooldown_changes")).to contain_exactly(
        a_hash_including(
          "action" => "foo/bar",
          "old_version" => "1.2.0",
          "new_version" => "1.3.0",
          "released_at" => "2026-07-22T12:00:00Z",
          "cooldown_until" => "2026-07-25T12:00:00Z"
        )
      )
    end

    it "does not fail check mode for broader outdated pins outside the selected upgrade level" do
      cli = described_class.new(["--root", workflow_root, "--upgrade", "patch", "--check"])

      expect do
        expect(cli.run!).to eq(0)
      end.to output(
        /Outdated pins \(1\):.*Outdated actions: none.*No change candidates found\./m
      ).to_stdout
    end

    it "rewrites unresolved version-equivalent refs to release SHAs instead of stripped tag names" do
      File.write(
        workflow_path,
        <<~YAML
          name: ci
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: foo/bar@1.2.0 # v1.2.0
        YAML
      )
      cli_client = instance_double(described_class::GitHubClient)
      allow(described_class::GitHubClient).to receive(:new).and_return(cli_client)
      allow(cli_client).to receive(:versions_for_repo).with("foo/bar").and_return(client_versions)
      allow(cli_client).to receive(:commit_sha).with("foo/bar", "1.2.0").and_return(nil)

      cli = described_class.new(["--root", workflow_root, "--upgrade", "patch", "--write"])
      cli.run!

      expect(File.read(workflow_path)).to include("uses: foo/bar@aaa # v1.2.0")
      expect(File.read(workflow_path)).not_to include("foo/bar@1.2.0")
    end

    it "updates adjacent version comments when upgrading to a newer release SHA" do
      File.write(
        workflow_path,
        <<~YAML
          name: ci
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: foo/bar@aaa # v1.2.0
        YAML
      )
      cli_client = instance_double(described_class::GitHubClient)
      allow(described_class::GitHubClient).to receive(:new).and_return(cli_client)
      allow(cli_client).to receive(:versions_for_repo).with("foo/bar").and_return(client_versions)
      allow(cli_client).to receive(:commit_sha).with("foo/bar", "aaa").and_return("aaa")

      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor", "--write"])
      cli.run!

      expect(File.read(workflow_path)).to include("uses: foo/bar@bbb # v1.3.0")
      expect(File.read(workflow_path)).not_to include("# v1.2.0")
    end

    it "updates stale version comments even when the SHA is already current" do
      File.write(
        workflow_path,
        <<~YAML
          name: ci
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: foo/bar@bbb # v1.2.0
        YAML
      )
      cli_client = instance_double(described_class::GitHubClient)
      allow(described_class::GitHubClient).to receive(:new).and_return(cli_client)
      allow(cli_client).to receive(:versions_for_repo).with("foo/bar").and_return(client_versions)
      allow(cli_client).to receive(:commit_sha).with("foo/bar", "bbb").and_return("bbb")

      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor", "--write"])
      cli.run!

      expect(File.read(workflow_path)).to include("uses: foo/bar@bbb # v1.3.0")
      expect(File.read(workflow_path)).not_to include("# v1.2.0")
    end

    it "updates major-line version comments to the canonical explicit equivalent once and stays clean" do
      File.write(
        workflow_path,
        <<~YAML
          name: ci
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: foo/bar@bbb # v7.0.0
        YAML
      )
      cli_client = instance_double(described_class::GitHubClient)
      allow(described_class::GitHubClient).to receive(:new).and_return(cli_client)
      allow(cli_client).to receive(:versions_for_repo).with("foo/bar").and_return([
        {tag: "v7.0.0", version_obj: Gem::Version.new("7.0.0"), version: "7.0.0", sha: "bbb"}
      ])
      allow(cli_client).to receive(:commit_sha).with("foo/bar", "bbb").and_return("bbb")

      first_run = described_class.new(["--root", workflow_root, "--upgrade", "major", "--write"])
      second_run = described_class.new(["--root", workflow_root, "--upgrade", "major", "--check"])

      expect(first_run.run!).to eq(0)
      expect(File.read(workflow_path)).to include("uses: foo/bar@bbb # v7.0.0")
      expect(second_run.run!).to eq(0)
    end

    it "updates shorthand major-line version comments to the canonical explicit equivalent" do
      File.write(
        workflow_path,
        <<~YAML
          name: ci
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: foo/bar@bbb # v7
        YAML
      )
      cli_client = instance_double(described_class::GitHubClient)
      allow(described_class::GitHubClient).to receive(:new).and_return(cli_client)
      allow(cli_client).to receive(:versions_for_repo).with("foo/bar").and_return([
        {tag: "v7.0.0", version_obj: Gem::Version.new("7.0.0"), version: "7.0.0", sha: "bbb"}
      ])
      allow(cli_client).to receive(:commit_sha).with("foo/bar", "bbb").and_return("bbb")

      cli = described_class.new(["--root", workflow_root, "--upgrade", "major", "--write"])

      expect(cli.run!).to eq(0)
      expect(File.read(workflow_path)).to include("uses: foo/bar@bbb # v7.0.0")
      expect(File.read(workflow_path)).not_to include("# v7\n")
    end

    it "returns failure and renders line-specific errors when a workflow token cannot be replaced" do
      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor"])
      allow(cli).to receive(:build_replacement_from_line).and_return(nil)

      expect do
        expect(cli.run!).to eq(2)
      end.to output(/Errors:\n- #{Regexp.escape(workflow_path)}:7 token_parse_failed/m).to_stdout
    end

    it "records read and YAML parse failures" do
      cli = described_class.new(["--root", workflow_root])
      state = {files_scanned: 0, failures: 0, errors: []}

      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(workflow_path).and_raise(Errno::EACCES, workflow_path)

      expect(cli.send(:load_workflows, [workflow_path], state)).to be_empty
      expect(state[:errors]).to contain_exactly(include(path: workflow_path, error: /read_error/))

      allow(File).to receive(:read).with(workflow_path).and_return(":\n")
      state = {files_scanned: 0, failures: 0, errors: []}

      expect(cli.send(:load_workflows, [workflow_path], state)).to be_empty
      expect(state[:errors]).to contain_exactly(include(path: workflow_path, error: /yaml_parse_error/))
    end

    it "renders errors without line numbers" do
      cli = described_class.new(["--root", workflow_root])
      state = {
        files_scanned: 0,
        files_with_changes: 0,
        updates: 0,
        failures: 1,
        errors: [{path: workflow_path, error: "read_error"}],
        changed_files: [],
        planned_changes: [],
        outdated_pins: []
      }

      expect { cli.send(:print_report, state) }.to output(/Errors:\n- #{Regexp.escape(workflow_path)} read_error/m).to_stdout
    end

    it "writes edits without YAML validation when validation is disabled" do
      File.write(
        workflow_path,
        <<~YAML
          name: ci
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: "foo/bar@v1.2.0"
        YAML
      )
      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor", "--write", "--no-validate"])

      expect(cli).not_to receive(:validate_yaml!)
      expect(cli.run!).to eq(0)
      expect(File.read(workflow_path)).to include(%("foo/bar@bbb"))
    end

    it "calls GitHub release-version lookup for each workflow action when evaluating pins" do
      cli_client = instance_double(described_class::GitHubClient)
      allow(described_class::GitHubClient).to receive(:new).and_return(cli_client)
      allow(cli_client).to receive(:versions_for_repo).with("foo/bar").and_return(client_versions)
      allow(cli_client).to receive(:commit_sha).and_return("aaa")

      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor"])
      cli.run!

      expect(cli_client).to have_received(:versions_for_repo).with("foo/bar")
    end

    it "reuses one resolution plan for duplicate action repos" do
      File.write(
        workflow_path,
        <<~YAML
          name: ci
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: foo/bar@v1.2.0
                - uses: foo/bar@v1.2.0
        YAML
      )
      cli_client = instance_double(described_class::GitHubClient)
      allow(described_class::GitHubClient).to receive(:new).and_return(cli_client)
      expect(cli_client).to receive(:versions_for_repo).with("foo/bar").once.and_return(client_versions)
      allow(cli_client).to receive(:commit_sha).and_return("aaa")

      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor"])
      cli.run!
    end

    it "emits progress feedback to stderr for human output" do
      err = StringIO.new
      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor", "--no-progress"], err: err)
      expect(cli.run!).to eq(0)
      expect(err.string).to eq("")

      err = StringIO.new
      allow(err).to receive(:tty?).and_return(true)
      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor"], err: err)
      cli.run!

      expect(err.string).to include("Discovering workflow files")
      expect(err.string).to include("Discovered 1 workflow file")
      expect(err.string).to include("Resolving 1 GitHub action reference")
      expect(err.string).to include("Actions live")
      expect(err.string).to include("Action resolution checks: 0 cached, 1 live.")
      expect(err.string).not_to include("Resolved foo/bar@v1.2.0 in")
    end

    it "keeps progress disabled by default for JSON output" do
      err = StringIO.new
      cli = described_class.new(["--root", workflow_root, "--upgrade", "minor", "--json"], err: err)

      cli.run!

      expect(err.string).to eq("")
    end
  end
end
# rubocop:enable RSpec/VerifiedDoubles, RSpec/MessageSpies, ThreadSafety/ClassInstanceVariable
