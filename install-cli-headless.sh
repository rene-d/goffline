#!/usr/bin/env bash

set -euo pipefail

scp()
{
    $(which scp) -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $@
}

ssh()
{
    $(which ssh) -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $@
}


target=${1:?Missing ssh target}

. vscode-$(cat vscode-version)/version

if [ $channel = stable ] ; then
    Channel=Stable
else
    echo 2> "Unknown channel: $channel"
    exit 2
fi

arch=$(ssh $target uname -m)
if [ $arch = aarch64 ] ; then
    arch=linux-arm64
elif [ $arch = x86_64 ] ; then
    arch=linux-x64
else
    echo 2> "Unknown arch: $arch"
    exit 2
fi

echo "Visual Studio Code $version cli and headless server (commit $commit, $arch/$channel)"

echo "Installing cli and headless server"
scp vscode-$version/vscode_cli_${arch/-/_}_cli.tar.gz $target:
scp vscode-$version/vscode-server-$arch.tar.gz $target:

cat <<EOF | ssh $target sh
set -e
mkdir -p .vscode-server/cli/servers/$Channel-$commit/server
mkdir -p .vscode-server/bin
tar -C .vscode-server --transform='s|code|code-$commit|' --no-same-owner -xf vscode_cli_${arch/-/_}_cli.tar.gz
tar -C .vscode-server/cli/servers/$Channel-$commit/server --strip-components=1 --no-same-owner -xf vscode-server-$arch.tar.gz
ln -rsnf .vscode-server/cli/servers/$Channel-$commit/server .vscode-server/bin/$commit
rm vscode_cli_${arch/-/_}_cli.tar.gz vscode-server-$arch.tar.gz
EOF

extensions=(
    MS-CEINTL.vscode-language-pack-fr
    ms-vscode.cpptools-$arch
    ms-vscode.cpptools-themes
    twxs.cmake
    waderyan.gitblame
    DavidAnson.vscode-markdownlint
    bierner.markdown-mermaid
    cschlosser.doxdocgen
    DotJoshJohnson.xml
    goessner.mdmath
)
# eamodio.gitlens

for ext in ${extensions[@]}
do
    echo "Installing extension $ext"
    scp vscode-extensions-$version/${ext}-*.vsix $target:$ext.vsix
    ssh $target .vscode-server/bin/$commit/bin/code-server --telemetry-level off --log warn --install-extension $ext.vsix
    ssh $target rm $ext.vsix
done
