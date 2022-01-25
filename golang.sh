#!/usr/bin/env bash
# Use a Docker container to call the Go modules downloader

set -Eeuo pipefail

GO_VERSION="${GO_VERSION:-1.17.6}"

DOCKER_SCAN_SUGGEST=false docker build --build-arg GO_VERSION="${GO_VERSION}" -t goffline .

do_chown()
{
    # fix docker rootfull bind mount rights
    if find "$PWD/dl" -user root -print -quit | grep -q "." ; then
        echo "Change owner to $(id -un)"
        exec docker run --rm -i -v "$PWD/dl:/dl" goffline chown -R "$(id -u):$(id -g)" /dl
    fi
}

mkdir -p "$PWD/dl"

if [[ "${1:-}" == "build_only" ]]; then
    # just build the image

    exit

elif [[ "${1:-}" == "shell" ]]; then
    # launch a shell into the container

    exec docker run --rm -ti -v "$PWD:/wd" -w /wd goffline

elif [[ "${1:-}" == "rshell" ]]; then
    # launch a shell into the container without network access

    exec docker run --network none --rm -ti -v "$PWD:/wd" -w /wd goffline

elif [[ "${1:-}" == "chown" ]]; then
    # chown files if Docker is ran rootfull

    do_chown

elif [[ "${1:-}" == "test" ]]; then
    # unit tests

    # download only modules for the tests
    docker run --init -e TINI_KILL_PROCESS_GROUP=1 --rm -i -v "$PWD/dl:/dl" goffline /goget.sh test

    # # try to install godoctor with Internet connection    echo
    echo "Testing Go without Internet connection"
    echo

    # --------------------------------------------------------------------------------
    # test1: test compiled module
    echo -e '\n\033[35mrunning test 1 ...\033[0m'
    docker run --rm -i -v "$PWD/dl:/dl" --network none goffline sh -c "
        printf '\033[1;34m'; /dl/go/test1.sh -h;
        printf '\033[1;37m'; /dl/go/test1.sh -i;
        printf '\033[1;31m'; /dl/go/test1.sh -m;
        printf '\033[0m';    /dl/go/test1.sh;
        go version ;
        hello && echo '\033[32mtest 1 is ok\033[0m'"

    # --------------------------------------------------------------------------------
    # test2: test build with module (in Go module mode)
    echo -e '\n\033[35mrunning test 2 ...\033[0m'
    (cat <<'EOF'
package main
import (
	"fmt"
	"rsc.io/quote"
)
func main() {
	fmt.Println(quote.Hello())
    fmt.Println("\033[32mtest 2 is ok\033[0m")
}
EOF
    ) | docker run --rm -i -v "$PWD/dl:/dl" --network none -w /work goffline sh -c "
            cat > main.go ;
            cat /dl/go/test2.sh | sh;
            ls -l /go;
            go env -w GO111MODULE=on ;
            go mod init hello ;
            echo 'require rsc.io/quote' >> go.mod ;
            /go/updategomod -w ;
            go mod tidy ;
            go build ; ls -l hello ; ./hello"

    # --------------------------------------------------------------------------------
    # test3: test add second module archive
    echo -e '\n\033[35mrunning test 3 ...\033[0m'
    (cat <<'EOF'
package main
import (
	"fmt"
	"rsc.io/quote"
    "golang.org/x/example/stringutil"
)
func main() {
	fmt.Println(stringutil.Reverse(quote.Hello()))
    fmt.Println("\033[32mtest 3 is ok\033[0m")
}
EOF
    ) | docker run --init -e TINI_KILL_PROCESS_GROUP=1 --rm -i -v "$PWD/dl:/dl" --network none -w /work goffline sh -c "
            cat > main.go ;
            cat /dl/go/test3.sh | sh ;
            ls -l /go;
            go env -w GO111MODULE=on ;
            go mod init hello ;
            echo 'require rsc.io/quote v1.5.2' >> go.mod ;
            /go/findmod golang.org/x/example >> go.mod ;
            /go/findmod golang.org/x/text    >> go.mod ;
            go mod tidy ;
            go build ; ls -l hello ; ./hello"

    echo ""
	do_chown

else
    # download Go modules
    config=
    if [[ $# -ge 2 ]] && [[ "$1" == "-f" ]]; then
        config="-v $(realpath "$2"):/config.txt:ro"
        shift 2
    fi

    docker run --init -e TINI_KILL_PROCESS_GROUP=1 --rm -i -v "$PWD/dl:/dl" \
        -e "GOFFLINE_VERSION=$(git describe --always --tags)" ${config} goffline /goget.sh $*

    do_chown
fi
