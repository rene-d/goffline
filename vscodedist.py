#!/usr/bin/env python3
# Package extensions into a single archive for host and remote installations.

from typing import List
from zipfile import ZipFile
import tarfile
from datetime import datetime
import argparse
from pathlib import Path
import re
import configparser


def find_vsix(vsix_dir: Path, vsix_name: str, arch: str = "x86_64") -> Path:
    """ Find the most recent vsix in the download directory. """

    if vsix_name == "ms-vscode.cpptools":
        if arch == "aarch64":
            vsix_name = "ms-vscode.cpptools-linux-aarch64"
        else:
            vsix_name = "ms-vscode.cpptools-linux"

    last_version = (-1,)

    # make a case insensitive regex that match "<name>-x.y.z.vsix"
    p = re.compile(vsix_name.replace(".", r"\.").replace("-", r"\-") + "\-(\d+\.\d+\.\d+)\.vsix", re.IGNORECASE)

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


def make_host(download_dir: Path, version: str, host_extensions: List):
    """ Make the archive for host extensions that should be unzipped in %USERPROFILE% / $HOME. """

    zip_file = download_dir / f"VSCode-host-extensions-{version}.zip"

    print(f"Make host extensions archive: {zip_file.name}")

    with ZipFile(zip_file, "w") as zip_host:
        for vsix_name in host_extensions:

            vsix_file = find_vsix(download_dir / f"vscode-extensions-{version}", vsix_name)

            print(f"adding {vsix_file.name}")

            with ZipFile(vsix_file) as vsix_zip:
                for f in vsix_zip.infolist():
                    if f.filename == "extension.vsixmanifest":
                        f.filename = f".vscode/extensions/{vsix_name}/.vsixmanifest"
                        zip_host.writestr(f, vsix_zip.read(f))
                    elif f.filename.startswith("extension/"):
                        f.filename = f".vscode/extensions/{vsix_name}" + f.filename[len("extension") :]
                        zip_host.writestr(f, vsix_zip.read(f))
                    else:
                        pass


def make_remote(download_dir: Path, version: str, commit_id: str, remote_extension: List, arch: str = "x86_64"):
    """ Make the archive for remote extensions that should be extracted into $HOME. """

    tar_remote = tarfile.open(download_dir / f"vscode-server+extensions-{arch}-{version}.tar.xz", mode="w:xz")

    print(f"Make host extensions archive: {Path(tar_remote.name).name}")

    if arch == "aarch64":
        server_archive = "vscode-server-linux-arm64.tar.gz"
    else:
        server_archive = "vscode-server-linux-x64.tar.gz"

    print(f"adding {server_archive}")

    basedir = f".vscode-server/bin/{commit_id}"
    server = tarfile.open(download_dir / f"vscode-{version}/{server_archive}", mode="r:gz")
    for i in server.getmembers():
        p = i.name.find("/")
        if p == -1:
            i.name = basedir
        else:
            i.name = basedir + i.name[p:]
        tar_remote.addfile(i, server.extractfile(i))
    server.close()

    for vsix_name in remote_extension:

        vsix_file = find_vsix(download_dir / f"vscode-extensions-{version}", vsix_name, arch)

        print(f"adding {vsix_file.name}")

        with ZipFile(vsix_file) as vsix:
            for f in vsix.infolist():
                ti = tarfile.TarInfo()
                if f.filename == "extension.vsixmanifest":
                    ti.name = f".vscode-server/extensions/{vsix_name}/.vsixmanifest"
                elif f.filename.startswith("extension/"):
                    ti.name = f".vscode-server/extensions/{vsix_name}" + f.filename[len("extension") :]
                else:
                    continue
                ti.mode = f.external_attr >> 16
                ti.size = f.file_size
                ti.mtime = int(datetime(*f.date_time).timestamp())
                tar_remote.addfile(ti, vsix.open(f))

    tar_remote.close()


def load_conf(conf_file):
    """ Use a configuration file to build the host and remote archives. """

    config = configparser.ConfigParser(allow_no_value=True)
    config.read(conf_file)

    download_dir = Path("dl")
    commit = None
    version = None

    for i in download_dir.glob("vscode-*"):
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

    print(f"Found version {version} commit {commit}")

    if "vscode:host" in config:
        make_host(download_dir, version, list(config["vscode:host"].keys()))

    if "vscode:remote" in config:
        make_remote(download_dir, version, commit, list(config["vscode:remote"].keys()), "x86_64")


def main():
    parser = argparse.ArgumentParser(description="Make archive for Visual Studio Code offline installation")
    parser.add_argument("-d", "--download-dir", help="download dir", default="dl")
    parser.add_argument("--vscode-version", help="Visual Studio Code version")
    parser.add_argument("--commit-id", help="Visual Studio Code commit id")
    parser.add_argument("-H", "--host-extension", help="Host extension", action="append")
    parser.add_argument("-R", "--remote-extension", help="Remote extension", action="append")
    parser.add_argument("--arch", help="Architecture", default="x86_64")

    parser.add_argument("-f", help="configuration file")

    args = parser.parse_args()

    if args.f:
        return load_conf(args.f)

    if args.host_extension:
        make_host(Path(args.download_dir), args.vscode_version, args.host_extension)

    if args.remote_extension:
        make_remote(Path(args.download_dir), args.vscode_version, args.commit_id, args.remote_extension, args.arch)


if __name__ == "__main__":
    main()