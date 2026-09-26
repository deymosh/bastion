# Releases and upgrades

A Bastion release is a **git tag** (`vX.Y.Z`) on `master`, together with a
GitHub Release that holds the changelog. Nothing is built or uploaded: the
compose files, configs and scripts in the tagged tree *are* the release, and
every image they use is already pinned by digest or commit.

`./bastion version` shows the release of a checkout and, when it differs, the
exact commit (`Bastion 1.2.0 (git v1.2.0-3-gabc1234-dirty)`).

## How a release is cut (maintainers)

It is automated by [release-please](https://github.com/googleapis/release-please)
(`.github/workflows/release.yml`):

1. Every merge to `master` updates a single open **release PR**. That PR bumps
   `VERSION` and prepends the new entries to `CHANGELOG.md`.
2. The version comes from the Conventional Commit types merged since the last
   tag:

   | Commits since last tag | Bump |
   |---|---|
   | `fix:` / `perf:` only | patch (`1.2.3` → `1.2.4`) |
   | any `feat:` | minor (`1.2.3` → `1.3.0`) |
   | any `!` / `BREAKING CHANGE:` footer | major (`1.2.3` → `2.0.0`) |

   `docs`, `refactor` and `build` appear in the changelog without bumping the
   version on their own; `chore`, `ci` and `test` are left out of it.
3. **Merging the release PR** creates the tag and the GitHub Release. Nothing
   is released until a human merges it, so batch as many changes as you like.

Mark anything that needs operator action on upgrade (a new required setting,
a data migration, a renamed container) as breaking, and say what to do in the
commit body. That text ends up in the changelog.

One-time repository setting: *Settings → Actions → General → Allow GitHub
Actions to create and approve pull requests*. PRs opened with the default
`GITHUB_TOKEN` do not trigger CI. The changes inside them were already tested
when they merged; run CI from the Actions tab if you want a fresh run.

The first release is pinned to `1.0.0` (`release-as` in
`release-please-config.json`). Remove that line once `v1.0.0` exists, or the
next release PR would propose `1.0.0` again.

## Upgrading a node (operators)

Read the changelog entries between your version and the target first, and
follow any **breaking** notes. Then:

```bash
./bastion version                               # where you are
git fetch --tags
git checkout vX.Y.Z                             # a release (or: git pull on master)
git submodule update --init --recursive         # rust-teos must match the tag
./bastion build                                 # images built from source
./bastion up                                    # recreates only what changed
./bastion ps                                    # everything healthy?
```

- **Back up first** (see [disaster recovery §2](disaster-recovery.md#2-back-up-now-and-on-a-schedule)),
  above all when a release touches `stack-bitcoin`.
- `data/`, `bastion.conf` and `secrets/` are never touched by an upgrade. New
  settings get their defaults on the next run; a new *required* setting is
  asked for by `up` (on a terminal) or named in the error (from the daemon).
- To roll back, `git checkout` the previous tag and repeat the same steps.
  Only do this if the changelog doesn't mention a data migration.
