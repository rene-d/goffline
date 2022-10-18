#!/usr/bin/env bash
# Use a Docker container to call the Go modules downloader

set -Eeuo pipefail

if [[ -d $(dirname $0)/.git ]]; then
    goffline_version=$(git describe --always --tags)
else
    goffline_version=${GOFFLINE_VERSION:-latest}
fi

golang_version=latest
dest_dir=$PWD/download
config=${1:-config.txt}
go_tag=
show_version=

while [[ ${1-} ]]; do
    case $1 in
        -d|--dest-dir) dest_dir=$(cd $2; pwd) ; shift ;;
        -c|--config) config=$2 ; shift ;;
        --go-version) golang_version=$2 ; shift ;;
        --go-tag) go_tag=$2 ; shift ;;
        version) show_version=1 ;;
        --) shift; break ;;
        *) echo "Unknown option $1" ; exit 2 ;;
    esac
    shift
done

DOCKER_SCAN_SUGGEST=false \
    docker build --quiet --build-arg GOLANG_VERSION=$golang_version -t goffline $(dirname $0) >/dev/null

if [[ $show_version ]]; then
    exec docker run --rm goffline go env GOVERSION
else
    echo -e "\n\033[1;34m🍻 Download Go modules\033[0m"
    mkdir -p "$dest_dir"
    exec docker run --init -e TINI_KILL_PROCESS_GROUP=1 --rm -i \
        -v $dest_dir:/dl \
        -v $(realpath "$config"):/config.txt:ro \
        -e GOFFLINE_VERSION=$goffline_version \
        -w /dl \
        goffline /goget.py -f /config.txt -c xz -o /dl "$@"
fi