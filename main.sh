#!/usr/bin/env bash

if [[ ! -f /.dockerenv ]]; then
    echo >&2 "Should be run into the container"
    exit 2
fi

set -u

compression=J

dl_111module()
{
    local name=$1
    local mode=$2
    shift 2

    echo -e "Processing \033[1;33m${name}\033[0m set in mode \033[1;33m${mode}\033[0m with:"
    for i; do echo "  $i"; done

    unset GOROOT
    export GOPATH="/tmp/cache/${name}-111GOPATH"
    export GO111MODULE=${mode}

    # get the modules twice
    for i; do
        env GOARCH=arm64 go get $i
        env GOARCH=amd64 go get $i
    done

    echo "Fixing bin dir with host arch"
    bin_arch=${GOPATH}/bin/$(go env GOHOSTOS)_$(go env GOHOSTARCH)
    rm -rf ${bin_arch}
    mkdir -p ${bin_arch}
    find ${GOPATH}/bin -maxdepth 1 -type f | xargs -i+ mv -f + ${bin_arch}

    echo "Make archive"
    tar -C "${GOPATH}" -c${compression}f /tmp/go-modules.tar .

    local filename="$(go version | sed -nr 's/^.* (go[0-9\.]+) .*$/\1/p')-${name}.sh"

    echo -e "Write self-extracting script \033[1;31m${filename}\033[0m"

    # as we have downloaded the both architectures, the extract script should deal with that
    cat <<EOF > "${DESTDIR}/go/${filename}"
#!/bin/sh
if [ "\$1" = "-m" ]; then
    echo $*
    exit
elif [ "\$1" = "-t" ]; then
    fn()
    {
        tar -t${compression}
    }
elif [ "\$1" = "-x" ]; then
    fn()
    {
        cat
    }
elif [ -n "\$1" ]; then
    echo "Usage: \$0 [option]"
    echo "  -x   extract to stdin"
    echo "  -t   list content"
    echo "  -m   print modules list"
    exit
else
    fn()
    {
        arch=\$(go env GOHOSTARCH)
        if [ \${arch} = amd64 ]; then exclude=arm64; else exclude=amd64; fi
        tar -C \$(go env GOROOT) \
            -x${compression} \
            --no-same-owner \
            --transform="s,bin/linux_\${arch},bin," \
            --exclude="bin/linux_\${exclude}*"
    }
fi
base64 -d <<'#EOF#' | fn
EOF

    base64 /tmp/go-modules.tar >> "${DESTDIR}/go/${filename}"
    echo '#EOF#' >> "${DESTDIR}/go/${filename}"
    chmod a+x "${DESTDIR}/go/${filename}"

    echo "Done"
    echo
}

get_latest_release()
{
    local repo=$1
    local asset=$2
    local url

    url=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" |
          jq -r '.assets | map(select(.name | contains("'${asset}'")).browser_download_url)[]')

    echo -e "tool: \033[1;36m$(basename ${url})\033[0m"
    wget -nv -nc -P "${DESTDIR}/go" ${url}
}

tools()
{
    echo "Downloading tools"

    # # https://github.com/golangci/golangci-lint/releases
    # get_latest_release golangci/golangci-lint -linux-amd64.tar.gz
    # get_latest_release golangci/golangci-lint -linux-arm64.tar.gz

    # https://github.com/gotestyourself/gotestsum
    get_latest_release gotestyourself/gotestsum _linux_amd64.tar.gz
    get_latest_release gotestyourself/gotestsum _linux_arm64.tar.gz
}

filter_important()
{
    local m
    while read line; do
        if [[ $line =~ "importPath: '" ]] ; then m=$line ; fi
        if [[ $line =~ "isImportant: true" ]]; then echo $m; fi
    done
}

mkdir -p ${DESTDIR}/go

for i; do
    case "$i" in
        -j|--bzip2) compression=j ; shift ;;
        -z|--gzip) compression=z ; shift ;;
        --no) compression= ; shift ;;
        test)
            dl_111module test1 on github.com/godoctor/godoctor
            dl_111module test2 auto github.com/julienschmidt/httprouter
            ;;
        pkgs)
            # our Go modules list
            packages=($(grep -v "^#" /go-modules.txt))
            dl_111module pkgs auto ${packages[*]}
            ;;
        vscode)
            # fetch the list of tools into the the source code of the extension
            vscode=($(curl -sL https://raw.githubusercontent.com/golang/vscode-go/master/src/goTools.ts | \
                      sed "s/^.*importPath: '\(.*\)',.*$/\1/p;d"))
            dl_111module vscode on ${vscode[*]}
            ;;
        vscode-light)
            # fetch the list of tools into the the source code of the extension
            vscode=($(curl -sL https://raw.githubusercontent.com/golang/vscode-go/master/src/goTools.ts | \
                      filter_important | \
                      sed "s/^.*importPath: '\(.*\)',.*$/\1/p;d"))
            dl_111module vscode-light on ${vscode[*]}
            ;;
        tools)
            tools
            ;;
        *) echo "Unknown operation: $1" ;;
    esac
done
