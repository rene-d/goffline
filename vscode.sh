#!/usr/bin/env bash
# Download Visual Studio Code client and server, and a list of extensions

set -e

DESTDIR="${DESTDIR:-.}"

if [[ ! -f /.dockerenv ]]; then

    list=
    if [[ -f $1 ]]; then
        list="-v $(realpath "$1"):/config.txt:ro"
        shift
    fi

    "$(dirname "${BASH_SOURCE[0]}")/golang.sh" build_only
    exec docker run --rm -ti -v "$PWD/dl:/dl" ${list} -w / ${list} go-pkgs-dl /vscode.sh
fi

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
echo "channel=${channel}" > "${DESTDIR}/vscode-${version}/version"
echo "version=${version}" >> "${DESTDIR}/vscode-${version}/version"
echo "commit=${commit}" >> "${DESTDIR}/vscode-${version}/version"

# download windows, linux and vscode-server x86_64 et aarch64
wget -nv -nc -P "${DESTDIR}/vscode-${version}" "${link}"
wget -nv -nc -P "${DESTDIR}/vscode-${version}" $(get_link "https://code.visualstudio.com/sha/download?build=${channel}&os=linux-x64")
wget -nv -nc -P "${DESTDIR}/vscode-${version}" $(get_link "https://update.code.visualstudio.com/commit:${commit}/server-linux-x64/${channel}")
wget -nv -nc -P "${DESTDIR}/vscode-${version}" $(get_link "https://update.code.visualstudio.com/commit:${commit}/server-linux-arm64/${channel}")


filter_vscode_config()
{
    awk '{ if ($1 ~ /^#/) next; if ($1 ~ /^\[/) section=$1; else if ($1 !~ /^$/) if (section ~ /^\[vscode.*\]$/) print $1  }'
}

# download the extensions
extensions=($(cat config.txt | filter_vscode_config | sort -u))

# open question: how to find the engine version ?
# guess: vscode uses its version number (for example 1.55.2)
for i in "${extensions[@]}"; do
    echo
    ./ext.sh "$i" "${version}"
done
echo
