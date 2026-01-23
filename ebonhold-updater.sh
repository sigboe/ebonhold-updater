#!/usr/bin/env bash


: "${debug:=false}"
manifest_api="https://api.project-ebonhold.com/api/launcher/games"
file_url_api="https://api.project-ebonhold.com/api/launcher/download?file_ids=" # append comma sepparate list of file ids
download_queue=()
manifest="$(curl -s "${manifest_api}")"
include_common=false

debug() {
    local msg="$*"
    if [[ "$debug" == true ]]; then
        # Color codes
        local RED="\033[0;31m"
        local GREEN="\033[0;32m"
        local YELLOW="\033[0;33m"
        local BLUE="\033[0;34m"
        local NC="\033[0m"  # No Color

        # Print [DEBUG]: in cyan, message in yellow
        echo -e "${BLUE}[DEBUG]:${NC} ${YELLOW}${msg}${NC}" >&2
    fi
}

filtered_args=()
for arg in "$@"; do
    if [[ "$arg" == "--debug" ]]; then
        debug=true
    elif [[ "$arg" == "--verify" ]]; then
        include_common=true
    else
        filtered_args+=("$arg")
    fi
done
set -- "${filtered_args[@]}"

# If Wow.exe is run as a non-steam app, and this script is launched using
# ./script %command%
# then this script will relaunch the command with this script inside the
# SteamLaunch wrapper so that Zenity will be displayed in GameScope
args=("$@")
for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "SteamLaunch" ]; then
        # Insert $0 at position i+3 (two after SteamLaunch)
        insert_pos=$((i + 3))
        new_args=("${args[@]:0:$insert_pos}" "$0" "${args[@]:$insert_pos}")
        exec "${new_args[@]}"
        exit
    fi
done


if [[ ! "${include_common}" == "true" ]] && [[ -x "$(command -v zenity)" ]]; then
    if [[ ! -f "Wow.exe" && ! -f "wow.exe" ]]; then
        if zenity --question \
            --title="Project Ebonhold Updater" \
            --text="Wow.exe not found in the current directory.\n\nDownload the full client?"; then
            include_common=true
        else
            zenity --info --title="Project Ebonhold Updater" --text="Aborting"
            exit 1
        fi
    fi
else
    if [[ ! -f "Wow.exe" && ! -f "wow.exe" ]]; then
        read -p "Wow.exe not found in the current directory. Download full client? [y/N]: " response
        case "$response" in
            [yY]|[yY][eE][sS]) 
                include_common=true
                ;;
            *)
                if [[ -x "$(command -v zenity)" ]]; then
                    zenity --info --text="Aborting"
                else
                    echo "Aborting"
                fi
                exit 1
                ;;
        esac
    fi
fi

if ${include_common}; then
    debug "Verifying and downloading all files"
    game_files=$(jq -cM '[.data.common.files[], .data.games[1].files[]]' <<< "$manifest")
else
    debug "Verifying and downloading only update files"
    game_files=$(jq -cM '.data.games[1].files' <<< "$manifest")
fi

file_count="$(jq 'length' <<< "${game_files}")"
count=0

if (( file_count > 0 )); then
    while read -r file; do
        count=$((++count))
        percentage=$((count * 100 / file_count))
        echo "${percentage}"
        id=$(jq -r '.id' <<<"$file")
        path=$(jq -r '.file_path_from_game_root' <<<"$file")
        echo "#${path}"
        debug "${path}"
        expected_md5=$(jq -r '.file_hash' <<<"$file" | base64 --decode | xxd -p)
        debug "Expected md5sum: ${expected_md5}"
        url="$(curl -s "${file_url_api}${id}" | jq --raw-output '.files|.[]|.url')"

        if [[ ! -f "$path" ]]; then
            debug "File not found, downloading"
            mkdir -p "$(dirname "${path}")"
            curl -fL ${url} -o "${path}"
            continue
        fi

        local_md5=$(md5sum "$path" | awk '{print $1}')
        debug "Local md5sum: ${local_md5}"

        if [[ "$local_md5" != "$expected_md5" ]]; then
            debug "File does not match, downloading"
            mkdir -p "$(dirname ${path})"
            curl -fL ${url} -o "${path}"
        fi
    done < <(jq -cM '.[]' <<< "${game_files}") | zenity --progress --title "Project Ebonhold Updater" --percentage=0 --auto-close
fi

if [ $# -gt 0 ]; then
    exec "$@"
fi
