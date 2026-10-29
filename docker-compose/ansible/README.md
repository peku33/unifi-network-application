# Ansible role for the docker-compose setup (optional)

Deploys the [docker-compose setup](../README.md) on one or more hosts: as the
ready playbook [`unifi.yml`](unifi.yml), or as the role
[`unifi_docker_compose`](roles/unifi_docker_compose) in your own playbook.

## Requirements

- On the control node: Ansible with the `community.docker` collection
  (included in the `ansible` package; with `ansible-core`:
  `ansible-galaxy collection install community.docker`)
- On the hosts: docker with the compose plugin 2.18 or newer, and systemd.
  The role checks the version, but doesn't install docker.

## Running the playbook

Put the hosts in a `unifi` group and set the [settings](#settings) in
host_vars / group_vars, e.g. `host_vars/controller.example.com.yml`:

```yaml
unifi_env:
  TZ: Europe/Berlin
```

```sh
ansible-playbook -i inventory docker-compose/ansible/unifi.yml
```

## Using the role in your own playbook

```yaml
- hosts: controller.example.com
  roles:
    - role: vendor/unifi-network-application/docker-compose/ansible/roles/unifi_docker_compose
      vars:
        unifi_env:
          TZ: Europe/Berlin
```

The settings can also come from your inventory. The role needs gathered
facts, and becomes root for its tasks.

The path points into a checkout of this repository in your project, e.g. a
git submodule (`git submodule add
https://github.com/peku33/unifi-network-application
vendor/unifi-network-application`). Use the role from there: it needs the
rest of the checkout. Alternatively add
`vendor/unifi-network-application/docker-compose/ansible/roles` to
`roles_path` in your `ansible.cfg` and refer to it as `unifi_docker_compose`.

## Settings

The defaults are those of the [docker-compose setup](../README.md), from its
`.env.example`. These variables change them:

| Variable | Default | Sets |
|---|---|---|
| `unifi_version` | `latest` | the application version: `latest` (the newest release) or e.g. `10.6.109`; see [Upgrading](#upgrading) |
| `unifi_image` | `ghcr.io/peku33/unifi-network-application` | the application image, without a tag (the tag is `unifi_version`); see below |
| `unifi_mongo_version` | `8` | MongoDB's version (`8`: the newest 8.x release); `4.4.18` for older CPUs, see [CPU support](../../README.md#cpu-support) |
| `unifi_env` | `{}` | [settings](../../README.md#configuration) such as `TZ`, `PUID` or `UNIFI_HTTP_PORT`, over `.env.example` |
| `unifi_system_ip` | the host's IPv4 address | `system_ip` in `system.properties` (empty: not set) |
| `unifi_properties` | `{}` | other `system.properties` settings |

All of them, with comments, are in
[`defaults/main.yml`](roles/unifi_docker_compose/defaults/main.yml).

**The image:** by default the published image is pulled. Set `unifi_image` to
a `localhost/` name, e.g. `localhost/unifi-network-application`, to build it
on the host instead (see [The image](../../README.md#the-image)).

**Other ports:** set them in `unifi_env`, not `unifi_properties`. They are
published under the same numbers and passed to the application. Optional
ports are listed in [`compose.yaml`](../compose.yaml), commented out.

```yaml
unifi_env:
  UNIFI_HTTP_PORT: 8081
  UNIFI_HTTPS_PORT: 8444
```

The role stops before changing anything if `unifi_version` is neither
`latest` nor a version or
`unifi_image` has a tag.

## What it does

- makes docker start at boot
- pulls or builds the application image
- installs the stack in `/opt/unifi-network-application/` and runs
  `docker compose up`, which pulls MongoDB, creates the volumes on the first
  run, and recreates the containers when a setting or an image changed.
  Docker starts the stack again at boot.

Unlike the podman roles, it creates no user: the application runs as
`PUID`/`PGID` (default 1000:1000).

## Upgrading

With the default `unifi_version: latest`, every run upgrades to the newest
release: it pulls the `latest` image again (or, when building, looks up the
newest release and builds it if it isn't there yet), and restarts the
application only if that brought a new version. The application can't update
itself from its UI in a container: a new version always comes as a new image.

To pin a version, set it, e.g. `unifi_version: "10.6.109"`: the role then
gets exactly that version, once, and leaves it alone on later runs. To
upgrade or roll back, change it and run the role again.

The application migrates its database on the first start of a new version.
Rolling back to an older version than the database was last used with may not
work: restore a backup from before the upgrade instead.

MongoDB is pulled on the first start only, so `mongo:8` stays on the 8.x
release it got then. To move to the newest one:

```sh
cd /opt/unifi-network-application/compose
sudo docker compose pull mongodb && sudo docker compose up -d
```

Don't use this on a host that runs one of the podman setups: they publish the
same ports.

## Status and logs

On the deployed host:

```sh
cd /opt/unifi-network-application/compose
sudo docker compose ps
sudo docker compose logs -f app
```
