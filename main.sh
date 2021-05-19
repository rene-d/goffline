#!/usr/bin/env bash
# Make archive of Go downloaded Go modules.

if [[ ! -f /.dockerenv ]] || [[ ! ${GOLANG_VERSION} ]]; then
    echo >&2 "Should be run into the container"
    exit 2
fi

set -ue

GOFFLINE_VERSION=${GOFFLINE_VERSION:=dev}

compression=J

now="$(date +%s)"
tag_date="$(date --date=@"${now}" +%Y%m%d%H%M%S)"
tag_date_iso8601="$(date --date=@"${now}" --iso-8601=seconds)"
test_count=0


dl_111module()
{
    local name="$1"
    local mode="$2"  # possible values: on bin
    shift 2

    echo -e "Processing \033[1;33m${name}\033[0m set in mode \033[1;33m${mode}\033[0m with:"
    for i; do echo "  $i"; done

    # the basename contains Go version and date, except for the unit tests
    if [[ ${name} =~ ^test[1-9]$ ]]; then
        basename="${name}"
        test_count=$((test_count + 1))
        local tag_date="${tag_date}.${test_count}"
    else
        basename="${name}-$(go version | sed -nr 's/^.* (go[0-9\.]+) .*$/\1/p')-${tag_date}"
    fi

    export GOPATH="/tmp/cache/gopath"
    go env -w GO111MODULE=on

    # get the modules twice (everything goes under $GOPATH)
    case ${mode} in
        bin)
            # all modules in one command
            env GOARCH=arm64 go get $*
            env GOARCH=amd64 go get $*
            ;;
        on)
            # all modules in one command with dependencies for building tests
            env GOARCH=arm64 go get -t $*
            env GOARCH=amd64 go get -t $*
            ;;
        *)
            exit 2
            ;;
    esac

    # permissions for all
    chmod -R a+rX "${GOPATH}"

    # by default:
    # - host arch binaries are into $GOPATH/bin/
    # - foreign arch binaries are into $GOPATH/bin/linux_<arch>/
    echo "Fixing bin dir with host arch"
    bin_arch="${GOPATH}/bin/$(go env GOHOSTOS)_$(go env GOHOSTARCH)"
    rm -rf "${bin_arch}"
    mkdir -p "${bin_arch}"
    find "${GOPATH}/bin" -maxdepth 1 -type f | xargs -I+ mv -f + "${bin_arch}"

    # Retrieve the list of modules/version
    local mods
    mods=($(cd ${GOPATH}/pkg/mod/cache/download && find . -name '*.zip' | cut -d/ -f2- | sed -r 's,/@v/(.*)\.zip$,@\1,' | sed -e 's/!\([a-z]\)/\u\1/' | sort ))
    echo "Module list: ${mods[@]}"

    # save the module list info a text file
    echo "# tag: ${tag_date}" > "${GOPATH}/gomods.txt.${tag_date}"
    echo "# date: ${tag_date_iso8601}" >> "${GOPATH}/gomods.txt.${tag_date}"
    echo "# goffline: ${GOFFLINE_VERSION}" >> "${GOPATH}/gomods.txt.${tag_date}"
    echo >> "${GOPATH}/gomods.txt.${tag_date}"
    for i in ${mods[*]}; do
        echo "$i" | sed 's/@/ /' >> "${GOPATH}/gomods.txt.${tag_date}"
    done
    chmod 444 "${GOPATH}/gomods.txt.${tag_date}"

    echo "Making archive"
    if [[ ${mode} == bin ]]; then
        tar -C "${GOPATH}" -c${compression}f /tmp/go-modules.tar bin
    else
        tar -C "${GOPATH}" -c${compression}f /tmp/go-modules.tar $(ls ${GOPATH})
    fi

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
    echo "version: $(go version)"
    echo "tag: ${tag_date}"
    echo "date: ${tag_date_iso8601}"
    echo "goffline: ${GOFFLINE_VERSION}"
    exit
elif [ "\$1" = "-t" ]; then
    fn()
    {
        tar -t${compression}
    }
elif [ "\$1" = "-tv" ]; then
    fn()
    {
        tar -tv${compression}
    }
elif [ "\$1" = "-x" ]; then
    fn()
    {
        cat
    }
elif [ -n "\$1" ]; then
    echo "Usage: \$0 [option]"
    echo "  -x     extract to stdin"
    echo "  -t[v]  list content"
    echo "  -i     display information"
    echo "  -m     print modules list"s
    exit
else
    fn()
    {
        local ver=\$(go version | sed -nr 's/^.*go([0-9.]+) .*/\1/p')
        if [ "\${ver}" != "${GOLANG_VERSION}" ]; then
            echo >&2 "Go version mismatch"
            echo >&2 "Found:    \${ver}"
            echo >&2 "Expected: ${GOLANG_VERSION}"
            exit 2
        fi
        local arch=\$(go env GOHOSTARCH)
        if [ \${arch} = amd64 ]; then exclude=arm64; else exclude=amd64; fi
        tar -C \$(go env GOPATH) \\
            -x${compression} \\
            --no-same-owner \\
            --transform="s,bin/linux_\${arch},bin," \\
            --exclude="bin/linux_\${exclude}*"
        if [ ${mode} != bin ]; then
            cd \$(go env GOPATH)
            cat gomods.txt.* | sort | grep -v "^# [dg]" > gomods.txt
            chmod 444 gomods.txt
        fi
    }
fi
base64 -d <<'#EOF#' | fn
EOF

    # append the archive encoded in Base64
    base64 /tmp/go-modules.tar >> "${DESTDIR}/go/${filename}"
    echo '#EOF#' >> "${DESTDIR}/go/${filename}"
    chmod a+x "${DESTDIR}/go/${filename}"

    # add checksum file
    cd "${DESTDIR}/go"
    sha256sum -b "${filename}" > "${filename}.sha256"

    rm -rf "${GOPATH}"

    # we're done
    echo "Done"
    echo
}

get_latest_release()
{
    local repo="$1"
    local asset="$2"
    local url
    url=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" |
          jq -r '.assets | map(select(.name | match("'${asset}'")).browser_download_url)[]' | head -n1)

    echo -e "tool: \033[1;36m$(basename ${url})\033[0m"
    wget -nv -nc -P "${DESTDIR}/go" "${url}"
}

dl_assets()
{
    echo "Downloading tools"
    for i; do
        echo "look for assets of $i"
        get_latest_release $i linux.amd64.tar.gz
        get_latest_release $i linux.arm64.tar.gz
    done
}

filter_all()
{
    sed "s/^.*importPath: '\(.*\)',.*$/\1/p;d"
}

filter_gopls()
{
    local m=
    while read line; do
        if [[ $line =~ "importPath: '" ]] ; then
            if [[ $m ]]; then echo "$m"; fi
            m=$(echo "$line" | cut -d\' -f2)
        fi
        if [[ $line =~ "replacedByGopls: true" ]]; then echo >&2 "  skip $m (replaced by gopls)"; m=; fi
        # if [[ $line =~ "isImportant: false" ]] && [[ $m ]]; then echo >&2 "  skip $m (non important)"; m=; fi
    done
    if [[ $m ]]; then echo "$m"; fi
}

adapt_version()
{
    # golangci-lint v1.40+ requires Go 1.15
    if [[ $(go version) =~ go1.14. ]]; then
        sed -r 's?(github.com/golangci/golangci-lint.*\b)?\1@v1.39.0?'
    else
        cat
    fi
}

parse_go_config()
{
    local prefix="$1"
    awk '
{
    if ($1 ~ /^#/ || $1 ~ /^$/) next;
    if ($1 ~ /^\[/)
        section=$1;
    else if (section == "['${prefix}']" || section ~ /\['${prefix}':.*\]/) {
        if ($2 ~ /^v[0-9].*/)
            print $1 "@" $2
        else
            print $1
    }
}'
}

semver_lte()
{
    printf '%s\n%s' "$1" "$2" | sort -C -V
}

# get tool list from https://github.com/golang/vscode-go
vscode_gotools()
{
    local tag=$(curl -sL https://api.github.com/repos/golang/vscode-go/releases/latest | jq -r ".tag_name")
    if [[ ! ${tag} ]]; then
        exit 2
    fi

    # tools information has been moved in v0.26.0
    if semver_lte "${tag}" "v0.26.0"; then
        curl -sL "https://raw.githubusercontent.com/golang/vscode-go/${tag}/src/goTools.ts"
    else
        curl -sL "https://raw.githubusercontent.com/golang/vscode-go/${tag}/src/goToolsInformation.ts"
    fi
}

main()
{
    mkdir -p "${DESTDIR}/go"

    for i; do

        case "$i" in
            -j|--bzip2) compression=j ; shift ;;
            -z|--gzip) compression=z ; shift ;;
            --no) compression= ; shift ;;

            test)
                rm -f "${DESTDIR}"/go/dl/go/test[1-9].*

                compression=J dl_111module test1 bin golang.org/x/example/hello
                compression=z dl_111module test2 on rsc.io/quote@v1.5.2
                compression=j dl_111module test3 on golang.org/x/text@v0.3.3 golang.org/x/example@v0.0.0-20210407023211-09c3a5e06b5d
                # nota: golang.org/x/text@v0.3.3 is mysteriously required when golang.org/x/example and rsc.io are both required
                ;;

            mods)
                # download Go module
                local list=($(cat /config.txt | parse_go_config go))
                dl_111module $i on ${list[*]}
                ;;

            vscode*)
                local filter
                local mode
                local vscode

                if [[ $i =~ -full ]]; then
                    filter=filter_all
                else
                    filter=filter_gopls
                fi
                if [[ $i =~ -bin ]]; then
                    mode=bin
                else
                    mode=on
                fi

                # fetch the list of tools into the the source code of the extension
                vscode=($(vscode_gotools | $filter | sort -u | adapt_version))
                dl_111module $i ${mode} ${vscode[*]}
                ;;

            tools)
                local list=($(cat /config.txt | parse_go_config gotools))
                dl_assets ${list[*]}
                ;;

            *) echo "Unknown operation: $1" ;;
        esac
    done
}

main "$@"
