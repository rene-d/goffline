#!/usr/bin/env bash
# Use a Docker container to call the Go modules downloader

set -Eeuo pipefail

GOLANG_VERSION="${GOLANG_VERSION:-latest}"

DOCKER_SCAN_SUGGEST=false \
    docker build --quiet --build-arg GOLANG_VERSION="${GOLANG_VERSION}" -t goffline $(dirname $0) >/dev/null

do_chown()
{
    # fix docker rootfull bind mount permissions
    if find "$PWD/dl" -user root -print -quit | grep -q "." ; then
        echo "Change owner to $(id -un)"
        exec docker run --rm -i -v "$PWD/dl:/dl" goffline chown -R "$(id -u):$(id -g)" /dl
    fi
}

mkdir -p "$PWD/dl"

if [[ "${1:-}" == "build_only" ]]; then
    # just build the image
    exit

elif [[ "${1:-}" == "version" ]]; then
    # print the GOVERSION
    exec docker run --rm goffline go env GOVERSION

elif [[ "${1:-}" == "shell" ]]; then
    # launch a shell into the container
    exec docker run --rm -ti -v "$PWD:/wd" -w /wd goffline

elif [[ "${1:-}" == "rshell" ]]; then
    # launch a shell into the container without network access
    exec docker run --network none --rm -ti -v "$PWD:/wd" -w /wd goffline

elif [[ "${1:-}" == "chown" ]]; then
    # chown files if Docker is ran rootfull
    do_chown

else
    # download Go modules
    config=
    if [[ $# -ge 2 ]] && [[ "$1" == "-f" ]]; then
        config="-v $(realpath "$2"):/config.txt:ro"
        shift 2
    fi

    exec docker run --init -e TINI_KILL_PROCESS_GROUP=1 --rm -i -v "$PWD/dl:/dl" -w /dl \
        -e "GOFFLINE_VERSION=$(git describe --always --tags)" ${config} goffline /goget.py -f /config.txt -c xz -o /dl "$@"
fi
