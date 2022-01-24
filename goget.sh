#!/usr/bin/env bash
# Make archive of Go downloaded Go modules.

if [[ ! -f /.dockerenv ]] || [[ ! ${GOLANG_VERSION} ]]; then
    echo >&2 "Should be run into the container"
    exit 2
fi

set -Eeuo pipefail

GOFFLINE_VERSION=${GOFFLINE_VERSION:=dev}

now="$(date +%s)"
now_iso8601="$(date --date=@"${now}" --iso-8601=seconds)"
test_count=0

compression=J
go_get_opt=
go_get_1by1=
suffix="$(date --date=@"${now}" +%Y%m%d%H%M%S)"
compute_sha=

dl_111module_setup()
{
    local name="$1"

    echo -e "Processing \033[1;33m${name}\033[0m with:"

    # the basename contains Go version and date, except for the unit tests
    if [[ ${name} =~ ^test[1-9]$ ]]; then
        basename="${name}"
        test_count=$((test_count + 1))
        local suffix="${suffix}.${test_count}"
    else
        basename="${name}-$(go version | sed -nr 's/^.* (go[0-9\.]+) .*$/\1/p')-${suffix}"
    fi

    export GOPATH="/tmp/cache/gopath"
    mkdir -p "${GOPATH}"
    go env -w GO111MODULE=on
}

dl_111module_add()
{
    local mode="$1"  # possible values: on bin
    shift

    # get the modules twice (everything goes under $GOPATH)
    echo "running go get with opt=${go_get_opt} 1by1=${go_get_1by1}"
    case ${mode} in
        bin)
            for i; do echo "  $i"; done

            for i; do
                local module=$(echo $i | cut -d= -f1)
                local bin=$(echo $module | sed -E 's?.*/([^/]+)@.*?\1?')
                local name=

                if [[ $module =~ = ]]; then
                    name=$(echo $i | cut -d= -f2)
                fi

                echo
                echo "~~~~~~~~~~ ${module} ${name} ~~~~~~~~~~"
                rm -rf /build
                mkdir -p "${GOPATH}"
                env GOPATH=/build GOARCH=arm64 go install "${module}"
                env GOPATH=/build GOARCH=amd64 go install "${module}"
                if [[ -n ${name} ]]; then
                    find /build/bin -name "${bin}" -execdir mv -n {} "${name}" \;
                fi
                cp -rp /build/bin "${GOPATH}"
            done
            ;;

        mod)
            if [[ ${go_get_1by1} ]]; then
                for i; do
                    echo
                    echo "~~~~~~~~~~ $i ~~~~~~~~~~"
                    env GOARCH=arm64 go get ${go_get_opt} $i
                    env GOARCH=amd64 go get ${go_get_opt} $i
                done
            else
                for i; do echo "  $i"; done
                env GOARCH=arm64 go get ${go_get_opt} $*
                env GOARCH=amd64 go get ${go_get_opt} $*
            fi
            ;;

        *)
            exit 2
            ;;
    esac
}

dl_111module_finish()
{
    local name="$1"
    local mode="$2"  # possible values: mod bin

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
    mkdir -p "${GOPATH}/pkg/mod/cache/download"
    mods=($(cd ${GOPATH}/pkg/mod/cache/download && find . -name '*.zip' | cut -d/ -f2- | sed -r 's,/@v/(.*)\.zip$,@\1,' | sed -e 's/!\([a-z]\)/\u\1/' | sort ))

    # save the module list info a text file
    echo "# tag: ${suffix}" > "${GOPATH}/gomods.txt.${suffix}"
    echo "# date: ${now_iso8601}" >> "${GOPATH}/gomods.txt.${suffix}"
    echo "# goffline: ${GOFFLINE_VERSION}" >> "${GOPATH}/gomods.txt.${suffix}"
    echo >> "${GOPATH}/gomods.txt.${suffix}"
    for i in ${mods[*]}; do
        echo "$i" | sed 's/@/ /' >> "${GOPATH}/gomods.txt.${suffix}"
    done
    chmod 444 "${GOPATH}/gomods.txt.${suffix}"

    # script to get a go.mod requirement
    cat <<'EOF' > "${GOPATH}/findmod"
#!/bin/sh
set -e
test -n "$1"
exec awk -v a="$1" '{ if ($1==a) print "require " $0 }' /go/gomods.txt
EOF
    chmod 755 "${GOPATH}/findmod"

    cat <<'EOF' > "${GOPATH}/updatemods"
#!/usr/bin/env python

from __future__ import print_function
import argparse
from os.path import exists


def main():
    parser = argparse.ArgumentParser(description="Update the mod list.")
    parser.add_argument("-w", "--write", action="store_true", help="Write go.mod if updated")
    parser.add_argument("gomod", help="Path to go.mod", default="go.mod", type=str, nargs="?")
    args = parser.parse_args()

    if not exists("/go/gomods.txt"):
        print("/go/gomods.txt not found")
        return

    if not exists(args.gomod):
        print("{} not found".format(args.gomod))
        return

    modules = {}
    for line in open("/go/gomods.txt"):
        line = line.strip()
        if line.startswith("#"):
            continue
        p = line.find(" ")
        if p != -1:
            name = line[:p]
            version = line[p + 1 :]
            modules[name] = version

    gomods = []
    updated = []
    for line in open(args.gomod):
        for name in modules:
            p = line.find(name)
            if p != -1:
                version = modules[name]
                if version not in line:
                    line = line[:p] + name + " " + version + "  // updated\n"
                    updated.append(name + " " + version)
                    break
        gomods.append(line)

    if len(updated) > 0:
        print("Module updated:")
        for line in updated:
            print("  " + line)
        if args.write:
            open(args.gomod, "w").write("".join(gomods))
        else:
            print("Run with -w to update {}".format(args.gomod))
    else:
        print("{} is ok".format(args.gomod))


if __name__ == "__main__":
    main()
EOF
    chmod 755 "${GOPATH}/updatemods"

    echo "Making archive compression=${compression}"
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
    echo "tag: ${suffix}"
    echo "date: ${now_iso8601}"
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

    if [[ ${compute_sha} ]]; then
        # add checksum file
        cd "${DESTDIR}/go"
        sha256sum -b "${filename}" > "${filename}.sha256"
    fi

    rm -rf "${GOPATH}"

    # we're done
    echo "Done"
    echo
}


dl_111module()
{
    local name="$1"
    local mode="$2"  # possible values: mod bin
    shift 2
    dl_111module_setup "${name}"
    dl_111module_add "${mode}" "$@"
    dl_111module_finish "${name}" "${mode}"
}

#
# Binary (precompiled) assets stuff
#

get_latest_release()
{
    local repo="$1"
    local asset="$2"
    local url
    url=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" |
          jq --arg asset ${asset} -r '.assets | map(select(.name | match($asset)).browser_download_url)[]' | head -n1)

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

#
# VSCode Go Extension stuff
#

filter_gopls()
{
    local name=
    local importPath
    local defaultVersion

    while read line; do
        if [[ $line =~ "': {" ]]; then
            # start of block
            name=$(echo "$line" | cut -d\' -f2)
            defaultVersion=
            importPath=

        elif [[ $line =~ "importPath: '" ]] ; then
            importPath=$(echo "$line" | cut -d\' -f2)

        elif [[ $line =~ "replacedByGopls: true" ]]; then
            echo >&2 "  skip $name $importPath (replaced by gopls)"
            name=

        elif [[ $line =~ "defaultVersion: " ]]; then
            defaultVersion=$(echo "$line" | cut -d\' -f2)

        elif [[ $line == }, ]]; then
            # end of block
            if [[ $name ]]; then
                echo >&2 "  get  $importPath@${defaultVersion:=latest} as $name"
                echo "$importPath@${defaultVersion:=latest}=$name"
            fi
        fi
    done
}

# compare two semver (leq=less than or equal)
semver_leq()
{
    printf '%s\n%s' "$1" "$2" | sort -C -V
}

# get tool list from https://github.com/golang/vscode-go
vscode_gotools()
{
    local tag=$(curl -sL https://api.github.com/repos/golang/vscode-go/releases/latest | jq -r '.tag_name')
    if [[ ! ${tag} ]]; then
        exit 2
    fi

    # tools information has been moved in v0.26.0
    if semver_leq "${tag}" "v0.26.0"; then
        curl -sL "https://raw.githubusercontent.com/golang/vscode-go/${tag}/src/goTools.ts"
    else
        curl -sL "https://raw.githubusercontent.com/golang/vscode-go/${tag}/src/goToolsInformation.ts"
    fi
}

#
# Other stuff
#

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

# add @latest if version is not present
add_version_if_missing()
{
    while read mod; do
        if [[ ${mod} =~ @ ]]; then
            echo "${mod}"
        else
            echo "${mod}@latest"
        fi
    done
}

#
# main routine
#

usage()
{
    echo "Usage: $0 <command> | [options]"
    exit 0
}

main()
{
    mkdir -p "${DESTDIR}"/go

    local name="mods"

    # parse options
    while [[ $# != 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            -j|--bzip2) compression=j; shift 1 ;;
            -z|--gzip) compression=z; shift 1 ;;
            --no) compression=; shift 1 ;;
            -m|--mode) mode="$2"; shift 2 ;;
            -s|--suffix) suffix="$2"; shift 2 ;;
            -t|--test) go_get_opt="${go_get_opt} -t"; shift ;;
            -1|--1by1) go_get_1by1=1; shift ;;
            -n|--name) name="$2"; shift 2 ;;
            --sha) compute_sha=1; shift ;;
            --) shift; break ;;
            * ) break ;;
        esac
    done

    case "${1:-}" in
        test)
            rm -f "${DESTDIR}"/go/dl/go/test[1-9].*

            compression=J dl_111module test1 bin golang.org/x/example/hello@latest
            compression=z dl_111module test2 mod rsc.io/quote@v1.5.2
            compression=j dl_111module test3 mod rsc.io/quote golang.org/x/text golang.org/x/example
            # nota: golang.org/x/text@v0.3.3 is mysteriously required when golang.org/x/example and rsc.io are both required

            return
            ;;

        assets)
            local list=($(cat /config.txt | parse_go_config gotools))
            dl_assets ${list[*]}

            return
            ;;

        vscode*)
            local list

            # fetch the list of tools into the the source code of the extension
            list=($(vscode_gotools | filter_gopls | sort -u | adapt_version))
            dl_111module_setup "$1"
            dl_111module_add bin ${list[*]}
            dl_111module_finish "$1" bin

            return
            ;;
    esac

    if [[ $# != 0 ]]; then
        echo >&2 "Unknown option: $*"
        exit 1
    fi

    dl_111module_setup "${name}"

    # Go module
    local list=($(cat /config.txt | parse_go_config go | add_version_if_missing))
    dl_111module_add mod ${list[*]}

    # cmdlet
    local listbin=($(cat /config.txt | parse_go_config gobin | add_version_if_missing))
    dl_111module_add bin ${listbin[*]}

    dl_111module_finish "${name}" mod
}

main "$@"
