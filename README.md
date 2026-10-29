# UniFi Network Application on rootless podman

A container image for the standalone UniFi Network Application
(`UniFi.unix.zip`) on Temurin 25, meant to run as your own (non-root) user
next to a MongoDB container. It works on amd64 and arm64.

| Path | Purpose |
|---|---|
| `build.sh` | Builds the image: looks up the version and checksum, then runs `podman build` |
| `Containerfile` | The image: Temurin 25 JRE + the UniFi Network Application zip + tini |
| `bin/` | The container's scripts, installed into `/usr/local/bin` in the image: the entrypoint (writes `system.properties`, waits for MongoDB, starts the application), the health check, and the two helpers the entrypoint uses for that |

## The image

Build it on the machine that runs it. No registry is needed, and podman builds
for whatever architecture it runs on.

```sh
./build.sh --latest             # the latest release, also tagged latest
./build.sh --latest 10.6.109    # a specific version
./build.sh 10.5.67              # an older version, without touching latest
./build.sh --no-build           # only look up the latest version and checksum
```

`build.sh` is the only part that talks to Ubiquiti's update API
(`fw-update.ubnt.com`). It looks up the version (the latest release unless you
name one) and the SHA-256 of its zip there, then runs `podman build` with both.
The Containerfile downloads the zip from `dl.ui.com` and checks it against
that SHA-256. It needs `curl` and `jq`; `./build.sh --help` lists the options.
Anything after `--` is passed to `podman build`, e.g.
`./build.sh --latest -- --pull=always` to refresh the Temurin base image.

The image is tagged `localhost/unifi-network-application:<version>`, and also
`:latest` with `--latest`. `localhost/` is podman's prefix for images that come
from no registry; `--image` sets another name, e.g. a registry path.

If you run the `:latest` tag, upgrading is: build the new version with
`--latest`, then restart the container. To roll back, point `latest` at the
old version and restart:

```sh
podman tag localhost/unifi-network-application:<old> localhost/unifi-network-application:latest
```

For scripts, `build.sh` prints its progress and podman's build log to stderr,
and only the result to stdout, as `KEY=VALUE` lines. They work with `eval`, as
an `.env` file, or appended to `$GITHUB_OUTPUT`:

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

To build without `build.sh`, call `podman build` yourself. `UNIFI_VERSION` is
required and `UNIFI_SHA256` optional; without a checksum the build warns that
the download is not verified. A bare `--build-arg NAME` takes the value from
the environment.

```sh
podman build --build-arg UNIFI_VERSION=<version> [--build-arg UNIFI_SHA256=<sha256>] \
  -t localhost/unifi-network-application:<version> .
```

The image expects:

- to run as a non-root UID/GID (it needs no passwd entry)
- a writable volume at `/unifi`, which holds `data/` and `logs/`. `/unifi`
  deliberately doesn't exist in the image: podman would copy its root
  ownership into a fresh named volume. Without a volume the container refuses
  to start; for a throwaway run without persistent data, use `--tmpfs /unifi`.
- MongoDB at `MONGO_ADDRESS`: by default 127.0.0.1:27017, i.e. a MongoDB
  container sharing this container's network namespace (see below for
  another one)

## Configuration

| Variable | Effect |
|---|---|
| `UNIFI_PROPERTIES` | `system.properties` settings, one `key=value` per line (blank and `#` lines ignored) |
| `MONGO_ADDRESS` | MongoDB's `host:port` (default `127.0.0.1:27017`): the default `db.mongo.uri`, and what the entrypoint waits for |
| `MONGO_WAIT_SECONDS` | How long to wait for MongoDB at startup; `0` skips waiting (default 120) |
| `JVM_MAX_HEAP`, `JVM_INIT_HEAP` | `-Xmx` (default `1024M`), `-Xms` (default unset), e.g. `512M` or `2G` |
| `JVM_EXTRA_OPTS` | Extra JVM options, separated by whitespace or newlines |
| `TZ` | Time zone, e.g. `Europe/Berlin` (default UTC) |

The application's own settings all go through `UNIFI_PROPERTIES`. The common
ones:

| Key | Meaning (default) |
|---|---|
| `system_ip` | The address devices are told to inform to: the host's LAN IP |
| `unifi.http.port` / `unifi.https.port` | Device inform (8080) / UI and API (8443) |
| `portal.http.port` / `portal.https.port` | Guest portal (8880 / 8843) |
| `unifi.stun.port`, `unifi.throughput.port` | STUN (3478), mobile speed test (6789) |
| `db.mongo.uri`, `unifi.db.name` | MongoDB connection and database (`mongodb://<MONGO_ADDRESS>/unifi`, `unifi`); statistics go to `<name>_stat` |

Each line is `key=value`. Keys may contain only letters, digits and `._-`
(the entrypoint warns about and skips other lines). Spaces around `=` and at
the ends of the line are dropped. Values are written as given, and Java
interprets `\` escapes in them as in any `.properties` file, so write `\\`
for a literal backslash. Values may contain only printable ASCII and tabs;
write other characters as `\uXXXX`. A value Java wouldn't read back as
written (other characters, a `\u` without 4 hex digits, a single `\` at the
end) is skipped with a warning.

The application gives up if MongoDB isn't reachable about 20 s after it
starts, so the entrypoint first waits for `MONGO_ADDRESS` to accept TCP
connections. For a MongoDB elsewhere, setting `MONGO_ADDRESS` (e.g.
`db.example.com:27017` or `[fd00::10]:27017`) is enough. For credentials or
connection options, also set the whole URI, with the same host and port:

```
MONGO_ADDRESS: db.example.com:27017
UNIFI_PROPERTIES: |
  db.mongo.uri=mongodb://USER:PASSWORD@db.example.com:27017/unifi?authSource=admin
```

On every start the entrypoint writes these, after the MongoDB defaults
(`db.mongo.local=false` and the two above), into `data/system.properties`. It
replaces any earlier line for the same key, keeps everything else in the file,
and swaps the file in atomically. It logs what it writes, with passwords in
URIs masked. The health check (`unifi-network-application-healthcheck`)
reads the UI port from that file.

## Ports

| Port | Purpose | Needed |
|---|---|---|
| 8080/tcp | device inform | yes |
| 8443/tcp | UI / API | yes |
| 3478/udp | STUN | yes |
| 10001/udp | AP discovery | yes |
| 6789/tcp | mobile speed test | optional |
| 8880, 8843/tcp | guest portal | optional |
| 1900/udp | L2 discovery | optional |
| 5514/udp | remote syslog | optional |

## MongoDB and CPU support

| Host CPU | MongoDB image |
|---|---|
| amd64 with AVX, arm64 ARMv8.2-A or newer (Pi 5, Graviton, Ampere, Apple) | `docker.io/library/mongo:7.0` |
| amd64 without AVX, Raspberry Pi 4 and other ARMv8.0 cores | `docker.io/library/mongo:4.4.18` |

### Raspberry Pi

- Use a 64-bit OS (arm64). Temurin 25 and MongoDB have no 32-bit ARM images.
- Build the image on the Pi itself, as above.
- Pi 4: `mongo:4.4.18`. Pi 5: `mongo:7.0`.
- `JVM_MAX_HEAP` defaults to 1024M. Cap MongoDB's cache too (e.g.
  `--wiredTigerCacheSizeGB 0.25`). Plan for at least 2 GB of RAM, and lower
  `JVM_MAX_HEAP` (e.g. `512M`) on a 2 GB model.

You can't switch MongoDB versions in place across major versions. To change
versions, take a backup in the UI, start with an empty database volume and
restore the backup.
