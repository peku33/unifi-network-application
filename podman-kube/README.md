# UniFi Network Application as a podman pod (recommended for podman)

| File | Purpose |
|---|---|
| `unifi-network-application.yaml` | Pod definition: `app` + `mongodb` containers, images, published ports, volumes |
| `unifi-network-application-config.yaml` | ConfigMap with the settings (`system_ip`, ports, time zone, …) |
| `unifi-network-application.kube` | Quadlet unit that makes systemd run the pod as `unifi-network-application.service` |

Both containers share the pod's network namespace. MongoDB listens on
127.0.0.1 there and is never published. With `UserNS=keep-id` both containers
run as your own user, so the data volumes stay owned by you.

## Requirements

- podman >= 4.4 (Quadlet `.kube` support), systemd
- A user account with sub-UIDs/GIDs (`grep $USER /etc/subuid`). Regular users
  get them automatically. For a dedicated system user, add a range with
  `usermod --add-subuids … --add-subgids …`.

## Install

Run all of this as the user that should own the UniFi Network Application.
Root is needed only for `loginctl`. Instead of a checkout of this repository,
you can also download the three files straight into
`~/.config/containers/systemd/` and edit them there (see the
[quick start](../README.md#with-podman-rootless-as-a-systemd-service)).

```sh
# 1. Configure: at least uncomment system_ip and set it to the host's LAN address
$EDITOR unifi-network-application-config.yaml

# 2. Optional: build the image yourself instead of pulling the published one
#    (see ../README.md#the-image), then set the app container's image in
#    unifi-network-application.yaml to localhost/unifi-network-application:latest
../app/build.sh --latest

# 3. Create the data volumes (explicitly, so they are browsable by you on the host)
podman volume create unifi-network-application-data
podman volume create unifi-network-application-mongodb

# 4. Install the pod as a systemd user service; the first start pulls the images
mkdir -p ~/.config/containers/systemd
cp unifi-network-application.yaml unifi-network-application-config.yaml \
   unifi-network-application.kube ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start unifi-network-application

# 5. Keep it running without a login session, and start it at boot
sudo loginctl enable-linger "$USER"
```

The UI is then at `https://<host>:8443`.

```sh
systemctl --user status unifi-network-application
podman logs -f unifi-network-application-app    # or: ...-mongodb
```

To run it without systemd (e.g. for a quick test):

```sh
podman kube play --configmap unifi-network-application-config.yaml \
    --userns=keep-id --replace unifi-network-application.yaml
podman pod stop unifi-network-application && podman kube down unifi-network-application.yaml
```

## Configuration

Settings live in `unifi-network-application-config.yaml` (see
[Configuration](../README.md#configuration)). Edit the installed copy in
`~/.config/containers/systemd/`, then run
`systemctl --user restart unifi-network-application`.

`unifi-network-application.yaml` only needs editing to change:

- **the application image** (see [The image](../README.md#the-image)).
- **the published ports.** Keep `containerPort` equal to
  `unifi.http.port`/`unifi.https.port` in the config. Optional ports are listed
  there, commented out. For full L2 discovery, set `hostNetwork: true` instead
  (the `ports` list is then ignored).
- **the MongoDB image**, e.g. `mongo:4.4.18` for older CPUs (see
  [CPU support](../README.md#cpu-support)).
- **the volumes.** To use host directories, replace the
  `persistentVolumeClaim` entries with `hostPath`.

## Upgrading

Images are pulled only when missing, so get the new image first, then run
`systemctl --user restart unifi-network-application`:

- **`:latest` from the registry:** `podman pull ghcr.io/peku33/unifi-network-application:latest`.
- **`:latest` you build:** `../app/build.sh --latest` (or
  `../app/build.sh --latest <version>`) moves the tag to the new version. To
  roll back, point it at the old one:
  `podman tag localhost/unifi-network-application:<old> localhost/unifi-network-application:latest`.
- **A version tag:** change it in the installed `unifi-network-application.yaml`.
  A missing image is pulled on start; a `localhost/` one must be built first,
  e.g. `../app/build.sh <version>`.

## Automatic updates

Off by default. When on, podman checks once a day for new images of the tags
in use, the application's (`:latest` by default) and MongoDB's (`8`). When one
changed, it restarts the service onto it, with the same orderly stop as
`systemctl --user restart`. If the service then fails to start, it goes back
to the previous images. To turn them on, uncomment `AutoUpdate=registry` in the
installed `~/.config/containers/systemd/unifi-network-application.kube`, then:

```sh
systemctl --user daemon-reload
systemctl --user restart unifi-network-application
systemctl --user enable --now podman-auto-update.timer
podman auto-update --dry-run    # lists the containers it covers, and pending updates
```

- **A pinned application version** (e.g. `:10.6.109`) has no newer image, so
  only MongoDB is updated.
- **An image you build:** use `AutoUpdate=mongodb/registry` and
  `AutoUpdate=app/local` instead. After you build a new `:latest` with
  `../app/build.sh --latest`, the next run restarts the application onto it.
- **Backups:** a new version migrates the database on its first start, which
  going back to the previous image doesn't undo. Enable the application's
  scheduled backups, so there is one from before each update.
- `podman-auto-update.timer` runs daily around midnight, for all of your
  containers marked for it. `systemctl --user edit podman-auto-update.timer`
  changes that.

## Shutdown

`unifi-network-application.kube` adds two `ExecStop` lines on top of what
Quadlet generates. Quadlet only runs `podman kube down`, which removes the pod
almost immediately and leaves MongoDB uncleanly shut down. The unit stops the
application first (it stalls on shutdown if MongoDB goes away first), then the
pod. A full stop takes a few seconds.

## Ansible

To deploy this setup with Ansible, see [ansible/README.md](ansible/README.md).
