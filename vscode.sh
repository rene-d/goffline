#!/usr/bin/env bash
# Download Visual Studio Code client and server, and a list of extensions

set -Eeuo pipefail

dest_dir=$PWD/dl
config=${1:-config.txt}
go_tag=

while [[ ${1-} ]]; do
    case $1 in
        -d|--dest-dir) dest_dir=$(cd $2; pwd) ; shift ;;
        -c|--config) config=$2 ; shift ;;
        --go-tag) go_tag=$2 ; shift ;;
        *) echo "Unknown option $1" ; exit 2 ;;
    esac
    shift
done

###############################################################################
echo -e "\n\033[1;34m🍻 Downloading VSCode\033[0m"
$(dirname $0)/vscode-app.py --dest-dir ${dest_dir}

###############################################################################
echo -e "\n\033[1;34m🍻 Downloading extenions\033[0m"
$(dirname $0)/vscode-ext.py --dest-dir ${dest_dir} --config $config

###############################################################################
echo -e "\n\033[1;34m🍻 Packaging extenions and vscode-server\033[0m"
$(dirname $0)/vscode-dist.py --dest-dir ${dest_dir} --config $config

###############################################################################
if [[ $go_tag ]]; then
    echo -e "\n\033[1;34m🍻 Download Go extension tools\033[0m"
    $(dirname $0)/golang.sh --dest-dir ${dest_dir} -- --name vscode --tag $go_tag --vscode
fi
