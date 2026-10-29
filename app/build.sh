#!/usr/bin/env bash
# Builds the UniFi Network Application image with a verified download.
#
# Usage: ./build.sh [OPTIONS] [VERSION] [-- BUILD_ARGS...]
#
#   ./build.sh                      build the latest release
#   ./build.sh 10.6.109             build a specific version
#   ./build.sh --latest             ... and also tag it IMAGE:latest
#   ./build.sh --no-build           only look up the latest version and checksum
#   ./build.sh -- --pull=always     pass extra arguments to "podman/docker build"
#
# Options:
#   -i, --image NAME    image name, without tag (default: localhost/unifi-network-application)
#   -e, --engine NAME   podman or docker (default: podman if installed, else docker)
#   -l, --latest        also tag the image NAME:latest
#   -n, --no-build      only look up and print the version and checksum
#   -h, --help          show this help
#
# Looks up the version (the latest release unless one is given) and the
# SHA-256 of its UniFi.unix.zip in Ubiquiti's update API (fw-update.ubnt.com),
# then runs "podman build" (or "docker build") with both. The Containerfile
# itself only downloads the zip from dl.ui.com. A version the API doesn't list
# is built without checksum verification, with a warning.
#
# Output: progress messages and the build log go to stderr. stdout gets
# only KEY=VALUE lines, printed once the lookup (and build) succeeded, so
# scripts can use them with eval, $GITHUB_OUTPUT or as an .env file:
#   UNIFI_VERSION=10.6.109
#   UNIFI_SHA256=6771ed35...   (empty if the build is unverified)
#   IMAGE=localhost/unifi-network-application:10.6.109
# Exits 1 on errors, 2 on wrong usage.
#
# Needs curl and jq, and podman or docker unless --no-build is given.
#
# (--help prints this header: every comment line up to the first non-comment line.)
set -euo pipefail

log() { echo "[unifi-network-application] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }
usage() {
    log "ERROR: $*"
    echo "Usage: ${0##*/} [OPTIONS] [VERSION] [-- BUILD_ARGS...]   (--help for details)" >&2
    exit 2
}
help() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0; }

# Ubiquiti's update API, selecting the standalone ("unix") build of the UniFi
# Network Application ("unifi-controller" is Ubiquiti's product ID), newest
# version first, one entry. The lookups below add their own filter.
api_url="https://fw-update.ubnt.com/api/firmware?filter=eq~~product~~unifi-controller&filter=eq~~platform~~unix&sort=-version&limit=1"
# A version as Ubiquiti numbers them: three numbers without leading zeros.
version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# Parse the arguments: options, an optional VERSION, then "--" and build args.
image=localhost/unifi-network-application
engine=""
tag_latest=false
build=true
version=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -i|--image) [ "$#" -ge 2 ] || usage "$1 needs a value"; image=$2; shift 2 ;;
        --image=*) image=${1#*=}; shift ;;
        -e|--engine) [ "$#" -ge 2 ] || usage "$1 needs a value"; engine=$2; shift 2 ;;
        --engine=*) engine=${1#*=}; shift ;;
        -l|--latest) tag_latest=true; shift ;;
        -n|--no-build) build=false; shift ;;
        -h|--help) help ;;
        --) shift; break ;;
        -*) usage "unknown option: $1" ;;
        *) [ -z "$version" ] || usage "more than one version given: $version, $1"; version=$1; shift ;;
    esac
done
# Whatever is left in "$@" is passed to the build command.
[ -n "$image" ] || usage "the image name is empty"
case "$engine" in
    podman|docker|"") ;;
    *) usage "--engine must be podman or docker, got: $engine" ;;
esac
[ -z "$version" ] || [[ $version =~ $version_pattern ]] ||
    usage "VERSION must look like 10.6.109, got: $version"

# Check that the tools this run needs are installed.
if $build && [ -z "$engine" ]; then
    if command -v podman >/dev/null; then engine=podman; else engine=docker; fi
fi
tools=(curl jq)
if $build; then tools+=("$engine"); fi
for tool in "${tools[@]}"; do
    command -v "$tool" >/dev/null || die "$tool is required"
done

# Narrow the API query down to the wanted version:
#  - no version: the newest release
#  - a version:  exactly that version, matched on its three numeric parts
if [ -z "$version" ]; then
    query="$api_url&filter=eq~~channel~~release"
else
    [[ $version =~ $version_pattern ]]
    query="$api_url&filter=eq~~version_major~~${BASH_REMATCH[1]}"
    query="$query&filter=eq~~version_minor~~${BASH_REMATCH[2]}"
    query="$query&filter=eq~~version_patch~~${BASH_REMATCH[3]}"
fi

# Ask the API, and take the single entry from the response (if any).
log "looking up ${version:-the latest release} in the update API"
response=$(curl -fsS --retry 3 --max-time 30 "$query") || die "cannot query the update API"
entry=$(jq -c '._embedded.firmware[0] // empty' <<< "$response" 2>/dev/null) ||
    die "the update API returned something other than the expected JSON"

# Without an entry there is nothing to build for "latest"; a named version is
# built anyway, unverified.
sha256=""
if [ -z "$entry" ]; then
    [ -n "$version" ] || die "the update API returned no release"
    log "WARNING: $version is not in the update API; its download will NOT be verified"
else
    # Don't trust that the API applied the filters (e.g. after a change on
    # Ubiquiti's side): check the entry is what was asked for, rather than
    # build whatever it returned.
    jq -e '.product == "unifi-controller" and .platform == "unix"' <<< "$entry" >/dev/null ||
        die "the update API returned an entry for another product or platform"
    # Its version: "v10.6.109+atag-..." -> "10.6.109". It goes into the image
    # tag and the download URL, so it must look like a version.
    found=$(jq -r '.version | ltrimstr("v") | split("+")[0]' <<< "$entry")
    [[ $found =~ $version_pattern ]] || die "the update API returned an unexpected version: $found"
    if [ -z "$version" ]; then
        jq -e '.channel == "release"' <<< "$entry" >/dev/null ||
            die "the update API returned $found from a non-release channel"
        version=$found
    elif [ "$found" != "$version" ]; then
        die "asked the update API for $version, but it returned $found"
    fi
    # Its checksum.
    sha256=$(jq -r '.sha256_checksum // empty' <<< "$entry")
    [[ $sha256 =~ ^[0-9a-f]{64}$ ]] || die "the update API has no valid SHA-256 for $version"
    log "found $version, SHA-256 $sha256"
fi

# Build the image from the directory this script is in, tagged with the
# version (and latest if asked), passing the checksum when there is one.
# The build's output goes to stderr, keeping stdout for the result below.
# The Containerfile is named explicitly: docker looks for a Dockerfile.
if $build; then
    names=("$image:$version")
    if $tag_latest; then names+=("$image:latest"); fi
    build_args=(--build-arg "UNIFI_VERSION=$version")
    if [ -n "$sha256" ]; then build_args+=(--build-arg "UNIFI_SHA256=$sha256"); fi
    dir=$(dirname "$0")
    log "building ${names[*]} with $engine"
    "$engine" build "${build_args[@]}" "${names[@]/#/--tag=}" --file "$dir/Containerfile" "$@" "$dir" >&2 ||
        die "$engine build failed"
fi

# The result, for scripts.
echo "UNIFI_VERSION=$version"
echo "UNIFI_SHA256=$sha256"
echo "IMAGE=$image:$version"
