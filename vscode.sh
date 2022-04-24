#!/usr/bin/env bash
# Download Visual Studio Code client and server, and a list of extensions

set -Eeuo pipefail

DESTDIR=./dl
CONFIG=${1:-config.txt}

if [ ! -f "$CONFIG" ]; then
    echo "Usage: $0 <config>"
    exit 1
fi

# DESTDIR="${DESTDIR:-.}"
# if [[ ! -f /.dockerenv ]]; then
#     list=
#     if [[ -f "${1:-}" ]]; then
#         list="-v $(realpath "$1"):/config.txt:ro"
#         shift
#     fi
#     "$(dirname "${BASH_SOURCE[0]}")/golang.sh" build_only
#     exec docker run --init -e TINI_KILL_PROCESS_GROUP=1 --rm -ti -v "$PWD/dl:/dl" ${list} -w / ${list} goffline /vscode.sh
# fi

###############################################################################
echo -e "\n\033[1;34m🍻 Downloading VSCode\033[0m"

# channel=insider
channel=stable

get_link()
{
    local link=$(curl -s "$1")
    link=${link/Found. Redirecting to /}
    echo "$link"
}

echo -e "Visual Studio Code: \033[1;33m${channel}\033[0m"

# fetch Windows version download link
link=$(get_link "https://code.visualstudio.com/sha/download?build=${channel}&os=win32-x64-archive")

# extract the commit and the version from the windows download link
commit=$(echo "${link}" | sed  -r 's/.*\/([0-9a-f]{40})\/.*/\1/')
version=$(echo "${link}" | sed  -r 's/.*\-([0-9\.]+(\-insider)?)\.zip$/\1/')

echo -e "Found version: \033[1;32m${version}\033[0m"
echo -e "Found commit: \033[1;32m${commit}\033[0m"

mkdir -p "${DESTDIR}/vscode-${version}"

# save the commit id
echo "${version}" > "${DESTDIR}/vscode-version"
echo "version=${version}" > "${DESTDIR}/vscode-${version}/version"
echo "commit=${commit}" >> "${DESTDIR}/vscode-${version}/version"
echo "channel=${channel}" >> "${DESTDIR}/vscode-${version}/version"

# download windows, linux and vscode-server for x86_64 and aarch64 architectures
set +e
wget -nv -nc -P "${DESTDIR}/vscode-${version}" "${link}"
wget -nv -nc -O "${DESTDIR}/vscode-${version}/code-linux-x64-${version}.tar.gz" $(get_link "https://code.visualstudio.com/sha/download?build=${channel}&os=linux-x64")
wget -nv -nc -P "${DESTDIR}/vscode-${version}" $(get_link "https://update.code.visualstudio.com/commit:${commit}/server-linux-x64/${channel}")
wget -nv -nc -P "${DESTDIR}/vscode-${version}" $(get_link "https://update.code.visualstudio.com/commit:${commit}/server-linux-arm64/${channel}")
set -e


###############################################################################
echo -e "\n\033[1;34m🍻 Downloading extenions\033[0m"
$(dirname $0)/vscodeext.py -e ${version} -o ${DESTDIR}/vscode-extensions-${version} -f $CONFIG


###############################################################################
echo -e "\n\033[1;34m🍻 Packaging extenions and vscode-server\033[0m"
$(dirname $0)/vscodedist.py -d ${DESTDIR} -f $CONFIG
