# Design

This repository builds a small catalog of container images the way Chainguard does:
declarative [apko](https://github.com/chainguard-dev/apko) configs on top of
[Wolfi](https://github.com/wolfi-dev) packages, rebuilt on a schedule so every image
carries the latest security updates, signed and attested, with an SBOM attached.

The guiding rule is **explicit over clever**. Everything a build does should be
readable top to bottom in two files: the image's `apko.yaml` and `scripts/build.sh`.
There is no Terraform, no generated config checked in, and no templating language
beyond two placeholders.

## Layout

```
images/<name>/
  versions.yaml      which major streams to build and tag policy, or `unversioned: true`
  apko.yaml          the image, plain apko config using ${STREAM} and ${PIN}
  apko.dev.yaml      the -dev variant: same image plus shell, apk-tools, git, wget
  test.sh            smoke test; receives an image reference and the stream (empty
                     for unversioned images), exits non-zero on failure
scripts/
  matrix.sh          versions.yaml -> GitHub Actions matrix JSON
  build.sh           the one build routine, used by CI and by `make`
.github/workflows/
  build.yaml         reusable: builds one image x one stream x one variant
  scheduled.yaml     every Monday, all images and streams, publishes
  ci.yaml            pull requests build changed images without publishing;
                     pushes to master build and publish changed images
Makefile             make build IMAGE=go STREAM=1.27 [VARIANT=dev] [PUSH=1]
```

## Versions

A major version is a *stream*. Wolfi ships one package per stream (`go-1.27`,
`nodejs-26`, `postgresql-18`, `valkey-9.1`) and keeps that package at the newest
minor release of the stream. We declare streams; Wolfi supplies the minor.

```yaml
# images/go/versions.yaml
package: go            # Wolfi package family; the stream package is go-<stream>
streams:
  - stream: "1.27"
    latest: true       # this stream also gets the :latest tag
  - stream: "1.26"
  - stream: "1.25"
    pin: "1.25.12"     # optional: hold the stream at this minor (apk fuzzy match ~)
    eol: 2027-02-01    # optional: skipped after this date; published tags are never removed
```

`apko.yaml` references the stream package as `go-${STREAM}${PIN}`. `${PIN}` renders
to an empty string, or to `~1.25.12` when a pin is set. Postgres applies it to all
four of its packages so the client, contrib and entrypoint packages stay in step.

Adding a stream is one line. Retiring one is deleting a line or setting `eol`.

An image with no upstream version (`static`) sets `unversioned: true` in
`versions.yaml` instead of `package` and `streams`. It is built with an empty stream
(`build.sh static ""`), tagged `latest` and the build date, and does not use `${STREAM}`
or `${PIN}`. The `-dev` variant exists exactly when `images/<name>/apko.dev.yaml`
exists; `static` has none.

## What one build does

`scripts/build.sh IMAGE STREAM [VARIANT]` runs the same steps locally and in CI.

1. **Render.** Substitute `${STREAM}` and `${PIN}` into a working copy of the apko file.
2. **Lock.** `apko lock` resolves every package against Wolfi right now and writes a
   lock file. The script reads the resolved version of the stream package from it.
   This is where `1.27` becomes `1.27.2`.
3. **Build.** `apko build --lockfile` produces an amd64 + arm64 OCI tarball and SPDX
   SBOMs. No emulation is involved; apko assembles images from packages.
4. **Test.** Load the host architecture into Docker and run the image's `test.sh`.
5. **Publish** (only with `PUSH=1`, and only if tests passed). `apko publish --lockfile`
   pushes the image with all tags, then the script asserts the pushed digest equals
   the one that was tested. apko builds are reproducible from a lock file, so they match.
6. **Sign and attest** (CI only). Keyless cosign signature via GitHub OIDC and SLSA
   provenance from `actions/attest-build-provenance`. SBOMs are attached by apko.
7. **Summarise.** A job summary table: image, stream, resolved version, tags, digest.

## Tags

For each stream, every build publishes:

| Tag                 | Meaning                                              |
|---------------------|------------------------------------------------------|
| `1.27`              | the stream; moves every build                        |
| `1.27.2`            | the resolved upstream version; moves on Wolfi rebuilds |
| `1.27.2-20261013`   | immutable, date-stamped                              |
| `latest`            | only for the stream marked `latest: true`            |
| `<tag>-dev`         | the same set for the dev variant                     |
| `latest`, `20261013` | unversioned images only (`static`): no stream or version tags |

Images live at `ghcr.io/rfizzle/<image>`. Pin by digest in production.

## Schedule

`scheduled.yaml` runs every Monday at 06:00 UTC and rebuilds every image and stream
against the current Wolfi packages, so each weekly build carries that week's security
fixes. `workflow_dispatch` accepts an optional image and stream for urgent rebuilds,
for example after a CVE fix lands in Wolfi.

Pushes to `master` build and publish only the images whose directory changed, so a new
stream goes live when its pull request merges. Pull requests build and test without
publishing.

## Images

| Image    | Streams    | Main packages                                              | Runs as                               | Entrypoint                       |
|----------|------------|------------------------------------------------------------|---------------------------------------|----------------------------------|
| go       | 1.27, 1.26 | go, build-base, git, openssh-client, busybox               | root (it is a build-stage image)      | `go`                             |
| node     | 26, 24     | nodejs, npm, dumb-init; dev adds yarn, pnpm, build-base    | `node` uid 65532, workdir `/app`      | `node`                           |
| postgres | 18, 17     | postgresql, -client, -contrib, -oci-entrypoint, gosu, bash | root, entrypoint drops to `postgres` uid 70 | `docker-entrypoint.sh postgres` |
| valkey   | 9.1, 9.0   | valkey, valkey-cli                                         | `valkey` uid 65532, workdir `/data`   | `valkey-server`                  |
| python   | 3.15, 3.14       | `python`, py3-pip-wheel; dev adds pip, setuptools, uv, build-base | `nonroot` uid 65532, workdir `/app` | `python`                   |
| ruby     | 4.0        | `ruby`, ruby-json, yaml; dev adds bundler, jemalloc-dev, build-base | `nonroot` uid 65532, workdir `/work` | `ruby`                  |
| static   | none       | wolfi-baselayout, ca-certificates-bundle, tzdata           | `nonroot` uid 65532                   | none                             |

Valkey stands in for Redis: Wolfi ships no Redis package, and Valkey is wire-compatible
with Redis 7.2 clients.

Package lists, users, entrypoints and environment follow Chainguard's published
definitions for the same images.

## Supply chain

- Packages come only from the Wolfi repository and are verified with its signing key.
- apko is pinned to a release in the workflow; actions are pinned by commit SHA and
  kept fresh by Dependabot.
- Workflow permissions are least privilege: `packages: write`, `id-token: write`,
  `attestations: write`, `contents: read`.
- No published tag is ever deleted.

## Not in version one

Each is easy to add later: melange-built packages, a CVE scan gate (a non-blocking
Grype report would come first), pruning untagged GHCR versions, FIPS variants.
