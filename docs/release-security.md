# Release and repository security

How the public `k97/dock-tile` repository is protected against outside contributions, a compromised
write account, and a bad release. Set up on 2026-10-28, after an outside contributor's first pull
request (#32) triggered a CI run and a Vercel preview request. Neither got through: GitHub held the
run (no job started) and Vercel's fork protection held the preview. This document turns those
defaults into deliberate, documented controls.

The rule-of-thumb version lives in [.claude/rules/ci-release.md](../.claude/rules/ci-release.md);
this is the full reference.

## What is worth protecting

A signed, notarised release reaches every user through Sparkle. Two secrets together could sign a
malicious update that every installed copy accepts:

- **`SPARKLE_EDDSA_KEY`**: the EdDSA private key whose public half (`SUPublicEDKey` in
  `DockTile/Resources/Info.plist`) every shipped copy trusts. It cannot be rotated without
  orphaning every installed copy.
- **`DEVELOPER_ID_APPLICATION_CERTIFICATE`** (+ `_PASSWORD`): the Developer ID identity that signs
  the app for Gatekeeper and notarisation.

Everything below exists to keep those two away from anyone but the owner, and to stop a wrong key
from ever reaching users.

## Who can do what

| Actor | Can push code | Can create `v*` tags | Gets release secrets |
|---|---|---|---|
| Outside contributor (fork PR) | No (PR only) | No | Never: GitHub withholds secrets from fork-triggered runs |
| Dependabot | Its own PR branches | No | No: Dependabot runs only see Dependabot secrets |
| A write collaborator (one, kept on purpose) | Yes | No ("Release tags" ruleset) | Not the signing secrets (environment-only since 2026-10-28). But code they push to `main` runs with them at the next approved release, so review `main` before approving |
| `k97` (admin, owner) | Yes | Yes | Yes, after approving the deployment |

## The controls

| Control | Where | What it stops |
|---|---|---|
| Fork-PR runs need approval for **all** external contributors | Settings → Actions → General | A contributor's later PRs running code on our runners unapproved (the default only covers first-timers) |
| **`release` environment**: required reviewer k97, deployment refs limited to `v*` tags, used by the build job | Settings → Environments | Anything being signed or published, or any job reading the signing secrets, without the owner's approval |
| Signing secrets live **only in the environment** (repo-level copies deleted 2026-10-28) | Settings → Environments → release | A write account pushing a branch with a new workflow that reads them |
| **"Release tags"** ruleset: create/update/delete `v*` only by the admin role | Settings → Rules | Anyone else starting a release |
| **"Protect main"** ruleset: no force push, no deletion | Settings → Rules | History rewrites of `main`. Normal pushes (and the pipeline's own appcast commit) still work |
| Every action **pinned to a full commit SHA** (version as a comment) | `.github/workflows/*.yml` | A moved tag silently running new code with the signing secrets |
| Actions policy: GitHub-owned + `softprops/action-gh-release@*`, **SHA pinning required** | Settings → Actions → General | An unvetted or unpinned action running at all |
| **Dependabot** for actions: weekly, 7-day cooldown, minor/patch grouped, each major its own PR | `.github/dependabot.yml` | Pins going stale. The cooldown gives the community a week to spot a compromised release |
| **Sparkle signature guard** before anything is published | `Scripts/ci/verify-sparkle-signature.swift`, run by `release.yml` | A wrong `SPARKLE_EDDSA_KEY` shipping an update every user's Sparkle rejects (`sign_update` signs with any key it is given), and a changed `SUPublicEDKey` (the script pins the shipped key) |
| Sparkle tools tarball **checked against a pinned SHA-256** | "Sign update for Sparkle" in `release.yml` | A tampered download receiving `SPARKLE_EDDSA_KEY`. Bumping `SPARKLE_VERSION` needs the new release's digest |
| Vercel **Git Fork Protection** stays on | Vercel → Project → Settings → Security | A fork's preview build reading the website's environment variables |

Read the live settings back at any time (read-only):

```bash
gh api repos/k97/dock-tile/actions/permissions/fork-pr-contributor-approval   # all_external_contributors
gh api repos/k97/dock-tile/actions/permissions                                # selected + sha_pinning_required
gh api repos/k97/dock-tile/actions/permissions/selected-actions
gh api repos/k97/dock-tile/environments/release --jq '{rules: [.protection_rules[].type], policy: .deployment_branch_policy}'
gh api repos/k97/dock-tile/environments/release/deployment-branch-policies --jq '.branch_policies[] | "\(.type) \(.name)"'
gh api repos/k97/dock-tile/rulesets --jq '.[] | "\(.name): \(.enforcement)"'
gh secret list --env release                                                  # names only, never values
```

## Releasing

Same three steps as before ([ci-release.md](../.claude/rules/ci-release.md) "Creating a Release"),
plus **one approval**:

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, commit, push `main`.
2. Tag and push `vX.Y.Z` (admin only). Run Tests starts at once: it reads only the repo-level
   notary login, so it needs no approval.
3. When Run Tests passes (~15 minutes), Build, Sign & Release waits for the `release` environment.
   Approve it only after reading what changed on `main` since the last tag (`git log
   vPREV..HEAD`), especially `.github/`, `Scripts/` and the Xcode project: whatever landed there
   runs with the signing secrets.

Approve either in the run (**Review deployments → release → Approve and deploy**) or, in a Claude
Code session, by saying "approve" for that release: the agent then calls the API with the owner's
`gh` login (`POST repos/k97/dock-tile/actions/runs/<run>/pending_deployments`,
`environment_ids[]=<release env id>`, `state=approved`; the id comes from
`gh api repos/k97/dock-tile/actions/runs/<run>/pending_deployments --jq '.[].environment.id'`). It never approves without that
instruction for that release. The approval protects against everyone else (other accounts cannot
approve); the owner's own login always could, so this costs only the pause, which the review in
step 3 replaces.

2.6.1 (2026-10-28) was the first release through the gate, then with two approvals (Run Tests used
the environment too); it was trimmed to one the same day.

## Landing an outside contributor's PR

Never approve its workflow run and never click Vercel's "Authorize". Both are the gate. Instead:

```bash
git fetch origin pull/<n>/head:<branch>      # read the WHOLE diff before building: a build runs script phases
# fix on top of the contributor's commit, keeping their authorship
git push -u origin <branch> && gh workflow run ci.yml --ref <branch>
# when green: fast-forward main to the branch; GitHub marks the PR merged by itself
```

## Where the secrets live

| Secret | Scope | Notes |
|---|---|---|
| `SPARKLE_EDDSA_KEY` | `release` environment | Re-exported from the owner's keychain on 2026-10-28 and checked to derive `SUPublicEDKey` before it was set |
| `DEVELOPER_ID_APPLICATION_CERTIFICATE` | `release` environment | The single Developer ID identity, exported with its private key on 2026-10-28 |
| `DEVELOPER_ID_APPLICATION_PASSWORD` | `release` environment | New random password for that export, checked to open it |
| `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_DEVELOPER_NAME`, `KEYCHAIN_PASSWORD` | repo level | Owner's choice: none of them can sign anything |

While a job uses the environment, an environment secret overrides a repo-level one of the same
name. The repo-level copies of the three signing secrets were deleted on 2026-10-28, after 2.6.1
was signed, notarised and published from the environment copies. Keep it that way: a signing
secret re-added at repo level is readable by any workflow on any branch.

### Moving or rotating a secret without exposing it

GitHub never returns a secret's value, so "moving" means re-exporting from the source. Keep values
in pipes and shell variables: never in a file, a terminal transcript or a chat. `gh secret set
NAME --env release` with nothing piped in asks for the value at a hidden prompt.

- **Sparkle key**: the keychain item is service `https://sparkle-project.org`, account `ed25519`
  (the same string `docs/sparkle-key-fixer/` moves between Macs). Before setting it, prove it
  derives `SUPublicEDKey`: `generate_keys -p` must print the same value as
  `PlistBuddy -c 'Print :SUPublicEDKey' DockTile/Resources/Info.plist`. **Never run `generate_keys`
  with no flag**: that creates a new key and orphans every installed copy.
- **Developer ID certificate**: export only the `Developer ID Application` identity as a `.p12`
  with a fresh password (Keychain Access → My Certificates → Export), then set its base64 and the
  password. macOS asks before letting anything export a private key.
- **App-specific password**: create a new one at account.apple.com → Sign-In and Security, set it,
  and revoke the old one after a release works.

## The Sparkle signature guard

`release.yml` runs it right after signing and before the appcast, the website commit and the
GitHub Release. So a failure publishes nothing. It first checks that the build's `SUPublicEDKey`
equals the key pinned in the script (the one every shipped copy trusts), then verifies the
signature against it with CryptoKit. Exit 0 valid, 1 wrong signature or changed key, 2 unreadable
input or usage (a check that cannot verify must not pass).

Run it against any published release (it needs no secret):

```bash
curl -sL -o /tmp/DockTile.dmg https://github.com/k97/dock-tile/releases/download/vX.Y.Z/DockTile-X.Y.Z.dmg
swift Scripts/ci/verify-sparkle-signature.swift /tmp/DockTile.dmg "<sparkle:edSignature from the appcast>" DockTile/Resources/Info.plist
```

Proved on 2026-10-28 against the published 2.6.0: its own signature passes, 2.5.1's signature on
the 2.6.0 file fails with exit 1, a plist carrying a different key fails with exit 1, and missing,
malformed or unreadable inputs exit 2.

## Recovery

| What happened | Do this |
|---|---|
| The guard failed in a release | Nothing was published. If the signature check failed, fix `SPARKLE_EDDSA_KEY` in the environment (procedure above), then **Re-run failed jobs** (a re-run reads secrets fresh; it asks for approval again). If the pinned-key check failed, `SUPublicEDKey` changed in code: revert that change on `main` and tag a new version |
| Create Release failed after "Commit website updates" pushed | The live appcast already points at a DMG that does not exist, so users see an update that cannot download. Revert the `chore: update website for vX.Y.Z` commit on `main` first, then fix and re-run |
| A release failed after a Dependabot action bump (e.g. the `git push` back to `main`, or the release action) | Check whether the website commit reached `main` (row above), revert the bump on `main` (the 2026-10-28 majors were `9c3da8b`), then tag a new patch version: a re-run replays the tagged commit, bump included |
| A secret may have leaked | Rotate it at its source (Apple ID password, certificate revocation at developer.apple.com). The Sparkle key cannot be rotated without a migration release, so treat it as the crown jewel |
| A write account is compromised | Remove it (Settings → Collaborators), then review recent pushes, tags and workflow runs |
