#!/usr/bin/env bash
# Make archive of Go downloaded Go modules.

if [[ ! -f /.dockerenv ]] || [[ ! ${GOLANG_VERSION} ]]; then
    echo >&2 "Should be run into the container"
    exit 2
fi

set -ue

compression=J

now="$(date +%s)"
tag_date="$(date --date=@"${now}" +%Y%m%d%H%M%S)"
tag_date_iso8601="$(date --date=@"${now}" --iso-8601=seconds)"

dl_111module()
{
    local name="$1"
    local mode="$2"
    shift 2

    # special mode "bin" archives only binaries
    local arch_dirs=.
    if [[ ${mode} == bin ]]; then
        mode=on
        arch_dirs=bin
    fi

    echo -e "Processing \033[1;33m${name}\033[0m set in mode \033[1;33m${mode}\033[0m with:"
    for i; do echo "  $i"; done

    # the basename contains Go version and date, except for the unit tests
    if [[ ${name} =~ ^test[1-9]$ ]]; then
        basename="${name}"
    else
        basename="${name}-$(go version | sed -nr 's/^.* (go[0-9\.]+) .*$/\1/p')-${tag_date}"
    fi

    unset GOROOT
    export GOPATH="/tmp/cache/${name}-111GOPATH"
    export GO111MODULE="${mode}"

    mkdir -p "${DESTDIR}/logs/"
    rm -f "${DESTDIR}/logs/${basename}.log"

    # get the modules twice (everything goes under $GOPATH)
    env GOARCH=arm64 go get $* |& tee -a "${DESTDIR}/logs/${basename}.log"
    env GOARCH=amd64 go get $* |& tee -a "${DESTDIR}/logs/${basename}.log"

    # permissions for all
    chmod -R a+rX "${GOPATH}"

    # by default,
    # host arch binaries are into $GOPATH/bin/
    # other arch binaries are into $GOPATH/bin/linux_<arch>/
    echo "Fixing bin dir with host arch"
    bin_arch="${GOPATH}/bin/$(go env GOHOSTOS)_$(go env GOHOSTARCH)"
    rm -rf "${bin_arch}"
    mkdir -p "${bin_arch}"
    find "${GOPATH}/bin" -maxdepth 1 -type f | xargs -i+ mv -f + "${bin_arch}"

    # Retrieve the list of modules/version
    local mods
    if [[ ${mode} != on ]]; then
        mods=($*)
    else
        mods=($(cd ${GOPATH}/pkg/mod/cache/download && find . -name '*.zip' | cut -d/ -f2- | sed -r 's,/@v/(.*)\.zip$,@\1,' | sed -e 's/!\([a-z]\)/\u\1/' ))
    fi
    for i in ${mods[*]}; do
        echo "$i" | sed 's/@/ /' >> "${GOPATH}/gomods.txt"
    done

    echo "Module list: ${mods[@]}"

    echo "Making archive"
    tar -C "${GOPATH}" -c${compression}f /tmp/go-modules.tar "${arch_dirs}"

    local sha256="$(sha256sum -b < /tmp/go-modules.tar | cut -f1 -d' ')"

    local filename="${basename}.sh"

    echo -e "Writing self-extracting script \033[1;31m${filename}\033[0m"

    # as we have downloaded the both architectures, the extract script should deal with that
    cat <<EOF > "${DESTDIR}/go/${filename}"
#!/bin/sh
if [ "\$1" = "-m" ]; then
    for i in ${mods[*]}
    do echo "\$i"; done
    exit
elif [ "\$1" = "-i" ]; then
    echo "${tag_date_iso8601}"
    echo "${sha256}"
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
    echo "  -i   print download date and SHA-256 of the *embedded* archive"
    echo "  -m   print modules list"s
    exit
else
    fn()
    {
        arch=\$(go env GOHOSTARCH)
        if [ \${arch} = amd64 ]; then exclude=arm64; else exclude=amd64; fi
        tar -C \$(go env GOPATH) \\
            -x${compression} \\
            --no-same-owner \\
            --transform="s,bin/linux_\${arch},bin," \\
            --exclude="bin/linux_\${exclude}*"
    }
fi
base64 -d <<'#EOF#' | fn
EOF

    base64 /tmp/go-modules.tar >> "${DESTDIR}/go/${filename}"
    echo '#EOF#' >> "${DESTDIR}/go/${filename}"
    chmod a+x "${DESTDIR}/go/${filename}"

    cd "${DESTDIR}/go"
    sha256sum -b "${filename}" > "${filename}.sha256"

    echo "# GO111MODULE=${mode}" > "${basename}.list"
    echo "# Size: $(stat --format %s ""${filename}"")" >> "${basename}.list"
    echo "# SHA-256: ${sha256}" >> "${basename}.list"
    for i in "$@"; do echo "$i"; done >> "${basename}.list"

    echo "Done"
    echo
}

get_latest_release()
{
    local repo="$1"
    local asset="$2"
    local url

    url=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" |
          jq -r '.assets | map(select(.name | contains("'${asset}'")).browser_download_url)[]')

    echo -e "tool: \033[1;36m$(basename ${url})\033[0m"
    wget -nv -nc -P "${DESTDIR}/go" "${url}"
}

tools()
{
    echo "Downloading tools"

    # # https://github.com/golangci/golangci-lint/releases
    get_latest_release golangci/golangci-lint -linux-amd64.tar.gz
    get_latest_release golangci/golangci-lint -linux-arm64.tar.gz

    # https://github.com/gotestyourself/gotestsum
    get_latest_release gotestyourself/gotestsum _linux_amd64.tar.gz
    get_latest_release gotestyourself/gotestsum _linux_arm64.tar.gz
}

filter_important()
{
    local m=
    while read line; do
        if [[ $line =~ "importPath: '" ]] ; then
            if [[ $m ]]; then echo "$m"; fi
            m=$(echo "$line" | cut -d\' -f2)
        fi
        if [[ $line =~ "replacedByGopls: true" ]]; then echo >&2 "  skip $m (replaced by gopls)"; m=; fi
        if [[ $line =~ "isImportant: false" ]] && [[ $m ]]; then echo >&2 "  skip $m (non important)"; m=; fi
    done
    if [[ $m ]]; then echo "$m"; fi
}

parse_go_config()
{
    local section=
    if [[ $1 ]]; then
        section="$1"
    fi
    awk '{ if ($1 ~ /^#/) next; if ($1 ~ /^\[/) section=$1; else if ($1 !~ /^$/) if (section=="[go]" || section=="['${section}']" ) print $1  }'
}

mkdir -p "${DESTDIR}/go"

for i; do
    case "$i" in
        -j|--bzip2) compression=j ; shift ;;
        -z|--gzip) compression=z ; shift ;;
        --no) compression= ; shift ;;
        test)
            dl_111module test1 bin golang.org/x/example/hello
            dl_111module test2 auto rsc.io/sampler
            dl_111module test3 on rsc.io/quote@v1.5.2
            ;;
        pkgs)
            # download in GOPATH mode
            packages=($(cat /config.txt | parse_go_config gopackages | cut -d@ -f1))
            dl_111module pkgs auto ${packages[*]}
            ;;
        mods)
            # download in the new Go modules mode
            packages=($(cat /config.txt | parse_go_config gomodules))
            dl_111module mods on ${packages[*]}
            ;;
        vscode-full)
            # fetch the list of tools into the the source code of the extension
            vscode=($(curl -sL https://raw.githubusercontent.com/golang/vscode-go/master/src/goTools.ts | \
                      sed "s/^.*importPath: '\(.*\)',.*$/\1/p;d"))
            dl_111module vscode-full on ${vscode[*]}
            ;;
        vscode)
            # fetch the list of tools into the the source code of the extension
            # retains only important extensions and those not replaced by the language server (gopls)
            vscode=($(curl -sL https://raw.githubusercontent.com/golang/vscode-go/master/src/goTools.ts | \
                      filter_important))
            dl_111module vscode on ${vscode[*]}
            ;;
        vscode-bin)
            # fetch the list of tools into the the source code of the extension
            # retains only important extensions and those not replaced by the language server (gopls)
            vscode=($(curl -sL https://raw.githubusercontent.com/golang/vscode-go/master/src/goTools.ts | \
                      filter_important))
            dl_111module vscode-bin bin ${vscode[*]}
            ;;
        tools)
            tools
            ;;
        *) echo "Unknown operation: $1" ;;
    esac
done
