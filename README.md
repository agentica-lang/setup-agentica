# setup-agentica

GitHub Action that installs a pinned [Agentica](https://github.com/agentica-lang/agentica) release in CI, like `actions/setup-node`.

- Downloads the release asset through the GitHub API first, then the direct link (either can answer 5xx for a while). 5 tries, waiting 10, 20, 40 and 80 s.
- Checks the sha256 of the archive. The input is required, so a pin is always verified.
- Caches the extracted release with `actions/cache`.
- Puts `agentica` on `PATH`.
- Works in `container:` jobs: the script is POSIX `sh` and needs only `curl`, `tar` and `awk`. No `jq`, `python` or `node` in the job image.

## Usage

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: agentica-lang/setup-agentica@v1
    with:
      version: 0.26.1
      sha256: 68c3e825cb14148e45c47b21b6ef66036c5ad17a2cdf36948f47e1415bae5524 # linux-x86_64
  - run: agentica --version
```

One runner OS and architecture needs one sha256. For a matrix, put it in the matrix:

```yaml
strategy:
  matrix:
    include:
      - os: ubuntu-latest
        sha256: 68c3e825cb14148e45c47b21b6ef66036c5ad17a2cdf36948f47e1415bae5524
      - os: ubuntu-24.04-arm
        sha256: 9f83da17c0e2336a202f39e8f1154abdea503d9ed160de484955f57a64e099b6
runs-on: ${{ matrix.os }}
steps:
  - uses: agentica-lang/setup-agentica@v1
    with:
      version: 0.26.1
      sha256: ${{ matrix.sha256 }}
```

In a `container:` job, install `curl` and `ca-certificates` first (a `debian` image has neither):

```yaml
container: debian:trixie
steps:
  - run: apt-get update && apt-get install -y --no-install-recommends ca-certificates curl
  - uses: agentica-lang/setup-agentica@v1
    with:
      version: 0.26.1
      sha256: 68c3e825cb14148e45c47b21b6ef66036c5ad17a2cdf36948f47e1415bae5524
```

## Inputs

| Input | Required | Default | Meaning |
|---|---|---|---|
| `version` | yes | | The release tag without a leading `v`, for example `0.26.1`. |
| `sha256` | yes | | The sha256 of the archive for the runner's platform. |
| `token` | no | `${{ github.token }}` | Token for the GitHub API. It is sent only to `api.github.com`, never to the direct link. |
| `cache` | no | `true` | `false` turns off `actions/cache`. |

## Outputs

| Output | Meaning |
|---|---|
| `path` | The folder with the `agentica` binary (also added to `PATH`). |
| `version` | The installed version. |
| `cache-hit` | `true` when the release was already on disk (restored from the cache) and nothing was downloaded. |

## Platforms

| Runner | Archive |
|---|---|
| Linux x64 | `agentica-VERSION-linux-x86_64.tar.gz` |
| Linux arm64 | `agentica-VERSION-linux-arm64.tar.gz` |
| macOS x64 | `agentica-VERSION-macos-x86_64.tar.gz` |
| macOS arm64 | `agentica-VERSION-macos-arm64.tar.gz` |
| Windows x64 | `agentica-VERSION-windows-x86_64.zip` |

Any other runner fails with a message that names it. An unknown version or archive fails after the 5 download tries.

## Get the sha256

Every release has a `SHA256SUMS` asset with one line per archive:

```sh
gh release download 0.26.1 -R agentica-lang/agentica -p SHA256SUMS -O -
# or
curl -fsSL https://github.com/agentica-lang/agentica/releases/download/0.26.1/SHA256SUMS
```

Copy the digest of the archive that matches your runner. When you bump `version`, bump the `sha256` with it: a mismatch fails the step with both digests in the message, and the retries do not repeat it.

## How the download works

1. `GET /repos/agentica-lang/agentica/releases/tags/VERSION` with the token, and the asset id is read from the JSON with `tr` and `awk`. There is no `jq` dependency, because a container image may not have it.
2. `GET /releases/assets/ID` with `Accept: application/octet-stream`. This route kept working on 2026-11-08, when the direct release link answered 504 for an hour.
3. If either call fails, the direct link `https://github.com/agentica-lang/agentica/releases/download/VERSION/ARCHIVE`.
4. Every call has a connect limit of 20 s and a total limit of 120 s. The whole sequence is tried 5 times.
5. The archive is checked (`sha256sum`, else `shasum -a 256`, else `openssl`), unpacked next to its final folder and moved in only then, so a failed install leaves nothing for the cache to save.

The cache key is `setup-agentica-OS-ARCH-VERSION-SHA256`, and the cache holds the extracted folder. On a hit the download is skipped.

## Pin the action

Use the moving major tag, or a full tag, or a commit sha:

```yaml
- uses: agentica-lang/setup-agentica@v1
- uses: agentica-lang/setup-agentica@v1.0.0
```

## License

Apache-2.0, see `LICENSE`.
