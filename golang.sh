#!/usr/bin/env bash
# Use a Docker container to call the Go modules downloader

set -e

GO_VERSION="${GO_VERSION:-1.14.15}"

DOCKER_SCAN_SUGGEST=false docker build --build-arg GO_VERSION="${GO_VERSION}" -t go-pkgs-dl .

mkdir -p "$PWD/dl"

if [[ "$1" == "build_only" ]]; then
    # just build the image

    exit

elif [[ "$1" == "shell" ]]; then
    # launch a shell into the conatiner

    exec docker run --rm -ti -v "$PWD:/wd" -w /wd go-pkgs-dl

elif [[ "$1" == "rshell" ]]; then
    # launch a shell into the conatiner

    exec docker run --network none --rm -ti -v "$PWD:/wd" -w /wd go-pkgs-dl

elif [[ "$1" == "chown" ]]; then
    # chown files if Docker is ran rootfull

    if ! find "$PWD/dl" -user root -print -quit | grep -q "." ; then
        echo "Change owner to $(id -un)"
        exec docker run --rm -i -v "$PWD/dl:/dl" go-pkgs-dl chown -R "$(id -u):$(id -g)" /dl
    fi

elif [[ "$1" == "test" ]]; then
    # unit tests

    # download only modules for the tests
    docker run --init -e TINI_KILL_PROCESS_GROUP=1 --rm -i -v "$PWD/dl:/dl" go-pkgs-dl /main.sh test

    # # try to install godoctor with Internet connection    echo
    echo "Testing Go without Internet connection"
    echo

    #  test1: test compiled module
    docker run --rm -i -v "$PWD/dl:/dl" --network none go-pkgs-dl sh -c "
        printf '\033[1;34m'; /dl/go/test1.sh -h;
        printf '\033[1;37m'; /dl/go/test1.sh -i;
        printf '\033[1;31m'; /dl/go/test1.sh -m;
        printf '\033[0m';    /dl/go/test1.sh;
        hello && echo '\033[32mtest 1 is ok\033[0m'"

    # test2: test build with module (in Go module mode)
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
    ) | docker run --rm -i -v "$PWD/dl:/dl" --network none -w /work go-pkgs-dl sh -c "
            cat > main.go ;
            cat /dl/go/test2.sh | sh;
            ls -l /go;
            go env -w GO111MODULE=on ;
            go mod init hello ;
            echo 'require rsc.io/quote v1.5.2' >> go.mod ;
            go mod tidy ;
            go build ; ls -l hello ; ./hello"

    # test3: test add second module archive
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
    ) | docker run --init -e TINI_KILL_PROCESS_GROUP=1 --rm -i -v "$PWD/dl:/dl" --network none -w /work go-pkgs-dl sh -c "
            cat > main.go ;
            cat /dl/go/test2.sh | sh;
            cat /dl/go/test3.sh | sh;
            ls -l /go;
            go env -w GO111MODULE=on ;
            go mod init hello ;
            echo 'require rsc.io/quote v1.5.2' >> go.mod ;
            echo 'require golang.org/x/example v0.0.0-20210407023211-09c3a5e06b5d' >> go.mod ;
            go mod tidy ;
            go build ; ls -l hello ; ./hello"

else
    # download Go modules
    list=
    if [[ -f $1 ]]; then
        list="-v $(realpath $1):/config.txt:ro"
        shift
    fi
    if [[ $# == 0 ]]; then
        set -- mods
    fi

    docker run --init -e TINI_KILL_PROCESS_GROUP=1 --rm -i -v "$PWD/dl:/dl" ${list} go-pkgs-dl /main.sh $*
fi
