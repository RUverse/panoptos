# Preparing and publishing a release

Panoptos has one unrestricted GPL-3.0-or-later app. GitHub, Homebrew, and optional
Gumroad delivery use the same official signed/notarized DMG. Preparation does
not authorize publication.

## Source and branch policy

The canonical application repository is `RUverse/panoptos`. For the first public
release, use a sanitized export with new history, preserving the original private
repository separately. Do not push legacy GitLab history, backup refs, local
signing configuration, private operations files, or build output. Use `main` for
release candidates and topic branches for contributions. Scan the exact proposed
tree and history before its first push.

Keep the website in its existing repository and hosting setup. Its deployment
is a separate publication action. The Homebrew tap is `RUverse/homebrew-tap`.

## Version and evidence

Choose a stable `X.Y.Z` greater than the latest published marketing version. Set
both Xcode configurations' `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`;
the new build must exceed both configurations and every published appcast/GitHub
release build. Keep bundle identity, the Sparkle public key, and the appcast URL
unchanged. The first GPL release is **1.4.0, build 11**, following 1.3.3/build 10.

Prepare concise Markdown notes describing observable changes. Keep notes outside
`build/release/`, which packaging recreates. Record the exact source commit and
run the Debug build/full test suite, unsigned Release validation, and clean
contributor build without `Signing.local.xcconfig`. Complete the manual checks
in `AGENTS.md` with Xcode Stop/Run, or record gaps explicitly.

## GitHub Actions preparation

Run **Prepare release candidate** (`release-candidate.yml`) manually on the reviewed commit, supplying
its version, build, `RUverse/panoptos`, and release-note text. The workflow has
read-only permissions and no signing credentials. It does not create tags or
releases, update the live appcast, or deploy the website.

Its candidate artifact contains Debug/full-test and Release validation evidence,
`Panoptos-unsigned.zip`, notes, exact-commit metadata, `appcast-draft.json`, checksums, and matching
source. The unsigned app is review material and must never be distributed as an
official release. Inspect the workflow log and artifact metadata against the
commit you intend to sign. Never run privileged release steps for untrusted PRs.

## Local signing and packaging

Production signing remains on the maintainer's Mac. Keep the Developer ID
certificate, notary credentials, and Sparkle EdDSA private key local. Configure
the team in ignored `Signing.local.xcconfig`; no license Keychain access group
or provisioning profile is needed. Preserve default certificate-derived
designated requirements, hardened runtime, secure timestamps, nested Sparkle
audits, app/DMG notarization, stapling, and Gatekeeper verification.

From the clean exact source commit:

```sh
scripts/release.sh --dry-run --github-repository RUverse/panoptos
scripts/release.sh --release-notes build/release-notes-1.4.0.md --github-repository RUverse/panoptos
```

The dry run validates local packaging without notarization or publication; its
DMG is not an official release. A normal run appends the GPL notice and exact
versioned source-archive link to the supplied release notes; review that final
`Panoptos.md` as the release text. It prepares the signed/notarized
candidate under `build/release/candidate/vX.Y.Z/` and stages a candidate appcast
in the website checkout. It never commits or pushes. Inspect all staged changes.

The corresponding-source archive contains the exact app commit, Xcode project,
resources, build/packaging scripts, notices, and source for the pinned Sparkle
dependency, including required non-system dependency source. The automatic
GitHub repository archive alone does not include SPM dependency source.

```sh
scripts/package-source.sh --version 1.4.0 --build 11 --output build/source-review
```

Verify the archive contents and build instructions. Do not include secrets.
Keep GPL and Sparkle notices in the app and release source. Each binary must link
to its version's matching source, rather than only a moving default branch.

## Homebrew preparation

After final signed/notarized DMG bytes exist, generate a local cask:

```sh
scripts/prepare-cask.py --version 1.4.0 --dmg build/release/candidate/v1.4.0/Panoptos.dmg --output /path/to/homebrew-tap/Casks/panoptos.rb
```

Review the version, GitHub URL, and computed SHA-256. Run Homebrew style/audit
checks. Normal uninstall removes the app and preserves preferences/workspaces;
the cask intentionally has no destructive zap. Verify install, upgrade, and
uninstall after the exact official asset is available. Never publish a cask
computed from unsigned or unnotarized dry-run bytes.

## Single publication review

Present source/app/website/cask diffs, exact source commit/version/build, exact
notes, artifact hashes, source completeness, test results, signing/notarization
evidence, URLs, and intended actions. Report pending manual checks. Obtain
explicit publication approval before pushing source or deploying anything.

After approval:

1. Publish the sanitized GPL source, enable Issues, and verify anonymous source
   and Issues access. Tag the exact reviewed commit as `vX.Y.Z`; tags and assets
   are immutable after release.
2. Publish `Panoptos.dmg`, matching source archive, checksums, and approved notes
   in the GitHub release. Download anonymously and compare bytes.
3. Publish the generated appcast and website only after assets are reachable.
   Verify version/build, enclosure URL/length/signature, release notes, old feed
   entries, and existing immutable download paths. Never edit signed feed data
   by hand or overwrite published binaries.
4. Publish the cask only after its GitHub DMG is public and its checksum matches.
   Once verified, expose `brew install --cask ruverse/tap/panoptos` on the website.
5. Enable the verified Gumroad support link. File delivery must use the same DMG
   with matching source/GPL links; modifying the listing or its delivery requires
   explicit authorization. No real purchase is needed for testing.
6. Review legacy customer support before retiring Lemon Squeezy infrastructure.
   Keep old reset/upgrade links useful and do not revoke credentials or delete
   provider records as part of publishing source.

Report local, draft, and public state separately. A preparation artifact is not
a published release. If rollout fails, report precisely what is already live.
