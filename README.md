# UniFi Network Application in containers

Runs Ubiquiti's UniFi Network Application (the self-hosted controller for
UniFi devices) and its MongoDB in containers, with podman or docker, on amd64
or arm64. The application runs as a non-root user, MongoDB is not reachable
from outside, and the settings are in one file.

## Deployment methods

| Directory | Runs with | Starts at boot |
|---|---|---|
| [`podman-kube/`](podman-kube/README.md) (recommended for podman) | `podman kube play`, rootless, as a pod | systemd user service (Quadlet) |
| [`podman-compose/`](podman-compose/README.md) | podman-compose, rootless | a systemd user unit |
| [`docker-compose/`](docker-compose/README.md) | `docker compose` | docker's restart policy |

Each directory's README has the installation steps; the sections below
apply to all of them. Use one method per host: they publish the same ports.

## The image

All methods run the published image
`ghcr.io/peku33/unifi-network-application` (amd64 and arm64), tagged with the
application's version, e.g. `:10.6.109`, and `:latest`. It is pulled on the
first start. `:latest` is the default; a version tag pins the version.

To build the image yourself instead, on the machine that runs it (needs
`curl`, `jq`, and podman or docker):

```sh
app/build.sh --latest      # or e.g. app/build.sh --latest 10.6.109
```

This creates `localhost/unifi-network-application:<version>` and `:latest`.
Then point your method at it:

| Method | Where the image is set |
|---|---|
| podman-kube | `image:` of the `app` container in `unifi-network-application.yaml` |
| podman-compose, docker-compose | `UNIFI_IMAGE` in `.env` |

How the image is built and works inside: [app/README.md](app/README.md).

## Configuration

The application is configured with the environment variables below. Where
they go:

| Method | Settings go in |
|---|---|
| podman-kube | `data:` of the ConfigMap in `unifi-network-application-config.yaml` |
| podman-compose, docker-compose | `.env` (each variable has a line there) |

| Variable | Effect |
|---|---|
| `UNIFI_PROPERTIES` | `system.properties` settings, one `key=value` per line (blank and `#` lines ignored) |
| `TZ` | Time zone, e.g. `Europe/Berlin` (default UTC) |
| `JVM_MAX_HEAP`, `JVM_INIT_HEAP` | `-Xmx` (default `1024M`), `-Xms` (default unset), e.g. `512M` or `2G` |
| `JVM_EXTRA_OPTS` | Extra JVM options, separated by whitespace or newlines |
| `MONGO_ADDRESS` | MongoDB's `host:port` (default `127.0.0.1:27017`, the MongoDB next to it) |
| `MONGO_WAIT_SECONDS` | How long to wait for MongoDB at startup; `0` skips waiting (default 120) |
| `MONGO_CACHE_SIZE_GB` | MongoDB's cache, in GB (default 0.25, the smallest it accepts). Raise it, e.g. to `1`, for large sites (hundreds of devices) whose UI gets slow. Applies to the MongoDB container. |

The application's own settings all go through `UNIFI_PROPERTIES`. Set at
least `system_ip`. The common keys:

| Key | Meaning (default) |
|---|---|
| `system_ip` | The address devices are told to inform to: the host's LAN IP |
| `unifi.http.port` / `unifi.https.port` | Device inform (8080) / UI and API (8443); see [Ports](#ports) |
| `portal.http.port` / `portal.https.port` | Guest portal (8880 / 8843) |
| `unifi.stun.port`, `unifi.throughput.port` | STUN (3478), mobile speed test (6789) |
| `db.mongo.uri`, `unifi.db.name` | MongoDB connection and database (`mongodb://<MONGO_ADDRESS>/unifi`, `unifi`) |

Each line is `key=value`. Keys may contain only letters, digits and `._-`.
Spaces around `=` and at the ends of the line are dropped. Values may
contain only printable ASCII and tabs; write other characters as `\uXXXX`,
and a literal backslash as `\\`. A line that breaks these rules is skipped
with a warning in the log.

The settings are applied on every start and replace earlier values of the
same keys in `system.properties`, so this is where they are changed. Keys you
don't set keep the values the application stored.

**A MongoDB elsewhere:** set `MONGO_ADDRESS`, e.g. `db.example.com:27017` or
`[fd00::10]:27017`. For credentials or connection options, also set the
whole URI, with the same host and port:

```
MONGO_ADDRESS=db.example.com:27017
UNIFI_PROPERTIES="db.mongo.uri=mongodb://USER:PASSWORD@db.example.com:27017/unifi?authSource=admin"
```

## Ports

The ports the application serves, from Ubiquiti's
[Required Ports Reference](https://help.ui.com/hc/en-us/articles/218506997-Required-Ports-Reference):

| Port | Purpose | Published |
|---|---|---|
| 8080/tcp | Device inform: devices talk to the application | yes, required |
| 8443/tcp | UI / API | yes, required |
| 3478/udp | STUN: device adoption and communication | yes, required |
| 10001/udp | Device discovery during adoption (see below) | yes |
| 6789/tcp | Mobile speed test | optional |
| 8880/tcp, 8843/tcp | Hotspot (guest) portal redirection, HTTP / HTTPS | optional |
| 28082/tcp | Packet captures and support files from devices | optional |
| 5514/udp | Remote syslog from devices | optional |
| 1900/udp | Makes the application discoverable on the LAN (when enabled in its settings) | optional |

The optional ports are listed, commented out, next to the published ones
(`unifi-network-application.yaml` or `compose.yaml`). Each is published under
the same number on the host.

**Device discovery (10001/udp)** lets the application see new devices that
broadcast on the same LAN, so they show up for adoption. It is published, but
container port forwarding may not pass broadcasts on to the application; for
full LAN discovery, use host networking (`hostNetwork: true` in podman-kube).
Devices can always be adopted without it: point them at the application with
DHCP option 43, a DNS name `unifi` resolving to the host, or `set-inform
http://<host>:8080/inform` over SSH.

Other ports in Ubiquiti's reference don't apply here: 27117 is the
application's built-in MongoDB (a separate container here, never published);
5671, 8444, 8881–8882, 10101 and 20100–22100 are for UniFi consoles and
gateways, and a fresh self-hosted 10.6 doesn't open them (publish one if a
feature turns out to need it); 53, 123, 443 and 8883 are outgoing
connections, which need no publishing.

To move the device inform or UI port:

| Method | Set |
|---|---|
| podman-kube | `unifi.http.port` / `unifi.https.port` in `UNIFI_PROPERTIES`, and the same numbers as `containerPort` and `hostPort` in `unifi-network-application.yaml` |
| podman-compose, docker-compose | `UNIFI_HTTP_PORT` / `UNIFI_HTTPS_PORT` in `.env` (not in `UNIFI_PROPERTIES`) |

## Data and backups

| Volume | Contents |
|---|---|
| `unifi-network-application-data` | `data/` (`system.properties`, keystore, `backup/autobackup/`) and `logs/` |
| `unifi-network-application-mongodb` | MongoDB's database files |

`podman volume inspect <volume> --format '{{.Mountpoint}}'` (or
`docker volume inspect <volume>`) shows where a volume is on the host.
Configure automatic backups in the application's settings; they land in
`data/backup/autobackup/`. Copy them off the host: a backup on the same disk
doesn't survive the disk. To restore, start with empty volumes and choose
the backup file in the setup wizard.

## Upgrading

Get the new image and restart; the method READMEs have the exact commands.
With `:latest`, pull it again (or rebuild it); with a version tag, change the
tag. The application migrates its database on the first start of a new version, which
can take a few minutes.

## Architecture

| Path | Contents |
|---|---|
| [`app/`](app/README.md) | The application image: `build.sh`, `Containerfile`, and the container's scripts in `bin/` |
| `podman-kube/`, `podman-compose/`, `docker-compose/` | The deployment methods: the application image plus MongoDB |

- Two containers: `app` (this repository's image) and `mongodb` (the official
  `mongo` image).
- They share one network namespace (a pod, or `network_mode: service:mongodb`
  in compose). MongoDB listens on 127.0.0.1 there and is never published;
  only the application's ports are.
- The application runs as a non-root user: with podman your own (rootless,
  `keep-id`), with docker `PUID`/`PGID` from `.env`.
- On each start, the image's entrypoint writes the settings into
  `system.properties`, waits until MongoDB accepts connections, and starts the
  application. A health check requests the application's `/status` page.

## CPU support

MongoDB 5.0 and newer needs AVX on amd64 and ARMv8.2-A on arm64. On older
CPUs, use MongoDB 4.4.18. 32-bit systems are not supported: use a 64-bit OS.

| CPU | MongoDB image |
|---|---|
| amd64 with AVX; arm64 ARMv8.2-A or newer | `docker.io/library/mongo:8` (the default: the newest 8.x release) |
| amd64 without AVX; arm64 ARMv8.0 (e.g. Raspberry Pi 4) | `docker.io/library/mongo:4.4.18` |

Where to set it: the `mongodb` container's `image:` in
`unifi-network-application.yaml` (podman-kube), `MONGO_VERSION` in `.env`
(compose).

`mongo:8` follows MongoDB's 8.x releases: an existing database is upgraded in
place when a newer 8.x image is pulled (tested from 8.0 to 8.3 with the
application 10.6.109). To stay on one, use its tag, e.g. `mongo:8.0`.

You can't switch MongoDB versions in place across major versions. To change
versions, take a backup in the UI, start with an empty database volume and
restore the backup.
