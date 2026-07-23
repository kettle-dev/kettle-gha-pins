# frozen_string_literal: true

module Kettle
  module Gha
    module Pins
      # Shared planning rules for converting and upgrading GitHub Action refs.
      module ActionResolver
        module_function

        def resolve_action_plan(cache:, client:, repo_ref:, old_ref:, upgrade_level: DEFAULT_UPGRADE_LEVEL)
          versions = if cache.key?(repo_ref)
            cache.fetch(repo_ref)
          else
            cache[repo_ref] = client.versions_for_repo(repo_ref)
          end

          determine_upgrade_plan(
            old_ref: old_ref,
            repo_ref: repo_ref,
            versions: versions,
            upgrade_level: upgrade_level,
            client: client
          )
        end

        def determine_upgrade_plan(old_ref:, repo_ref:, versions:, upgrade_level:, client:)
          level = VersionRubric.normalize_upgrade_level(upgrade_level)

          current_ref = old_ref.to_s.strip
          return {is_outdated: false, updates: nil, reason: nil, current_version: nil} if current_ref.empty?

          available_versions = versions || []
          latest = available_versions.first

          current_sha = if SHA_RE.match?(current_ref) || WEAK_SHA_RE.match?(current_ref)
            current_ref
          else
            client.commit_sha(repo_ref, current_ref)
          end
          parsed_current_ref = VersionRubric.parse(current_ref)
          version_equivalent_entry = if parsed_current_ref
            available_versions.find { |entry| entry[:version_obj] == parsed_current_ref }
          end
          matched_entry = matching_version_entry(available_versions, current_ref, current_sha, client, repo_ref)
          unresolved_version_ref = false
          if matched_entry.nil? && current_sha.to_s.empty? && version_equivalent_entry && non_sha?(current_ref)
            matched_entry = version_equivalent_entry
            unresolved_version_ref = true
          end
          current_version = matched_entry ? matched_entry[:version] : nil

          updates = nil
          reason = nil
          is_outdated = false
          latest_outdated = nil

          if current_version
            latest_outdated = VersionRubric.latest_outdated_target(current_version, available_versions)
            target = VersionRubric.choose_upgrade_target(current_version, available_versions, level)
            target_sha = target ? version_entry_sha(target, client, repo_ref) : nil
            latest_outdated_sha = latest_outdated ? version_entry_sha(latest_outdated, client, repo_ref) : nil
            if latest_outdated && stale_sha?(current_ref, latest_outdated_sha)
              latest_outdated = latest_outdated.merge(sha: latest_outdated_sha)
              is_outdated = true
              reason = UPGRADE_REASON
            end
            if target && stale_sha?(current_ref, target_sha)
              updates = {
                sha: target_sha,
                version: target[:version],
                released_at: target[:released_at],
                reason: UPGRADE_REASON
              }
              reason ||= UPGRADE_REASON
            end
            if updates.nil? && unresolved_version_ref
              matched_sha = version_entry_sha(matched_entry, client, repo_ref)
              if stale_sha?(current_ref, matched_sha)
                updates = {
                  sha: matched_sha,
                  version: nil,
                  reason: NON_SHA_REASON
                }
                latest_outdated ||= matched_entry.merge(sha: matched_sha)
                is_outdated = true
                reason ||= NON_SHA_REASON
              end
            end
          elsif current_sha && non_sha?(current_ref)
            if stale_sha?(current_ref, current_sha)
              updates = {
                sha: current_sha,
                version: nil,
                reason: NON_SHA_REASON
              }
              reason = NON_SHA_REASON
            end
          elsif current_sha
            latest_sha = latest ? version_entry_sha(latest, client, repo_ref) : nil
            if latest && stale_sha?(current_ref, latest_sha)
              latest_outdated = latest.merge(sha: latest_sha)
              updates = {
                sha: latest_sha,
                version: latest[:version],
                reason: STALE_SHA_REASON
              }
              reason = STALE_SHA_REASON
              is_outdated = true
            end
          end

          {
            is_outdated: is_outdated,
            updates: updates,
            reason: reason,
            current_version: current_version,
            latest_outdated: latest_outdated
          }
        end

        def matching_version_entry(versions, current_ref, current_sha, client, repo_ref)
          parsed = VersionRubric.parse(current_ref)
          if parsed
            direct = versions.find { |entry| entry[:tag] == current_ref }
            return direct if direct
          end

          return nil unless current_sha

          prefix = current_sha[0, 40]
          versions.find do |entry|
            sha = version_entry_sha(entry, client, repo_ref)
            sha.to_s.start_with?(prefix)
          end
        end

        def version_entry_sha(entry, client, repo_ref)
          return nil unless entry
          return entry[:sha] unless entry[:sha].to_s.empty?

          sha = client.commit_sha(repo_ref, entry[:tag])
          entry[:sha] = sha
          sha
        end

        def short_sha?(candidate)
          return false unless candidate

          WEAK_SHA_RE.match?(candidate)
        end

        def non_sha?(candidate)
          !SHA_RE.match?(candidate) && !WEAK_SHA_RE.match?(candidate)
        end

        def stale_sha?(current, latest)
          return false if current.nil? || latest.nil?

          current_down = current.downcase
          latest_down = latest.downcase

          if current_down.length < latest_down.length
            !latest_down.start_with?(current_down)
          else
            current_down != latest_down
          end
        end
      end

      class << self
        def resolve_action_plan(**kwargs)
          ActionResolver.resolve_action_plan(**kwargs)
        end

        def determine_upgrade_plan(**kwargs)
          ActionResolver.determine_upgrade_plan(**kwargs)
        end

        def matching_version_entry(versions, current_ref, current_sha, client, repo_ref)
          ActionResolver.matching_version_entry(versions, current_ref, current_sha, client, repo_ref)
        end

        def version_entry_sha(entry, client, repo_ref)
          ActionResolver.version_entry_sha(entry, client, repo_ref)
        end

        def short_sha?(candidate)
          ActionResolver.short_sha?(candidate)
        end

        def non_sha?(candidate)
          ActionResolver.non_sha?(candidate)
        end

        def stale_sha?(current, latest)
          ActionResolver.stale_sha?(current, latest)
        end
      end
    end
  end
end
