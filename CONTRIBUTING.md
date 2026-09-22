# Contributing to Panoptos

Contributions are welcome under GPL-3.0-or-later, the same license as Panoptos.
You retain copyright in your contributions. No copyright assignment or separate
contributor license agreement is required. Only submit work you have the right
to contribute under this license, and preserve applicable third-party notices.

Read [AGENTS.md](AGENTS.md) for the product and engineering contracts and
[README.md](README.md) for build, signing, and Accessibility setup. Use a topic
branch and describe the user-visible problem, resulting behavior, and validation
in your pull request. Keep unrelated changes separate.

Before submitting, run `git diff --check`, the documented Debug build, and the
full test suite. Add focused regression coverage for behavior changes. Durable
state needs backward-compatible decoding, storage round-trip coverage, and a
model relaunch test. Report manual Accessibility checks and any unavailable
checks honestly.

Do not commit credentials, local signing configuration, certificates, provisioning
profiles, private operations files, generated build output, or payment data.
Unsigned/ad-hoc contributor builds require no owner's account or payment.

Keep the app settings-only, use public Accessibility APIs, and preserve the
system menu bar and existing permission boundaries. Sparkle is the only
third-party app code dependency. Tests must not contact the live update feed.

Report vulnerabilities privately using [SECURITY.md](SECURITY.md).
