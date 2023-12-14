#!/usr/bin/env python3
# Package extensions into a single archive for host and remote installations.

from typing import Set
from zipfile import ZipFile
import tarfile
from datetime import datetime
import argparse
from pathlib import Path
import re
import hashlib


def find_vsix(vsix_dir: Path, vsix_name: str, arch: str = "x86_64") -> Path:
    """Find the most recent vsix in the download directory."""

    # use Windows semantics
    if arch == "aarch64":
        arch = "arm64"
    else:
        arch = "x64"

    last_version = (-1,)

    # make a case insensitive regex that match "<name>[-linux-{arch}]-x.y.z.vsix"
    p = re.compile(
        r"^" + re.escape(vsix_name) + rf"(?:\-linux\-{arch})?\-(\d+\.\d+\.\d+)\.vsix",
        re.IGNORECASE,
    )

    for i in vsix_dir.glob("*.vsix"):
        m = p.match(i.name)
        if m:
            semver = tuple(map(int, m[1].split(".")))
            if last_version < semver:
                last_version = semver
                vsix = i

    if last_version == (-1,):
        print(f"Extension not found: {vsix_name}")
        exit(2)

    return vsix


def make_host(dest_dir: Path, version: str, host_extensions: Set[str]):
    """Make the archive for host extensions that should be unzipped in %USERPROFILE% / $HOME."""

    zip_file = dest_dir / f"vscode-host-extensions-{version}.zip"
    digest_file = zip_file.parent / ("." + zip_file.stem + ".digest")

    # compute a hash with archive filenames
    sha = hashlib.sha256()
    for vsix_name in sorted(host_extensions):
        vsix_file = find_vsix(dest_dir / f"vscode-extensions-{version}", vsix_name)
        sha.update(vsix_file.name.encode("utf-8"))
    digest_hexvalue = sha.hexdigest()

    # do not rebuild archive if up to date
    if zip_file.is_file():
        if digest_file.is_file():
            if digest_file.read_text() == digest_hexvalue:
                print(f"\033[1;33mHost\033[0m extensions archive \033[1;32m{zip_file.name}\033[0m is up to date")
                return
        digest_file.unlink()

    print(f"Making \033[1;33mhost\033[0m extensions archive")

    with ZipFile(zip_file, "w") as zip_host:
        for vsix_name in host_extensions:
            vsix_file = find_vsix(dest_dir / f"vscode-extensions-{version}", vsix_name)

            # directory name contains the version and is lowercase
            vsix_dir = vsix_file.with_suffix("").name.lower()

            print(f"adding {vsix_file.name}")

            with ZipFile(vsix_file) as vsix_zip:
                for f in vsix_zip.infolist():
                    if f.filename == "extension.vsixmanifest":
                        f.filename = f".vscode/extensions/{vsix_dir}/.vsixmanifest"
                        zip_host.writestr(f, vsix_zip.read(f))
                    elif f.filename.startswith("extension/"):
                        f.filename = f".vscode/extensions/{vsix_dir}" + f.filename[len("extension") :]
                        zip_host.writestr(f, vsix_zip.read(f))
                    else:
                        pass

    digest_file.write_text(digest_hexvalue)

    print(f"written: \033[1;32m{zip_file.name}\033[0m")
    print("Done")


def make_remote(
    dest_dir: Path,
    version: str,
    commit_id: str,
    remote_extension: Set[str],
    arch: str = "x86_64",
):
    """Make the archive for remote extensions that should be extracted into $HOME."""

    tar_file = dest_dir / f"vscode-server+extensions-{arch}-{version}.tar.xz"
    digest_file = tar_file.parent / ("." + tar_file.stem + ".digest")

    if arch == "aarch64":
        server_archive = "vscode-server-linux-arm64.tar.gz"
    elif arch == "x86_64":
        server_archive = "vscode-server-linux-x64.tar.gz"
    elif arch == "alpine-aarch64":
        server_archive = "vscode-server-alpine-arm64.tar.gz"
    elif arch == "alpine-x86_64":
        server_archive = "vscode-server-linux-alpine.tar.gz"
    else:
        raise

    # compute a hash with archive filenames
    sha = hashlib.sha256()
    sha.update(server_archive.encode("utf-8"))
    for vsix_name in sorted(remote_extension):
        vsix_file = find_vsix(dest_dir / f"vscode-extensions-{version}", vsix_name, arch)
        sha.update(vsix_file.name.encode("utf-8"))
    digest_hexvalue = sha.hexdigest()

    # do not rebuild archive if up to date
    if tar_file.is_file():
        if digest_file.is_file():
            if digest_file.read_text() == digest_hexvalue:
                print(
                    f"\033[1;33mRemote\033[0m extensions archive for arch \033[1;33m{arch}\033[0m \033[1;32m{tar_file.name}\033[0m is up to date"
                )
                return
            digest_file.unlink()

    print(f"Making \033[1;33mremote\033[0m extensions archive for arch \033[1;33m{arch}\033[0m")

    tar_remote = tarfile.open(tar_file, mode="w:xz")

    print(f"adding server {server_archive}")

    basedir = f".vscode-server/bin/{commit_id}"
    server = tarfile.open(dest_dir / f"vscode-{version}/{server_archive}", mode="r:gz")
    for i in server.getmembers():
        p = i.name.find("/")
        if p == -1:
            i.name = basedir
        else:
            i.name = basedir + i.name[p:]
        tar_remote.addfile(i, server.extractfile(i))
    server.close()

    for vsix_name in remote_extension:
        vsix_file = find_vsix(dest_dir / f"vscode-extensions-{version}", vsix_name, arch)

        # directory name contains the version and is lowercase
        vsix_dir = vsix_file.with_suffix("").name.lower()

        print(f"adding extension {vsix_file.name}")

        with ZipFile(vsix_file) as vsix:
            for f in vsix.infolist():
                ti = tarfile.TarInfo()
                if f.filename == "extension.vsixmanifest":
                    ti.name = f".vscode-server/extensions/{vsix_dir}/.vsixmanifest"
                elif f.filename.startswith("extension/"):
                    ti.name = f".vscode-server/extensions/{vsix_dir}" + f.filename[len("extension") :]
                else:
                    continue
                ti.mode = f.external_attr >> 16
                ti.size = f.file_size
                ti.mtime = int(datetime(*f.date_time).timestamp())
                tar_remote.addfile(ti, vsix.open(f))

    tar_remote.close()

    digest_file.write_text(digest_hexvalue)

    print(f"written: \033[1;32m{tar_file.name}\033[0m")
    print("Done")


def read_conf(conf_file):
    """Read the configuration file."""
    conf = {}
    in_section = None
    for i in conf_file.read_text().splitlines():
        i = i.strip()
        if not i or i.startswith("#"):
            continue
        if i.startswith("["):
            in_section = re.match("^\[(.*)\]$", i)
            if in_section:
                in_section = in_section.group(1)
                conf[in_section] = set()

        else:
            if in_section:
                conf[in_section].add(i)
    return conf


def process_conf_file(dest_dir, conf_file):
    """Use a configuration file to build the host and remote archives."""

    config = read_conf(conf_file)

    commit = None
    version = None

    for i in dest_dir.glob("vscode-*"):
        version_file = i / "version"
        if i.is_dir() and version_file.is_file():
            if commit or version:
                print("Error: found more than one version file.")
                exit(2)
            for line in version_file.read_text().splitlines():
                key, value = line.split("=", 2)
                if key == "commit":
                    commit = value
                elif key == "version":
                    version = value

    if not version or not commit:
        print("Error: no version version file found.")
        exit(2)

    print(f"Found version \033[1;32m{version}\033[0m commit \033[1;32m{commit}\033[0m")

    common = config.get("vscode:common", set())

    if "vscode:host" in config:
        make_host(dest_dir, version, common.union(config["vscode:host"]))

    if "vscode:remote" in config:
        # archive for Linux remote (with glibc)
        remote_extensions = common.union(config["vscode:remote"])
        make_remote(dest_dir, version, commit, remote_extensions, "x86_64")
        make_remote(dest_dir, version, commit, remote_extensions, "aarch64")

    if "vscode:alpine" in config:
        # archive for AlpineLinux remote (with musl-libc)
        remote_extensions = common.union(config["vscode:alpine"])
        make_remote(dest_dir, version, commit, remote_extensions, "alpine-x86_64")
        make_remote(dest_dir, version, commit, remote_extensions, "alpine-aarch64")


def main():
    parser = argparse.ArgumentParser(description="Make archive for Visual Studio Code offline installation")
    parser.add_argument("-d", "--dest-dir", help="dest dir", default=".")
    parser.add_argument("--vscode-version", help="Visual Studio Code version")
    parser.add_argument("--commit-id", help="Visual Studio Code commit id")
    parser.add_argument("-H", "--host-extension", help="Host extension", action="append")
    parser.add_argument("-R", "--remote-extension", help="Remote extension", action="append")
    parser.add_argument("--arch", help="Architecture", default="x86_64")
    parser.add_argument("-c", "--config", help="configuration file", type=Path)

    args = parser.parse_args()

    if args.config:
        return process_conf_file(Path(args.dest_dir), args.config)

    if args.host_extension:
        make_host(Path(args.dest_dir), args.vscode_version, set(args.host_extension))

    if args.remote_extension:
        make_remote(
            Path(args.dest_dir),
            args.vscode_version,
            args.commit_id,
            set(args.remote_extension),
            args.arch,
        )


if __name__ == "__main__":
    main()
