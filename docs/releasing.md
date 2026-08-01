# Releasing mtest

This is the maintainer runbook for a stable GitHub release and the matching
`modular-community` package. The workflows fail closed; start a fresh dispatch
when retrying rather than using GitHub's **Re-run jobs** button.
Never delete or move a published tag to recover from a failed run.

## One-time repository setup

1. Enable private vulnerability reporting under **Settings → Security →
   Private vulnerability reporting**.
2. Enable immutable releases under **Settings → General → Releases**.
3. Under **Settings → Actions → General**, set the default workflow token
   permission to read-only and leave workflow-created pull-request approval
   disabled.
4. Create the protected environments `github-release` and
   `community-publish`. Restrict both to the selected branch `main`, require
   review by `mikeleppane`, leave **Prevent self-review** unchecked, and
   disable administrator bypass.
5. Add these environment variables:

   - `github-release`: `RELEASE_ENVIRONMENT_CONFIGURED=true` and
     `RELEASE_IMMUTABILITY_CONFIGURED=true`
   - `community-publish`: `COMMUNITY_ENVIRONMENT_CONFIGURED=true` and
     `COMMUNITY_FORK_OWNER=mikeleppane`

6. Keep the normal-account fork
   `mikeleppane/modular-community` synchronized enough for GitHub to recognize
   it as a fork of `modular/modular-community`.
7. Under **Settings → Pages**, set the build source to **GitHub Actions**. The
   `Docs` workflow's deploy job cannot publish until Pages is enabled that way.
8. Create the floating `v1` tag on the merge that first ships `action.yml`:
   `git tag v1 <merge commit>` then `git push origin v1`. Do this once, at that
   merge, and not at a release. `v1` is a major-version alias rather than a
   release tag — the release procedure below only ever *moves* it, so nothing
   there brings it into existence, and until it exists `mikeleppane/mtest@v1`
   does not resolve and every workflow copied from the README or the
   documentation site fails with `Unable to resolve action`.

Do not create the fork token until the first exact-main dry run succeeds. When
it is needed, create an expiring fine-grained personal access token owned by
`mikeleppane`, restricted to the single repository
`mikeleppane/modular-community`, with only **Contents: Read and write**.
Store it as the `COMMUNITY_FORK_TOKEN` secret in the `community-publish`
environment. Never use a classic token or grant access to the upstream
repository.

The workflow rejects classic-token scopes and verifies the authenticated
account, expiry, fork relationship, and effective write access before any Git
mutation. GitHub's API does not reveal whether a fine-grained token was also
granted to additional repositories, so confirm the single-repository selection
in the token settings.

GitHub CLI 2.96.0 or newer is required when manually inspecting immutable
release responses.

## Release procedure

1. Merge the version, contract, and `CHANGELOG.md` changes to `main`. The
   changelog entry names the release version, its date, the Mojo pin, the
   supported platforms, and — once step 10 passes — where it is published. A
   release without an entry is not ready to cut. This merge automatically
   starts `CI` for the exact resulting `main` push.
2. Without waiting for `CI`, run **Community Publish** from `main` with mode
   `dry-run`, no tag, and build number `0`. Both supported platform builds and
   the linux-aarch64 selector proof must pass. Record the workflow run ID.
3. Wait for both the dry run and the exact resulting `main` push to finish all
   required `CI` checks successfully.
4. If this is the first release, create the fine-grained fork token described
   above and add `COMMUNITY_FORK_OWNER=mikeleppane`.
5. Run **Release** from `main`, entering the stable version without `v` and the
   dry-run ID. Approve the `github-release` environment after checking the
   displayed commit and version.
6. Move the floating `v1` tag onto the released commit and force-push it:
   `git tag -f v1 <released commit>` then `git push --force origin v1`. This
   step moves the alias created in the one-time setup above; it never creates
   one, so a repository where that step was skipped has no `v1` for this
   command to move. It is deliberate and moves nothing the rule above
   protects: the release tag stays exactly where it is, and `v1` is not a
   release tag but a major-version alias. A floating major tag is the
   convention
   consumers of GitHub Actions expect, and it is the only reason the published
   composite action resolves at `mikeleppane/mtest@v1`. Skip this step and
   every adopter of the action stays on the previous 1.x release without being
   told; delete the tag and their workflows fail to resolve it at all. Stop
   moving it at 2.0.0 and start a `v2` alias instead, since the tag promises
   the major version it names.
7. The successful new release triggers **Community Publish** in `prepare`
   mode. Approve the `community-publish` environment. The workflow rechecks
   the upstream tip, public channels, recipe digest, fork identity, and token
   expiration before it prepares the fork branch.
8. Open the compare URL in the workflow summary. Disable **Allow edits from
   maintainers**, use the generated title and validation facts, and open the
   pull request against `modular/modular-community`.
9. Wait for the upstream `OK to test` label, CI, review, merge, and channel
   build.
10. Run **Community Verify** with the release tag and build number. It installs
   only from the public Modular, modular-community, and conda-forge channels
   on Linux and macOS and exercises the installed runner and assertion
   companion.
11. Only after public verification passes, fill in the release's **Published**
   subsection in `CHANGELOG.md` with the channel, build number, and artifact
   names, and confirm the README's Installation section and the release notes
   say the package is publicly available.

## Recovery

| State | Action |
|---|---|
| Exact immutable release already exists and its commit is still `main` | A fresh **Release** dispatch is a no-op and emits fresh evidence. Run **Community Publish** manually with `prepare`, the tag, and build number if the fork branch still needs preparation. |
| Exact tag exists but no release exists | **Release** creates the stable release without moving the tag. |
| Draft, prerelease, or mutable release exists | Stop and inspect it; automation refuses to reinterpret it as the stable release. |
| Tag targets another commit | Stop. Never move or delete the published tag; choose a corrected version. |
| Exact open upstream pull request exists | The protected preparation updates the same deterministic fork branch with a lease. |
| Upstream pull request is merged but packages are absent | Wait for channel publication, then rerun **Community Verify**. |
| Only one supported platform is public | Stop and ask upstream maintainers to repair the partial publication. |
| Fork credential is expired or belongs to another account | Replace only the environment secret with a correctly scoped, expiring token and rerun preparation. |
| Upstream `main` advanced during validation or approval | Start a new dry run so every platform validates the new upstream commit. |
| Another process changed the fork branch after preparation read it | The force-with-lease push fails; inspect the remote branch before retrying. |
