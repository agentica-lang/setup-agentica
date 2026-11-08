# setup-agentica

A composite GitHub Action that installs a pinned Agentica release. `action.yml` is the interface; the work is in `install.sh`
(POSIX sh, so it runs in a `container:` job with no bash; no jq, python or node).

## Rules

- Third-party actions are forbidden; only official `actions/*` ones, pinned by major version.
- Keep `install.sh` POSIX sh (`dash -n install.sh`).
- A pin is always verified: `sha256` stays required. A failed install must leave nothing in the cache path.
- A change to inputs, outputs or platforms updates `README.md` and `CHANGELOG.md` (`## [Unreleased]`, one line).
- The action has no tests of its own; it is proven by its use in the CI of the Agentica repos.
- Releases: the owner tags `vX.Y.Z` and moves the major tag `v1`. Do not tag or force-push.
