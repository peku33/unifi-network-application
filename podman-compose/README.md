# UniFi Network Application with podman-compose

The same deployment as [`podman-kube/`](../podman-kube/README.md), written as
a compose file. Use it if you prefer compose syntax and `.env` variables. The
kube setup is the recommended one for podman: it needs no extra tool and
integrates with systemd through Quadlet.

| File | Purpose |
|---|---|
| `compose.yaml` | `app` + `mongodb` services |
| `.env.example` | Settings: copy to `.env` |

## Requirements

- podman, and [podman-compose](https://github.com/containers/podman-compose)
  (tested with 1.6.0). For docker, use [`docker-compose/`](../docker-compose/README.md):
  this file relies on podman-specific settings (`userns_mode`).
- A systemd user session (lingering, see below), to start the stack at boot
  and for podman to run the application's health check

## Usage

```sh
cp .env.example .env
$EDITOR .env                     # PUID/PGID (id -u / id -g), system_ip in UNIFI_PROPERTIES, ...

# Optional: build the image yourself instead of pulling the published one
# (see ../README.md#the-image), then set UNIFI_IMAGE=localhost/unifi-network-application:latest in .env
../app/build.sh --latest

podman volume create unifi-network-application-data
podman volume create unifi-network-application-mongodb
sudo loginctl enable-linger "$USER"

podman-compose up -d             # pulls the images on the first start
podman-compose logs -f app
podman-compose down
```

The UI is then at `https://<host>:8443`. All settings go in `.env` (see
[Configuration](../README.md#configuration)); recreate the containers after
changing it. Set the device inform and UI ports with `UNIFI_HTTP_PORT` /
`UNIFI_HTTPS_PORT`, not in `UNIFI_PROPERTIES`: compose publishes them and
passes them to the application as `unifi.http.port` / `unifi.https.port`.
Optional ports are listed in `compose.yaml`, commented out.

To upgrade, get the new image, then recreate the containers with
`podman-compose down && podman-compose up -d`:

- **`:latest` from the registry:** `podman-compose pull app` (`up` pulls only
  missing images).
- **`:latest` you build:** `../app/build.sh --latest` moves it to the new
  version.
- **A version tag:** change it in `UNIFI_IMAGE` (a `localhost/` one must be
  built first, e.g. `../app/build.sh <version>`).

The volumes are the same ones podman-kube uses, so run only one of the two
at a time.

podman-compose has no Quadlet integration. To start the stack at boot (with
lingering enabled, see above), use a systemd user unit that runs
`podman-compose up -d` / `down`. Set `WorkingDirectory` to this directory and
the podman-compose path to the output of `command -v podman-compose`:

```ini
# ~/.config/systemd/user/unifi-network-application.service
[Unit]
Description=UniFi Network Application
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=%h/unifi-network-application/podman-compose
# The first start pulls the images. "down" waits up to 90 s per container.
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
TimeoutStartSec=600
TimeoutStopSec=200

[Install]
WantedBy=default.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now unifi-network-application
```

## How it differs from the pod

Compose has no pods with a shared user namespace, so the file rebuilds that
by hand. Each of these was found by testing:

- **`mongodb` publishes all the ports**, and `app` joins its network namespace
  (`network_mode: service:mongodb`). That way they share 127.0.0.1 like a pod,
  and MongoDB stays unpublished.
- **`app` also joins MongoDB's user namespace**
  (`userns_mode: container:unifi-network-application-mongodb`). With its own
  `keep-id` namespace, joining MongoDB's network namespace fails
  (`error mounting "sysfs" … operation not permitted`).
- **`app` runs as `PUID:PGID`.** A container that joins a `keep-id` namespace
  starts as its root, which maps to one of your sub-UIDs on the host, so files
  it wrote would not be owned by you.
- **`x-podman: in_pod: false`.** With a pod, podman-compose 1.6.0 still gives
  each container its own network, so the application can't reach MongoDB on
  127.0.0.1.

Unlike `podman kube down`, `podman-compose down` stops the containers
gracefully: MongoDB shuts down cleanly with no extra configuration.
