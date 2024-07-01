#!/usr/bin/env bash

set -euo pipefail

. vscode-$(cat vscode-version)/version

if [ $channel = stable ] ; then
    Channel=Stable
else
    echo 2> "Unknown channel: $channel"
    exit 2
fi

arch=$(uname -m)
if [ $arch = aarch64 ] ; then
    arch=linux-arm64
elif [ $arch = x86_64 ] ; then
    arch=linux-x64
    arch_deb=amd64
else
    echo 2> "Unknown arch: $arch"
    exit 2
fi

echo "Visual Studio Code $version (commit $commit, $arch/$channel)"

# installation de vscode dans l'host
echo "Installing"
sudo dpkg -i vscode-$version/code_$version-*_${arch_deb}.deb
sudo rm -f /etc/apt/sources.list.d/vscode.list

mapfile -n3 -t a < <(/usr/bin/code --version)
if [[ ${a[0]} != $version ]] || [[ ${a[1]} != $commit ]] ; then
    echo "A problem occured... check the script"
    exit 2
fi

extensions=(
    MS-CEINTL.vscode-language-pack-fr
    ms-vscode.cpptools-$arch
    ms-vscode.cpptools-themes
    twxs.cmake
    eamodio.gitlens
    waderyan.gitblame
    DavidAnson.vscode-markdownlint
    bierner.markdown-mermaid
    cschlosser.doxdocgen
    DotJoshJohnson.xml
    goessner.mdmath

    ms-vscode.remote-explorer
    ms-vscode-remote.remote-containers
    ms-vscode-remote.remote-ssh
    ms-vscode-remote.remote-ssh-edit

    ms-azuretools.vscode-docker

    redhat.vscode-xml-$arch
    DotJoshJohnson.xml
    cschlosser.doxdocgen

    ms-python.black-formatter
    ms-python.debugpy-$arch
    ms-python.isort
    ms-python.python
    ms-python.vscode-pylance
    ms-toolsai.jupyter-keymap
    ms-toolsai.jupyter-$arch
    ms-toolsai.jupyter-renderers
    ms-toolsai.vscode-jupyter-cell-tags
    ms-toolsai.vscode-jupyter-slideshow
)

for ext in ${extensions[@]}
do
    echo "Installing extension $ext"
    ext=$(find vscode-extensions-$version -name "${ext}-*.vsix")
    /usr/bin/code --log warn --install-extension $ext
done
