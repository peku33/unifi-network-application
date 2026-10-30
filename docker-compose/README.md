# UniFi Network Application with Docker Compose

The same deployment as the podman setups, for docker: the application and
MongoDB share one network namespace, MongoDB listens on 127.0.0.1 there and
is never published, and the application runs as a non-root user.

| File | Purpose |
|---|---|
| `compose.yaml` | `app` + `mongodb` services, and `data-owner`, which prepares the data volume |
| `.env.example` | Settings: copy to `.env` |

## Requirements

- docker with the compose plugin (`docker compose`, tested with docker 29 and
  compose 5.6), rootful or rootless

## Usage

Run this in a checkout of this repository, or in any directory with just
`compose.yaml` and `.env.example` downloaded into it (see the
[quick start](../README.md#with-docker-compose)).

```sh
cp .env.example .env
$EDITOR .env                     # system_ip in UNIFI_PROPERTIES, ...

# Optional: build the image yourself instead of pulling the published one
# (see ../README.md#the-image), then set UNIFI_IMAGE=localhost/unifi-network-application:latest in .env
../app/build.sh --latest

docker compose up -d             # pulls the images on the first start
docker compose logs -f app
docker compose down
```

The UI is then at `https://<host>:8443`. With `restart: unless-stopped` the
stack starts again with the docker daemon, e.g. at boot, until you stop it
with `docker compose down` (or `stop`).

All settings go in `.env` (see [Configuration](../README.md#configuration));
run `docker compose up -d` after changing it. Set the device inform and UI
ports with `UNIFI_HTTP_PORT` / `UNIFI_HTTPS_PORT`, not in `UNIFI_PROPERTIES`:
compose publishes them and passes them to the application as
`unifi.http.port` / `unifi.https.port`. Optional ports are listed in
`compose.yaml`, commented out.

To upgrade, get the new image, then run `docker compose up -d`, which
recreates the containers whose image changed:

- **`:latest` from the registry:** `docker compose pull` (`up` pulls only
  missing images).
- **`:latest` you build:** `../app/build.sh --latest` moves it to the new
  version.
- **A version tag:** change it in `UNIFI_IMAGE` (a `localhost/` one must be
  built first, e.g. `../app/build.sh <version>`).

## How it differs from the podman setups

- **The application runs as `PUID:PGID`** from `.env` (default 1000:1000).
  Any non-root IDs work; there is no rootless user namespace to map them to
  your own user.
- **`data-owner`** gives the data volume to that user. Docker creates a new
  volume owned by root, and the image has no `/unifi` it could copy an owner
  from. It runs on every `up`, changes the owner of the volume's top directory
  only, and exits. If you change `PUID`/`PGID` later, change the owner of the
  files already in the volume as well.
- **Docker creates the volumes** (`unifi-network-application-data` and
  `unifi-network-application-mongodb`) on the first `up`; there is nothing to
  create beforehand. `docker volume inspect <name>` shows where they are.
- **MongoDB runs as the image's own `mongodb` user**, as the official image
  does by default.

## Ansible

To deploy this setup with Ansible, see [ansible/README.md](ansible/README.md).
