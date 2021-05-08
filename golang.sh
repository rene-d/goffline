#!/usr/bin/env bash
# Use a Docker container to call the Go modules downloader

set -e

GO_VERSION=${GO_VERSION:-1.14.15}

DOCKER_SCAN_SUGGEST=false docker build --build-arg GO_VERSION=${GO_VERSION} -t go-pkgs-dl .

mkdir -p $PWD/dl

if [[ "$1" == "build_only" ]]; then
    # just build the image

    exit

elif [[ "$1" == "shell" ]]; then
    # launch a shell into the conatiner

    exec docker run --rm -ti -v $PWD:/wd -w /wd go-pkgs-dl

elif [[ "$1" == "rshell" ]]; then
    # launch a shell into the conatiner

    exec docker run --network none --rm -ti -v $PWD:/wd -w /wd go-pkgs-dl

elif [[ "$1" == "chown" ]]; then
    exec docker run --rm -ti -v $PWD/dl:/dl go-pkgs-dl chown -R $(id -u):$(id -g) /dl


elif [[ "$1" == "test" ]]; then
    # unit tests

    rm -f dl/go/test[1-9].*

    # download only modules for the tests
    docker run --rm -i -v $PWD/dl:/dl go-pkgs-dl /main.sh test

    # # try to install godoctor with Internet connection    echo
    echo "Testing Go without Internet connection"
    echo

    # test compiled module
    docker run --rm -i -v $PWD/dl:/dl --network none go-pkgs-dl sh -c \
                "/dl/go/test1.sh -h;
                 /dl/go/test1.sh -i;
                 /dl/go/test1.sh -m;
                 /dl/go/test1.sh;
                 hello && echo '\033[32mtest 1 is ok\033[0m'"

    # test build with module (in GOPATH mode)
    (cat <<'EOF'
package main
import (
    "fmt"
    "rsc.io/sampler"
)
func main() {
    fmt.Println(sampler.Glass())
    fmt.Println("\033[32mtest 2 is ok\033[0m")
}
EOF
) | docker run --rm -i -v $PWD/dl:/dl --network none -w /work go-pkgs-dl sh -c "cat > hello.go ; \
                cat /dl/go/test2.sh | sh; \
                go env -w GO111MODULE=auto ; \
                go build hello.go; ls -l hello ; ./hello"

    # test build with module (in Go module mode)
    (cat <<'EOF'
package main
import (
	"fmt"
	"rsc.io/quote"
)
func main() {
	fmt.Println(quote.Hello())
    fmt.Println("\033[32mtest 3 is ok\033[0m")
}
EOF
) | docker run --rm -i -v $PWD/dl:/dl --network none -w /work go-pkgs-dl sh -c "cat > main.go ; \
    cat /dl/go/test3.sh | sh; \
    go env -w GO111MODULE=on ; \
    go mod init hello ; \
    echo 'require rsc.io/quote v1.5.2' >> go.mod ;\
    go build ; ls -l hello ; ./hello"

elif [[ "$1" =~ "vscode" ]]; then
    # download Visual Studio Code Go extension tools
    docker run --rm -i -v $PWD/dl:/dl ${list} go-pkgs-dl /main.sh $1

else
    # download Go modules
    list=
    if [[ -f $1 ]]; then
        list="-v $(realpath $1):/config.txt:ro"
        shift
    fi
    if [[ $# == 0 ]]; then
        set -- pkgs
    fi

    docker run --rm -i -v $PWD/dl:/dl ${list} go-pkgs-dl /main.sh $*
fi
