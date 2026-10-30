# The UniFi Network Application image

The container image the setups run as their `app` container: the standalone
UniFi Network Application (`UniFi.unix.zip`) on Temurin 25, for amd64 and
arm64. This is the developer side; to run it, see the [top README](../README.md).

| Path | Purpose |
|---|---|
| `build.sh` | Builds the image: looks up the version and checksum, then runs `podman build` (or `docker build`) |
| `Containerfile` | The image: Temurin 25 JRE on Ubuntu 26.04 + the UniFi Network Application zip + tini |
| `bin/` | The container's scripts, installed into `/usr/local/bin` in the image (see [The scripts](#the-scripts)) |
| `published.env` | What was published last, and what it was built from; written by the workflow (see [Publishing](#publishing)) |

## Building

```sh
./build.sh --latest             # the latest release, also tagged latest
./build.sh --latest 10.6.109    # a specific version
./build.sh 10.5.67              # an older version, without touching latest
./build.sh --no-build           # only look up the latest version and checksum
```

`build.sh` is the only part that talks to Ubiquiti's update API
(`fw-update.ubnt.com`). It looks up the version (the latest release unless you
name one) and the SHA-256 of its zip there, then builds with both. The
Containerfile downloads the zip from `dl.ui.com` and checks it against that
SHA-256. It needs `curl` and `jq`, and podman or docker (`--engine` picks one;
podman is the default when both are installed). `./build.sh --help` lists the
options. Anything after `--` is passed to the build command, e.g.
`./build.sh --latest -- --pull=always` to refresh the Temurin base image.

The image is built for the architecture of the machine that builds it, and
tagged `localhost/unifi-network-application:<version>`, and also `:latest`
with `--latest`. `localhost/` marks an image that comes from no registry;
`--image` sets another name, e.g. a registry path.

For scripts, `build.sh` prints its progress and the build log to stderr, and
only the result to stdout, as `KEY=VALUE` lines. They work with `eval`, as an
`.env` file, or appended to `$GITHUB_OUTPUT`:

```sh
$ ./build.sh --no-build 2>/dev/null
UNIFI_VERSION=10.6.109
UNIFI_SHA256=6771ed353bea92586aaa8bf1545d8aa4309ef3d31ebafd9869fe39dfd5098109
IMAGE=localhost/unifi-network-application:10.6.109

$ eval "$(./build.sh)" && podman tag "$IMAGE" localhost/unifi-network-application:latest
```

A version the API doesn't list is still built, but without checksum
verification: `build.sh` and the build both print a warning, and the result
has an empty `UNIFI_SHA256=`.

To build without `build.sh`, call `podman build` (or `docker build`)
yourself. `UNIFI_VERSION` is required and `UNIFI_SHA256` optional; without a
checksum the build warns that the download is not verified. A bare
`--build-arg NAME` takes the value from the environment.

```sh
podman build --build-arg UNIFI_VERSION=<version> [--build-arg UNIFI_SHA256=<sha256>] \
  -t localhost/unifi-network-application:<version> -f Containerfile .
```

## Publishing

The workflow
[`.github/workflows/app-build-and-publish.yml`](../.github/workflows/app-build-and-publish.yml)
publishes `ghcr.io/peku33/unifi-network-application` for amd64 and arm64,
each built on a native runner, as `:<version>` and `:latest`. It runs:

- **daily**, publishing when the latest release (from `build.sh --no-build`)
  or the base image (the `FROM` of the Containerfile, by digest) differs from
  what `published.env` records, so the image also gets the base image's
  security updates
- **on a push to `main`** that changes `app/` or the workflow
- **by hand**, from the Actions tab (on `main`)
- **on a pull request**, where it only builds, and publishes nothing

The build uses the base image by the digest it looked up, and labels the
image with it (`org.opencontainers.image.base.name` / `.base.digest`) and
with the commit it was built from (`.revision`).

After each publish, the workflow writes `published.env` and commits it to
`main` as `github-actions[bot]`, e.g. "chore: publish image 10.6.110". The
commit is the record of the publish: its diff shows what changed, and it
links to the workflow run. It doesn't start the workflow again. Pull before
you push, as `main` may have moved.

Only the newest version is rebuilt: an older version tag stays on the base
image it was built with.

## What the image expects

- to run as a non-root UID/GID (it needs no passwd entry)
- a writable volume at `/unifi`, which holds `data/` and `logs/`. `/unifi`
  deliberately doesn't exist in the image: podman would copy its root
  ownership into a fresh named volume. Without a volume the container refuses
  to start; for a throwaway run without persistent data, use `--tmpfs /unifi`.
- MongoDB at `MONGO_ADDRESS`: by default 127.0.0.1:27017, i.e. a MongoDB
  container sharing this container's network namespace

Its environment variables are described in the top README's
[Configuration](../README.md#configuration).

## The scripts

| Script | Role |
|---|---|
| `unifi-network-application-entrypoint` | Checks `/unifi`, waits for MongoDB, writes `system.properties`, starts the application |
| `unifi-network-application-wait-for` | Waits until a `HOST:PORT` accepts TCP connections, and rejects an address that isn't one |
| `unifi-network-application-set-properties` | Merges `key=value` settings into `system.properties` |
| `unifi-network-application-healthcheck` | The health check: the application's `/status` answers on its HTTPS port |

Each starts with a header describing its usage and behaviour, and they share
the same conventions: `log`, `die` (exit 1) and `usage` (exit 2), messages
prefixed with `[unifi-network-application]` on stderr.

**Waiting for MongoDB.** The application gives up if MongoDB isn't reachable
about 20 s after it starts (`serverSelectionTimeoutMS` in the URI is
ignored), and MongoDB may be starting at the same time. So the entrypoint
first waits for `MONGO_ADDRESS` to accept TCP connections, up to
`MONGO_WAIT_SECONDS`. mongod only listens once its storage is ready.

**Writing `system.properties`.** On every start the entrypoint writes the
MongoDB defaults (`db.mongo.local=false`, `db.mongo.uri`, `unifi.db.name`)
and then `UNIFI_PROPERTIES` into `data/system.properties`. It replaces any
earlier line for the same key, keeps everything else in the file (including
continuation lines), and swaps the file in atomically. Lines that Java would
read differently than written (see the value rules in the top README) are
skipped with a warning, so the file can't be broken by a setting. It logs
what it writes, with passwords in URIs masked. The application itself
rewrites the file at startup: sorted, with its own escaping and header.

**The health check** reads `unifi.https.port` from `system.properties`
(default 8443) and requests `https://127.0.0.1:<port>/status`. Only the HTTP
status counts, not the `"up"` field: that is false while the application
starts or migrates its database, which can take long, and a liveness probe
failing then would restart it mid-way.
