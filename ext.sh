#!/usr/bin/env bash
# Download the last Visual Studio Code extension compatible with a given version

set -euo pipefail

slug=${1?missing extension identifier}
engine=${2:-1.63.2}

if [[ -z ${DESTDIR:+x} ]]; then
    dl_dir=.
else
    dl_dir=${DESTDIR}/vscode-extensions-${engine}
fi


# constants from vscode extension API
# https://github.com/microsoft/vscode/blob/main/src/vs/platform/extensionManagement/common/extensionGalleryService.ts

FilterType_Tag=1
FilterType_ExtensionId=4
FilterType_Category=5
FilterType_ExtensionName=7
FilterType_Target=8
FilterType_Featured=9
FilterType_SearchText=10
FilterType_ExcludeWithFlags=12

Flags_None=0x0
Flags_IncludeVersions=0x1
Flags_IncludeFiles=0x2
Flags_IncludeCategoryAndTags=0x4
Flags_IncludeSharedAccounts=0x8
Flags_IncludeVersionProperties=0x10
Flags_ExcludeNonValidated=0x20
Flags_IncludeInstallationTargets=0x40
Flags_IncludeAssetUri=0x80
Flags_IncludeStatistics=0x100
Flags_IncludeLatestVersionOnly=0x200
Flags_Unpublished=0x1000

# prepare the request: we look for golang.Go extension
#   - last version (Flags.IncludeLatestVersionOnly)
#   - we want the assets uri (Flags.IncludeAssetUri)
#   - details (Flags.IncludeVersionProperties)
data=$(cat <<EOF
{
    "filters": [
        {
            "criteria": [
                {
                    "filterType": $FilterType_Target,
                    "value": "Microsoft.VisualStudio.Code",
                },
                {
                    "filterType": $FilterType_ExcludeWithFlags,
                    "value": "$Flags_Unpublished",
                },
                {
                    "filterType": $FilterType_ExtensionName,
                    "value": "$slug"
                }
            ]
        }
    ],
    "flags": $(( Flags_IncludeAssetUri + Flags_IncludeVersionProperties)),
}
EOF
)

echo -e "extension: \033[1;33m${1}\033[0m"

json_file=/tmp/extdl$$.json
trap 'rm -f ${json_file}' EXIT

# issue the request
echo $data | curl -s \
                  -o ${json_file} \
                  -X POST --data-binary @- \
                  -H "Content-Type: application/json" \
                  -H "Accept: application/json;api-version=3.0-preview.1" \
                  "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"

# the extension name
name=$(cat ${json_file} | jq -r '.results[].extensions[] | (.publisher.publisherName + "." + .extensionName)')

# https://stackoverflow.com/questions/4023830
# not sure it works all the time, some version numbers may be messy
vercomp()
{
    if [[ "$1" == $2 ]] || [[ "$1" == '*' ]]
    then
        return 0  # versions are equal or any: ok
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1  # version is greater than expected: ko
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 0  # version is less than expected: ok
        fi
    done
    return 0  # versions are equal: ok
}

# get all version engines (recent first)
set -f # engine version could be "*" - really annoying in a shell script
engines=($(cat ${json_file} | jq -r \
    '.results[].extensions[].versions[].properties | map(select(.key | contains("Microsoft.VisualStudio.Code.Engine")).value)[]' \
    2>/dev/null || true))

# find the first suitable engine
version_index=
index=0
for e in "${engines[@]}"; do
    e="${e##^}"
    if vercomp "$e" "$engine" ; then
        echo -e "found compatible engine: \033[1;32m$e <= $engine\033[0m"
        version_index=$index
        break
    fi
    echo -e "\033[2mskipping version $e !~ $engine\033[0m"
    index=$((index + 1))
done

if [[ ! ${version_index} ]]; then
    echo "cannot find a suitable version"
    exit 2
fi

# we have the good version
version=$(cat ${json_file} | jq --argjson vi ${version_index} -r \
    '.results[].extensions[] | (.versions[$vi].version)')
echo -e "version: \033[1;32m${version}\033[0m"

mkdir -p "${dl_dir}"

curl_no_clobber()
{
    # with -nc and -o, wget indicates an error if file exists
    # (however, without -o it works as expected)
    if [[ ! -f "$1" ]]; then
        curl -sSL -o "$1" "$2"
    fi
}

targetPlaforms=($(cat ${json_file} | jq --arg v $version -r \
    '.results[].extensions[].versions[] | select(.version==$v).targetPlatform'))

echo -e "targetPlaforms: \033[1;32m${targetPlaforms[@]}\033[0m"

if [[ ${targetPlaforms[0]} != "null" ]]; then

    dl_arch()
    {
        local arch=$1

        # construct the vsix filename
        vsix=$(cat ${json_file} | jq --arg arch ${arch} --argjson vi ${version_index} -r \
            '.results[].extensions[] | (.publisher.publisherName+"."+ .extensionName+"-"+$arch+"-"+.versions[$vi].version+".vsix")')

        # construct the vsix filename with the platform
        assetUri=$(cat ${json_file} | jq --arg arch ${arch} --arg v ${version} -r \
            '.results[].extensions[].versions[] | select(.version==$v and .targetPlatform==$arch).assetUri')
        echo -e "vsix: \033[1;36m${vsix}\033[0m"

        # download the .vsix (e.g. the archive of the extension)
        curl_no_clobber "${dl_dir}/${vsix}" "$assetUri/Microsoft.VisualStudio.Services.VSIXPackage"
    }

    # assume we always have linux-x64 and linux-arm64 platforms
    dl_arch linux-x64
    dl_arch linux-arm64

elif [[ $name == "ms-vscode.cpptools" ]]; then

    # old C/C++ extension has to be downloaded from GitHub releases since it is platform dependent

    vsix=${name}-linux-arm64-${version}.vsix
    echo -e "vsix: \033[1;36m${vsix}\033[0m"
    curl_no_clobber "${dl_dir}/${vsix}" https://github.com/microsoft/vscode-cpptools/releases/download/${version}/cpptools-linux-aarch64.vsix

    vsix=${name}-linux-x64-${version}.vsix
    echo -e "vsix: \033[1;36m${vsix}\033[0m"
    curl_no_clobber "${dl_dir}/${vsix}" https://github.com/microsoft/vscode-cpptools/releases/download/${version}/cpptools-linux.vsix


elif [[ $name == "vadimcn.vscode-lldb" ]]; then

    # CodeLLDB extension has to be downloaded from GitHub releases since it is platform dependent

    vsix=${name}-linux-arm64-${version}.vsix
    echo -e "vsix: \033[1;36m${vsix}\033[0m"
    curl_no_clobber "${dl_dir}/${vsix}" https://github.com/vadimcn/vscode-lldb/releases/download/v${version}/codelldb-aarch64-linux.vsix

    vsix=${name}-linux-x64-${version}.vsix
    echo -e "vsix: \033[1;36m${vsix}\033[0m"
    curl_no_clobber "${dl_dir}/${vsix}" https://github.com/vadimcn/vscode-lldb/releases/download/v${version}/codelldb-x86_64-linux.vsix


else
    # construct the vsix filename
    vsix=$(cat ${json_file} | jq --argjson vi ${version_index} -r \
        '.results[].extensions[] | (.publisher.publisherName+"."+ .extensionName+ "-"+.versions[$vi].version+".vsix")')
    echo -e "vsix: \033[1;36m${vsix}\033[0m"

    # extract the uri from the JSON
    assetUri=$(cat ${json_file} | jq --argjson vi ${version_index} -r \
        '.results[].extensions[].versions[$vi].assetUri')

    # download the .vsix (e.g. the archive of the extension)
    curl_no_clobber "${dl_dir}/${vsix}" "$assetUri/Microsoft.VisualStudio.Services.VSIXPackage"
fi
