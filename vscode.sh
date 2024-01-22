#!/usr/bin/env bash
# Download Visual Studio Code client and server, and a list of extensions

set -Eeuo pipefail

dest_dir=$PWD/dl
config_file=${1:-config.txt}
opt_local=
opt_gotag=

while [[ ${1-} ]]; do
    case $1 in
        -d|--dest-dir) dest_dir=$(cd $2; pwd) ; shift ;;
        -c|--config) config_file=$2 ; shift ;;
        -l|--local) opt_local=1 ;;
        --go-tag) opt_gotag=$2 ; shift ;;
        *) echo "Unknown option $1" ; exit 2 ;;
    esac
    shift
done

###############################################################################
echo -e "\n\033[1;34m🍻 Downloading VSCode\033[0m"
$(dirname $0)/vscode-app.py --dest-dir ${dest_dir}

###############################################################################
echo -e "\n\033[1;34m🍻 Downloading extenions\033[0m"
if [[ $opt_local ]]; then
    $(dirname $0)/vscode-ext.py --dest-dir ${dest_dir} --local
else
    $(dirname $0)/vscode-ext.py --dest-dir ${dest_dir} --config $config_file
fi

###############################################################################
if [[ ! $opt_local ]]; then
    echo -e "\n\033[1;34m🍻 Packaging extenions and vscode-server\033[0m"
    $(dirname $0)/vscode-dist.py --dest-dir ${dest_dir} --config $config_file
fi

###############################################################################
if [[ $opt_gotag ]]; then
    echo -e "\n\033[1;34m🍻 Download Go extension tools\033[0m"
    $(dirname $0)/golang.sh --dest-dir ${dest_dir} -- --name vscode --tag $opt_gotag --vscode
fi
