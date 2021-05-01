#!/usr/bin/env bash

DESTDIR=${DESTDIR:-.}

if [[ ! -f /.dockerenv ]]; then
    $(dirname $BASH_SOURCE)/golang.sh build_only
    exec docker run --rm -ti -v $PWD/dl:/dl ${list} -w / go-pkgs-dl /vscode.sh $*
fi

# channel=insider
channel=stable

get_link()
{
    local link=$(curl -s "$1")
    link=${link/Found. Redirecting to /}
    echo $link
}

echo -e "Visual Studio Code: \033[1;33m${channel}\033[0m"

# fetch Windows version download link
link=$(get_link "https://code.visualstudio.com/sha/download?build=${channel}&os=win32-x64-archive")

# extract the commit and the version from the windows download link
commit=$(echo $link  | sed  -r 's/.*\/([0-9a-f]{40})\/.*/\1/')
version=$(echo $link  | sed  -r 's/.*\-([0-9\.]+(\-insider)?)\.zip$/\1/')

echo -e "Found version: \033[1;32m${version}\033[0m"
echo -e "Found commit: \033[1;32m${commit}\033[0m"

mkdir -p ${DESTDIR}/vscode-${version}

# save the commit id
echo "channel=${channel}" > ${DESTDIR}/vscode-${version}/version
echo "version=${version}" >> ${DESTDIR}/vscode-${version}/version
echo "commit=${commit}" >> ${DESTDIR}/vscode-${version}/version

# download windows, linux and vscode-server x86_64 et aarch64
wget -nv -nc -P ${DESTDIR}/vscode-${version} $link
wget -nv -nc -P ${DESTDIR}/vscode-${version} $(get_link "https://code.visualstudio.com/sha/download?build=${channel}&os=linux-x64")
wget -nv -nc -P ${DESTDIR}/vscode-${version} $(get_link "https://update.code.visualstudio.com/commit:${commit}/server-linux-x64/${channel}")
wget -nv -nc -P ${DESTDIR}/vscode-${version} $(get_link "https://update.code.visualstudio.com/commit:${commit}/server-linux-arm64/${channel}")


# download the extensions

extensions=(
    ms-python.python
    ms-python.vscode-pylance
    ms-toolsai.jupyter
    ms-vscode.cpptools
    golang.go
    ms-vscode-remote.remote-containers
    ms-vscode-remote.remote-ssh
    ms-vscode-remote.remote-ssh-edit
    ms-azuretools.vscode-docker
    ms-vscode.cmake-tools
    DavidAnson.vscode-markdownlint
    goessner.mdmath
    James-Yu.latex-workshop
    waderyan.gitblame
    twxs.cmake
    redhat.vscode-yaml
    zxh404.vscode-proto3
    cschlosser.doxdocgen
    alexkrechik.cucumberautocomplete
    secanis.jenkinsfile-support
    janjoerke.jenkins-pipeline-linter-connector
    rebornix.ruby
    wingrunr21.vscode-ruby
)

# open question: how to find the engine version ?
# guess: vscode uses its version number (for example 1.55.2)

for i in "${extensions[@]}"; do
    echo
    ./ext.sh $i ${version}
done
