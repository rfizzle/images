# images

Container images built the way Chainguard builds theirs: declarative
[apko](https://github.com/chainguard-dev/apko) configs on top of
[Wolfi](https://github.com/wolfi-dev) packages, rebuilt every Monday with the latest
Wolfi packages, signed with cosign, attested, and published with an SBOM to GitHub
Container Registry. The design is in [docs/DESIGN.md](docs/DESIGN.md).

## Images

| Image    | Streams    | Pull                                |
|----------|------------|-------------------------------------|
| go       | 1.27, 1.26 | `ghcr.io/rfizzle/go:<stream>`       |
| node     | 26, 24     | `ghcr.io/rfizzle/node:<stream>`     |
| python   | 3.15, 3.14 | `ghcr.io/rfizzle/python:<stream>`   |
| ruby     | 4.0        | `ghcr.io/rfizzle/ruby:<stream>`     |
| postgres | 18, 17     | `ghcr.io/rfizzle/postgres:<stream>` |
| valkey   | 9.1, 9.0   | `ghcr.io/rfizzle/valkey:<stream>`   |
| static   | none       | `ghcr.io/rfizzle/static:latest`     |

A stream is a major version. Its tag always points at the newest minor release Wolfi
ships for it, so `go:1.27` is Go 1.27.2 today and moves on each rebuild.

Every image except `static` also has a `-dev` variant with a shell, apk-tools, git,
wget and the build toolchain, under the `-dev` tags, for example
`ghcr.io/rfizzle/go:1.27-dev`. Use the plain image at runtime and the `-dev` image in
build stages.

`static` is a minimal base (CA certificates, timezone data, a `nonroot` user with uid
65532) for statically linked binaries, for example the last stage of a Go build:

```dockerfile
FROM ghcr.io/rfizzle/go:1.27 AS build
# ... build a static binary at /src/app
FROM ghcr.io/rfizzle/static:latest
COPY --from=build /src/app /app
ENTRYPOINT ["/app"]
```

## Tags

| Tag               | Meaning                                         |
|-------------------|-------------------------------------------------|
| `1.27`            | the stream; moves every build                   |
| `1.27.2`          | the resolved upstream version                   |
| `1.27.2-20261013` | immutable, date-stamped                         |
| `latest`          | only the stream marked `latest: true`           |
| `<tag>-dev`       | the same set for the dev variant                |

Unversioned images (`static`) are tagged `latest` and `YYYYMMDD`.

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

To hold a stream at one minor release, add `pin: "1.26.4"` to it. To mark the stream
that gets the `latest` tag, add `latest: true`.

## Add a new image

Create `images/<name>/` with:

- `versions.yaml`: the Wolfi package family and the streams to build, or
  `unversioned: true` for an image with no upstream version.
- `apko.yaml`: the image, as a plain [apko](https://github.com/chainguard-dev/apko)
  config. Reference the stream package as `<package>-${STREAM}${PIN}`.
- `apko.dev.yaml` (optional): the `-dev` variant. It exists exactly when this file does.
- `test.sh`: a smoke test that receives the image reference and the stream, and exits
  non-zero on failure.

`make lock IMAGE=<name> STREAM=<stream>` checks that every package resolves. The
existing images are the templates; `node` is the simplest versioned one.

## Local use

```sh
make tools                          # apko and yq into ./.bin, sha256 verified
make lock IMAGE=go STREAM=1.27      # resolve packages, print the resolved version
make build IMAGE=go STREAM=1.27     # build and test (needs Docker); add VARIANT=dev
make build IMAGE=static             # unversioned images take no STREAM
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
