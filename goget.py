#!/usr/bin/env python3
# Download the last Visual Studio Code extension compatible with a given version

import argparse
from unicodedata import name
import requests
from pathlib import Path
import os
import subprocess
import datetime
import tarfile
import base64
import re
import shutil
import logging


class GogoGadget:
    def __init__(self, name, bins, mods, output=None, tag=None, compression=None):
        self.name = name
        self.output = output or "."
        self.tag = tag or "tag"
        self.now_iso8601 = datetime.datetime.now().isoformat()
        self.compression = compression or "gz"
        self.bins = GogoGadget.ensure_version(bins)
        self.mods = GogoGadget.ensure_version(mods)
        self.GOVERSION = subprocess.check_output(["go", "env", "GOVERSION"]).decode().strip()
        self.GOFFLINE_VERSION = os.environ.get("GOFFLINE_VERSION", "master")

    def ensure_version(mods):
        """Ensure that the version is in the format 'module@version'."""
        new_mods = set()
        for mod in mods:
            if "@" not in mod:
                mod = f"{mod}@latest"
            new_mods.add(mod)
        return new_mods

    def downloaded_versions(self):

        dl = Path("/go/pkg/mod/cache/download")
        for zip in dl.rglob("*.zip"):
            m, v = str(zip.relative_to(dl)).split("/@v/")
            m = re.sub(r"(![a-z])", lambda c: c.group(1)[1].upper(), m)
            v = v[:-4]
            yield f"{m} {v}"

    def download_bins(self):
        """Install Go modules for both architectures."""

        if not self.bins:
            logging.info("No binary to install")
            self.bins_versions = []
            return

        logging.info("Installing binaries")

        # download and compile for linux/amd64
        for arch in ["amd64", "arm64"]:
            subprocess.run(["go", "env", "-w", f"GOARCH={arch}", "GOOS=linux"])
            for mod in self.bins:
                logging.debug(f"Install {mod} for arch {arch}")
                subprocess.run(["go", "install", "-ldflags=-s -w", mod])

        # move the host arch binaries to the relying subdir
        hostarch, hostos = subprocess.check_output(["go", "env", "GOHOSTARCH", "GOHOSTOS"]).decode().splitlines()

        b = Path("/go/bin") / f"{hostos}_{hostarch}"
        b.mkdir(parents=True, exist_ok=True)

        for f in Path("/go/bin").glob("*"):
            if f.is_file():
                (b / f.name).unlink(missing_ok=True)
                f.rename(b / f.name)

        # restore values
        subprocess.run(["go", "env", "-u", "GOARCH", "GOOS"])

        # find the binaries versions (from the download cache)
        bins = set(i.split("@")[0] for i in self.bins)
        self.bins_versions = []
        for i in self.downloaded_versions():
            m, v = i.split(" ")
            for bin in bins:
                if bin.startswith(m):
                    self.bins_versions.append(f"{bin} {v}")

        shutil.rmtree("/go/pkg", ignore_errors=True)

    def download_mods(self):
        """Download Go modules."""

        if not self.mods:
            logging.info("No module to download")
            self.mods_versions = []
            return

        logging.info("Downloading modules")

        tmp = Path("/project")
        tmp.mkdir(parents=True, exist_ok=True)
        tmp.joinpath("go.mod").unlink(missing_ok=True)
        subprocess.run(["go", "mod", "init", "download"], cwd=tmp)
        go_mod = tmp / "go.mod"
        fresh = go_mod.read_bytes()
        for mod in self.mods:
            logging.debug(f"Download {mod}")
            go_mod.write_bytes(fresh)
            subprocess.run(["go", "get", mod], cwd=tmp)

        Path(f"/go/gosums.txt.{self.tag}").write_text(tmp.joinpath("go.sum").read_text())

        self.mods_versions = list(self.downloaded_versions())

    def info_file(self):
        """Save the module list info a text file."""

        logging.info(f"Write info file")

        info = Path("/go") / f"gomods.txt.{self.tag}"
        with info.open("w") as f:
            f.write(f"# tag: {self.tag}\n")
            f.write(f"# date: {self.now_iso8601}\n")
            f.write(f"# goffline: {self.GOFFLINE_VERSION}\n")
            for v in self.bins_versions:
                f.write(f"# bin: {v}\n")
            for v in self.mods_versions:
                f.write(f"{v}\n")

        info.chmod(0o444)

    def write_tools(self):
        """Write the script to get a go.mod requirement.
        Write the script to update the module versions in go.mod."""

        if len(self.mods) == 0:
            return

        logging.info(f"Write tools")

        findmod = Path("/go") / "findmod"
        findmod.write_text(
            """\
#!/bin/sh
set -e
test -n "$1"
exec awk -v a="$1" '{ if ($1==a) print "require " $0 }' /go/gomods.txt
"""
        )
        findmod.chmod(0o755)

        updategomod = Path("/go") / "updategomod"
        updategomod.write_text(
            """\
#!/bin/bash
exec $(which python3 || which python || which false) - <<'#PYTHON' "$@"
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
                    line = f"{line[:p]}{name} {version} // updated\\n"
                    updated.append(name + " " + version)
                    break
        gomods.append(line)

    if len(updated) > 0:
        print("Module updated:")
        for line in updated:
            print("  " + line)
        if args.write:
            open(args.gomod, "w").write("".join(gomods))
            print(f"{args.gomod} updated")
            go_sum = args.gomod.replace("go.mod", "go.sum")
            if exists(go_sum) and exists("/go/gosums.txt"):
                open(go_sum, "w").write(open("/go/gosums.txt").read())
                print(f"{go_sum} updated")
        else:
            print("Run with -w to update {}".format(args.gomod))
    else:
        print("{} is ok".format(args.gomod))


if __name__ == "__main__":
    main()

#PYTHON
"""
        )
        updategomod.chmod(0o755)

    def make_tar(self):
        """Make the tar archive."""

        logging.info(f"Make archive with compression {self.compression}")

        # create the archive
        archive = Path("/tmp/go-modules.tar")

        def chmod_all(i: tarfile.TarInfo) -> tarfile.TarInfo:
            """Equivalent to chmod a+rX: add owner permission for all, except write."""
            a = (i.mode & 0o500) >> 6
            i.mode = i.mode | (a << 3) | a
            return i

        it = Path("/go").rglob("*") if self.mods else Path("/go/bin").rglob("*")

        with tarfile.open(archive, f"w:{self.compression}") as tar:
            for f in it:
                if f.is_file():
                    tar.add(f, arcname=f.relative_to("/go"), filter=chmod_all)

    def make_selfextract(self):
        """Make a self-extracting archive."""

        compression_letter = {"gz": "z", "bz2": "j", "xz": "J"}[self.compression]
        mode = "bin" if len(self.mods) == 0 else "mod"

        list_bins = "\n".join(f"    echo '{i}'" for i in sorted(self.bins_versions))
        list_mods = "\n".join(f"    echo '{i}'" for i in sorted(self.mods_versions))

        script = f"""\
#!/bin/sh
if [ "$1" = "-m" ]; then
{list_bins}
    echo
{list_mods}
    exit
elif [ "$1" = "-i" ]; then
    echo "version: {self.GOVERSION}"
    echo "tag: {self.tag}"
    echo "date: {self.now_iso8601}"
    echo "goffline: {self.GOFFLINE_VERSION}"
    exit
elif [ "$1" = "-t" ]; then
    fn()
    {{
        tar -t{compression_letter}
    }}
elif [ "$1" = "-tv" ]; then
    fn()
    {{
        tar -tv{compression_letter}
    }}
elif [ "$1" = "-x" ]; then
    fn()
    {{
        cat
    }}
elif [ -n "$1" ]; then
    echo "Usage: $0 [option]"
    echo "  -x     extract to stdin"
    echo "  -t[v]  list content"
    echo "  -i     display information"
    echo "  -m     print modules list"s
    exit
else
    fn()
    {{
        local ver=$(go env GOVERSION)
        if [ "$ver" != "{self.GOVERSION}" ]; then
            echo >&2 "Go version mismatch"
            echo >&2 "Found:    $ver"
            echo >&2 "Expected: {self.GOVERSION}"
            exit 2
        fi
        local arch=$(go env GOHOSTARCH)
        if [ $arch = amd64 ]; then exclude=arm64; else exclude=amd64; fi
        tar -C $(go env GOPATH) \\
            -x{compression_letter} \\
            --no-same-owner \\
            --transform="s,bin/linux_$arch,bin," \\
            --exclude="bin/linux_$exclude*"
        if [ {mode} != bin ]; then
            cd $(go env GOPATH)
            cat gomods.txt.* | sort -u | grep -v "^# [dg]" > gomods.txt
            cat gosums.txt.* | sort -u > gosums.txt
            chmod 444 gomods.txt
        fi
    }}
fi
base64 -d <<'#EOF#' | fn
"""

        selfextract = Path(self.output) / f"{self.name}-{self.GOVERSION}-{self.tag}.sh"
        tar = Path("/tmp/go-modules.tar")

        logging.info(f"Create self-extracting archive {selfextract}")

        with tar.open("rb") as tarf:
            with selfextract.open("wb") as sfx:
                sfx.write(script.encode())
                base64.encode(tarf, sfx)
                sfx.write("#EOF#".encode())

        selfextract.chmod(0o755)


def vscode_ext_tools():
    r = requests.get("https://api.github.com/repos/golang/vscode-go/releases/latest").json()
    tag_name = r["tag_name"]
    url = f"https://raw.githubusercontent.com/golang/vscode-go/{tag_name}/src/goToolsInformation.ts"
    r = requests.get(url).text

    bins = []

    for line in r.splitlines():

        line = line.strip()

        m = re.match(r"'(.+)': {", line)
        if m:
            name = m.group(1)
            default_version = "latest"
            import_path = None
            continue

        m = re.match(r"importPath: '(.+)'", line)
        if m:
            import_path = m.group(1)
            continue

        m = re.match(r"defaultVersion: '(.+)'", line)
        if m:
            default_version = m.group(1)
            continue

        if "replacedByGopls: true" in line:
            # skip $name $importPath (replaced by gopls)"
            name = None
            continue

        if line == "},":
            if name:
                bins.append(f"{import_path}@{default_version}")
            name = None

    return bins


def section(conf_file, name, force_latest=False):
    values = set()
    in_section = False
    for i in conf_file.read_text().splitlines():
        i = i.strip()
        if not i or i.startswith("#"):
            continue
        if i.startswith("["):
            in_section = i.startswith(f"[{name}]")
        else:
            if in_section:
                if " " in i:
                    i = i.split(" ", 1)
                    i = i[0].strip() + "@" + i[1].strip()
                if "@" not in i or force_latest:
                    i = i.split("@", 1)[0]
                    i = f"{i}@latest"
                values.add(i)
    return list(values)


def main():
    assert os.environ["GOPATH"] == "/go"

    parser = argparse.ArgumentParser()
    parser.add_argument("-n", "--name", help="basename", type=str, default="go")
    parser.add_argument("-o", "--output", help="output dir", type=Path)
    parser.add_argument("-t", "--tag", help="tag")
    parser.add_argument("-c", "--compression", help="compression")
    parser.add_argument("-f", "--conf", help="configuration file", type=Path)
    parser.add_argument("-l", "--latest", help="force latest", action="store_true")
    parser.add_argument("--vscode", help="vscode extension tools", action="store_true")
    parser.add_argument("-B", "--binary", help="binaries", action="append")
    parser.add_argument("-M", "--module", help="modules", action="append")

    args = parser.parse_args()

    logging.basicConfig(format="%(asctime)s - %(levelname)s - %(message)s", level=logging.DEBUG)

    logging.debug(f"{__file__} {args}")

    if args.vscode:
        go_bins = vscode_ext_tools()
        go_mods = []
    elif args.conf:
        go_bins = section(args.conf, "gobin", args.latest)
        go_mods = section(args.conf, "go", args.latest)
    elif args.module or args.binary:
        go_bins = args.binary or []
        go_mods = args.module or []
    else:
        go_bins = ["google.golang.org/protobuf/cmd/protoc-gen-go@latest"]
        go_mods = ["golang.org/x/tools@latest"]

    a = GogoGadget(args.name, go_bins, go_mods, args.output, args.tag, args.compression)

    a.download_bins()
    a.download_mods()

    a.info_file()
    a.write_tools()
    a.make_tar()

    a.make_selfextract()


if __name__ == "__main__":
    main()
