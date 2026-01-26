#!/usr/bin/env bash

: "${debug:=false}"
: "${game:=roguelike-prod}"
scriptdir="$(dirname "$(readlink -f "${0}")")"
login_api="https://api.project-ebonhold.com/api/auth/login"
manifest_api="https://api.project-ebonhold.com/api/launcher/games"
file_url_api="https://api.project-ebonhold.com/api/launcher/download?file_ids=" # append comma sepparate list of file ids
token_file="${scriptdir}/.updaterToken"
[[ -f "${token_file}" ]] && authToken=$(<"${token_file}")
download_queue=()
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
        debug "Debug messages enabled"
    elif [[ "$arg" == "--verify" ]]; then
        include_common=true
    elif [[ "$arg" == --game=* ]]; then
        game="${arg#--game=}"
        debug "Game set to: ${game}"
    elif [[ "$arg" == --mods=* ]]; then
        option_slugs="${arg#--mods=}"
        debug "Also downloading mods: ${option_slugs}"
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
        debug "Steam detected, relaunching with gamescope integration"
        insert_pos=$((i + 3))
        new_args=("${args[@]:0:$insert_pos}" "$0" "${args[@]:$insert_pos}")
        exec "${new_args[@]}"
        exit
    fi
done

if [[ -n "${authToken}" ]]; then
    debug "Auth token found"
    manifest=$(curl -s -H "Authorization: Bearer ${authToken}" "${manifest_api}")
    if ! jq -e '.success' <<< "${manifest}" >/dev/null 2>&1; then
        debug "Token invalid, need login"
        unset authToken manifest
    else
        debug "Token works, manifest fetched"
    fi
fi

if [[ -z "${manifest}" ]]; then
    if [[ -x "$(command -v zenity)" ]]; then
            USERNAME=$(zenity --entry --title="Ebonhold Login" --text="Enter your username:" --width=400 2>/dev/null)
            [[ -z "${USERNAME}" ]] && exit 1
            PASSWORD=$(zenity --password --title="Password for $USERNAME" --width=400 2>/dev/null)
            [[ -z "${PASSWORD}" ]] && exit 1
    else
            echo "Project Ebonhold requires you to be logged in to update."
            read -p "Username:" USERNAME
            [[ -z "${USERNAME}" ]] && exit 1
            read -p "Password: " -s PASSWORD
            [[ -z "${PASSWORD}" ]] && exit 1
            echo
    fi

    session="$( curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" \
        "${login_api}")"
    if ! jq -e '.success' <<< "${session}" >/dev/null 2>&1; then
        message="$(jq -r '.message' <<< "${session}")"
        debug "session invalid"
        debug "${message}"
        debug "exiting"
        exit 1
    else
        debug "session works, fetching manifest"
        authToken="$(jq -r '.token' <<< "${session}" )"
        echo "${authToken}" > "${token_file}"
        debug "Auth token stored"
        manifest="$(curl -s -H "Authorization: Bearer ${authToken}" "${manifest_api}")"
    fi
fi

if [[ ! "${include_common}" == "true" ]] && [[ -x "$(command -v zenity)" ]]; then
    if [[ ! -f "Wow.exe" && ! -f "wow.exe" ]]; then
        if zenity --question --width=400 \
            --title="Project Ebonhold Updater" \
            --text="Wow.exe not found in the current directory.\n\nDownload the full client?"; then
            include_common=true 2>/dev/null
        else
            zenity --info --title="Project Ebonhold Updater" --text="Aborting" --width=400 2>/dev/null
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
                    zenity --info --text="Aborting" --width=400 2>/dev/null
                else
                    echo "Aborting"
                fi
                exit 1
                ;;
        esac
    fi
fi

game_index=$(jq -r --arg slug "$game" '
  [ .data.games[] | .slug ] | index($slug)
' <<< "$manifest")
debug "${game} has index ${game_index}"
if [ -z "$game_index" ]; then
  debug "Error: game '$game' not found in manifest"
  exit 1
fi

if [[ "$include_common" == true ]]; then
    debug "Verifying and downloading all files"
    game_files=$(jq -cM --arg i "$game_index" '
        (.data.common.files[]?, .data.games[($i|tonumber)].files[]?) | select(.option_slug? == null)
    ' <<< "$manifest")
else
    debug "Verifying and downloading only update files"
    game_files=$(jq -cM --arg i "$game_index" '
        .data.games[($i|tonumber)].files[]? | select(.option_slug? == null)
    ' <<< "$manifest")
fi

mod_files=$(jq -cM --arg slugs "${option_slugs:-}" --arg i "$game_index" '
  ($slugs | split(",") | map(select(length > 0))) as $allowed
  |
  if ($allowed | length) == 0 then
    empty
  else
    (.data.common.files[]?, .data.games[($i|tonumber)].files[]?)
    | select(.option_slug? as $s | $s != null and ($allowed | index($s)))
  end
' <<< "$manifest")

game_files=$(printf "%s\n%s\n" "$mod_files" "$game_files" | grep -v '^$')

file_count="$(wc -l <<< "${game_files}")"
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
        url="$(curl -s -H "Authorization: Bearer ${authToken}" "${file_url_api}${id}" | jq --raw-output '.files|.[]|.url')"

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
    done <<< "${game_files}" | zenity --progress --title "Project Ebonhold Updater" --percentage=0 --auto-close --width=400 2>/dev/null
fi

if [ $# -gt 0 ]; then
    exec "$@"
fi
