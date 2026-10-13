# images

Container images built the way Chainguard builds theirs: declarative
[apko](https://github.com/chainguard-dev/apko) configs on top of
[Wolfi](https://github.com/wolfi-dev) packages, rebuilt every Monday with the latest
Wolfi packages, signed with cosign, attested, and published with an SBOM to GitHub
Container Registry. The design is in [docs/DESIGN.md](docs/DESIGN.md).


## Images

| Image    | Streams    | Pull                                  |
|----------|------------|---------------------------------------|
| go       | 1.27, 1.26 | `ghcr.io/rfizzle/go:<stream>`         |
| node     | 26, 24     | `ghcr.io/rfizzle/node:<stream>`       |
| postgres | 18, 17     | `ghcr.io/rfizzle/postgres:<stream>`   |
| valkey   | 9.1, 9.0   | `ghcr.io/rfizzle/valkey:<stream>`     |

Each image also has a `-dev` variant (shell, apk-tools, git, wget, and more) under the
`-dev` tags, for example `ghcr.io/rfizzle/go:1.27-dev`.

## Tags

| Tag               | Meaning                                         |
|-------------------|-------------------------------------------------|
| `1.27`            | the stream; moves every build                   |
| `1.27.2`          | the resolved upstream version                   |
| `1.27.2-20261013` | immutable, date-stamped                         |
| `latest`          | only the stream marked `latest: true`           |
| `<tag>-dev`       | the same set for the dev variant                |

Pin by digest in production.

## How a build happens

`scripts/build.sh <image> <stream> [variant]`, the same locally and in CI:

1. Render `${STREAM}`, `${PIN}` and `${SOURCE_URL}` into a copy of the apko config.
2. Lock: `apko lock` resolves packages from Wolfi and gives the exact version.
3. Tag: stream, full version, dated version, and `latest` where it applies.
4. Build a multi-arch (amd64, arm64) image and SPDX SBOMs with `apko build`.
5. Test the host-arch image with `images/<image>/test.sh` (needs Docker).
6. Publish with `apko publish` (only with `PUSH=1`), then check the digest matches.
7. In CI: sign with cosign (keyless), attest provenance, and print a summary table.

## Add or retire a version

1. Edit `images/<image>/versions.yaml`: add a `stream:` entry, or delete one, or set `eol: YYYY-MM-DD`.
2. Open a pull request. CI builds and tests the changed image without publishing.
3. Merge. The push to `master` builds and publishes it. Published tags are never deleted.

## Local use

```sh
make tools                          # apko and yq into ./.bin, sha256 verified
make lock IMAGE=go STREAM=1.27      # resolve packages, print the resolved version
make build IMAGE=go STREAM=1.27     # build and test (needs Docker); add VARIANT=dev
make build IMAGE=go STREAM=1.27 PUSH=1 REGISTRY=ghcr.io/rfizzle   # publish
make matrix                         # the build matrix as JSON
make lint                           # shellcheck and actionlint, if installed
```

Without a GitHub `origin` remote, set `SOURCE_URL` yourself; `SKIP_TESTS=1` skips the
Docker smoke test. `make tools LINT=1` also installs shellcheck and actionlint.

## Verify signatures and SBOM

```sh
cosign verify ghcr.io/rfizzle/go:1.27 \
  --certificate-identity-regexp '^https://github.com/rfizzle/images/\.github/workflows/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

cosign download sbom ghcr.io/rfizzle/go:1.27
gh attestation verify oci://ghcr.io/rfizzle/go:1.27 --repo rfizzle/images
```

## Schedule

Images are rebuilt every Monday at 06:00 UTC (`scheduled.yaml`) so they carry the latest
security updates. Run the workflow manually with an image and stream to rebuild one
sooner, for example after a CVE fix lands in Wolfi.
