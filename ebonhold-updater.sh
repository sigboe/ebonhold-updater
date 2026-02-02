#!/usr/bin/env bash

: "${debug:=false}"
: "${game:=roguelike-prod}"
scriptdir="$(dirname "$(readlink -f "${0}")")"
login_api="https://api.project-ebonhold.com/api/auth/login"
manifest_api="https://api.project-ebonhold.com/api/launcher/games"
file_url_api="https://api.project-ebonhold.com/api/launcher/download?file_ids=" # append comma sepparate list of file ids
token_file="${scriptdir}/.updaterToken"
[[ -f "${token_file}" ]] && authToken="$(<"${token_file}")"
if [[ -t 0 ]]; then interactiveShell="true"; else interactiveShell="false"; fi
if    [[ "$XDG_SESSION_TYPE" = "x11" ]] \
   || [[ "$XDG_SESSION_TYPE" = "wayland" ]] \
   || [[ -n "$DISPLAY" ]] \
   || [[ -n "$WAYLAND_DISPLAY" ]]
then
        GUI="${GUI:=true}"
else
        GUI="false"
fi
[[ -x "$(command -v zenity)" ]] || GUI="false"
[[ "${GUI}" == "false" ]] && [[ "${interactiveShell}" == "false" ]] && exit 1
include_common="false"

debug() {
    local msg="${*}"
    if [[ "${debug}" == "true" ]]; then
        # Color codes
        local BLUE="\033[0;34m"
        local YELLOW="\033[0;33m"
        local NC="\033[0m"  # No Color

        # Print [DEBUG]: in cyan, message in yellow
        echo -e "${BLUE}[DEBUG]:${NC} ${YELLOW}${msg}${NC}" >&2
    fi
}

error() {
    local exit_code="0"
    local msg

    # Check if first argument is a number (exit code)
    if [[ "${1}" =~ ^[0-9]+$ ]]; then
        exit_code="${1}"
        shift
    fi

    msg="${*}"

    # Color codes
    local RED="\033[0;31m"
    local YELLOW="\033[0;33m"
    local NC="\033[0m"

    if [[ "${GUI}" == "true" ]]; then
        zenity --error \
            --title="Error" \
            --text="${msg}" \
            --width=400 2>/dev/null
    else
        echo -e "\n\033[2K${RED}[ERROR]:${NC} ${YELLOW}${msg}${NC}" >&2
    fi

    [[ "${exit_code}" -ge "1" ]] && exit "${exit_code}"
}


# This function is here to easily support GUI via zenity
# or text based output more easilty
progress() {
    local title="${1}"
    local bar_width="40"
    local text=""
    local percent="0"

    if [[ "${GUI}" == "true" ]]; then
        zenity --progress \
            --title="${title}" \
            --percentage=0 \
            --auto-close \
            --width=400 2>/dev/null
        return
    fi

    # Terminal fallback
    printf "%s\n\n" "${title}"
    while IFS= read -r line; do
        if [[ "${line}" =~ ^# ]]; then
            text="${line#\#}"
        elif [[ "${line}" =~ ^[0-9]+$ ]]; then
            percent="${line}"
        else
            continue
        fi

        filled="$(( percent * bar_width / 100 ))"
        empty="$(( bar_width - filled ))"

        if [[ "${debug}" == "true" ]]; then
            debug "Progress: ${percent}%"
        else
            printf "\r\033[2K%s\n [" "${text}"
            printf "%0.s#" $(seq 1 ${filled})
            printf "%0.s-" $(seq 1 ${empty})
            printf "] %3d%%\033[K" "${percent}"
        fi
    done

    echo
}

prompt_text() {
    local title="${1}"
    local text="${2}"

    if [[ "${GUI}" == "true" ]]; then
        zenity --entry \
            --title="${title}" \
            --text="${text}" \
            --width=400 2>/dev/null || return 1
    else
        local input
        echo "${title}" >&2
        read -r -p "${text} > " input
        [[ -z "${input}" ]] && return 1
        echo -n "${input}"
    fi
}

prompt_password() {
    local title="${1}"
    local text="${2}"

    if [[ "${GUI}" == "true" ]]; then
        zenity --password \
            --title="${title}" \
            --text="${text}" \
            --width=400 2>/dev/null
    else
        local input
        echo "${title}" >&2
        read -r -s -p "Password: >" input
        [[ -z "${input}" ]] && return 1
        echo -n "${input}"
    fi
}

prompt_yes_no() {
    local title="${1}"
    local text="${2}"

    if [[ "${GUI}" == "true" ]]; then
        zenity --question \
            --title="${title}" \
            --text="${text}" \
            --width=400 2>/dev/null
        return "${?}"
    else
        while true; do
            [[ -n "${title}" ]] && echo "${title}"
            read -r -p "${text} [y/N]: " answer
            case "${answer}" in
                [yY]|[yY][eE][sS]) return 0 ;;
                [nN]|[nN][oO]|"") return 1 ;;
                *) echo "Please answer yes or no." ;;
            esac
        done
    fi
}

notify() {
    local title="${1}"
    local text="${2}"

    if [[ "${GUI}" == "true" ]]; then
        zenity --info \
            --title="${title}" \
            --text="${text}" \
            --width=400 2>/dev/null
    else
        echo
        echo "=== ${title} ==="
        echo "${text}"
        echo
        read -r -p "Press Enter to continue..." _
    fi
}


# downloads a new line separated list of json objects
# usage: downloadFiles "${game_files}"
downloadFiles() {
    local file_count total_bytes file_size bytes_done percentage id path expected_md5 local_md5 download response retry_after url
    local game_files="${1}"

    [[ -z "${game_files}" ]] && return

    file_count="$(wc -l <<< "${game_files}")"

    total_bytes="0"
    while read -r file; do
        file_size="$(jq -r '.file_size_bytes' <<<"${file}")"
        total_bytes="$(( total_bytes + file_size ))"
    done <<< "${game_files}"
    bytes_done="0"

    if (( file_count > 0 )); then
        while read -r file; do
            file_size="$(jq -r '.file_size_bytes' <<<"${file}")"
            echo "${percentage}"
            bytes_done="$((bytes_done + file_size))"
            percentage="$(( bytes_done * 100 / total_bytes ))"
            id="$(jq -r '.id' <<<"${file}")"
            path="$(jq -r '.file_path_from_game_root' <<<"${file}")"
            echo "#${path}"
            debug "File ID: ${id} File: ${path}"
            expected_md5="$(jq -r '.file_hash' <<<"${file}" | base64 --decode | od -An -tx1 | tr -d ' \n')"
            debug "Expected md5sum: ${expected_md5}"

            download="false"
            if [[ ! -f "${scriptdir}/${path}" ]]; then
                debug "File not found, downloading"
                download="true"
            else
                local_md5="$(md5sum "${scriptdir}/${path}" | cut -d' ' -f1)"
                debug "Local md5sum: ${local_md5}"

                if [[ "${local_md5}" != "${expected_md5}" ]]; then
                    debug "File does not match, downloading"
                    download="true"
                fi
            fi

            if [[ "${download}" == "true" ]]; then
                mkdir -p "$(dirname "${scriptdir}/${path}")"
                response="$(curl -s -H "Authorization: Bearer ${authToken}" "${file_url_api}${id}")"
                retry_after="$(jq -r '.retry_after_minutes // 0' <<<"$response")"
                [[ "${retry_after}" -gt 0 ]] && error 1 "Rate limit hit for file ${path}\nPlease wait ${retry_after} minutes"
                url="$(jq --raw-output '.files|.[]|.url' <<< "${response}")"
                curl -fL "${url}" -o "${scriptdir}/${path}"
                [[ -d "${scriptdir}/Cache" ]] && touch "${scriptdir}/Cache/invalid"
            fi
        done <<< "${game_files}" | progress "Project Ebonhold Updater"
    fi
}

# DELETES! files, described by a new line separated list of json objects
# use to remove mods or removing files before switching game modes
# usage: deleteFiles "${game_files}"
deleteFiles() {
    local file_count id path resolvedpath
    local game_files="${1}"
    local invalidCache="false"

    [[ -z "${game_files}" ]] && return
    while read -r file; do
        id="$(jq -er '.id' <<<"${file}")" || continue
        path="$(jq -er '.file_path_from_game_root' <<<"${file}")" || continue
        path="${path//$'\r'/}"
        debug "File ID: ${id} File: ${path}"

        resolvedpath="$(realpath -m "${scriptdir}/${path}")"
        if [[ "${resolvedpath}" != "${scriptdir}/"* ]]; then
            debug "Skipping unsafe path: ${resolvedpath}"
            continue
        fi

        if [[ -f "${scriptdir}/${path}" ]]; then
            debug "File found, deleting"
            builtin rm -- "${scriptdir}/${path}"
            invalidCache="true"
        fi
    done <<< "${game_files}"
    [[ "${invalidCache}" == "true" && -d "${scriptdir}/Cache" ]] && touch "${scriptdir}/Cache/invalid"
}

# This does clear the cache if there is any cache
# to clear only when we think the cache is invalid then call the function like so:
# [[ -f "${scriptdir}/Cache/invalid" ]] && clearCache
clearCache() {
    local deleted
    if [[ -d "${scriptdir}/Cache" ]] && deleted="$(find "${scriptdir:?scriptdir is not set}/Cache" -iname '*.wdb' -type f -print -delete)"; then
        rm "${scriptdir}/Cache/invalid"
        [[ -n "${deleted}" ]] && debug "Update fetched, cleared cache\n${deleted}"
    fi
}

filtered_args=()
for arg in "${@}"; do
    if [[ "${arg}" == "--debug" ]]; then
        debug="true"
        debug "Debug messages enabled"
    elif [[ "${arg}" == "--verify" ]]; then
        include_common="true"
    elif [[ "${arg}" == --game=* ]]; then
        game="${arg#--game=}"
        debug "Game set to: ${game}"
    elif [[ "${arg}" == --mods=* ]]; then
        option_slugs="${arg#--mods=}"
        debug "Also downloading mods: ${option_slugs}"
    else
        filtered_args+=("${arg}")
    fi
done
set -- "${filtered_args[@]}"

# The game supports loging in via -login and -password
# If ebonhold-updater is ran as a wrapper (exmaple in steam, see readme)
# we can just capture the username and password and use it for the
# authentication that updating requires, if there is no credentials
# we just ask the user later if the authToken has expired
for ((i=1; i <= ${#}; i++)); do
    arg="${!i}"
    next="$((i + 1))"
    case "${arg}" in
        -login) [[ ${next} -le ${#} ]] && ebonhold_user="${!next}" ;;
        -password) [[ ${next} -le ${#} ]] && ebonhold_password="${!next}" ;;
    esac
done
[[ -n "${ebonhold_user}" ]] && [[ -n "${ebonhold_password}" ]] && debug "fetched credentials from launch arguments"

# If Wow.exe is run as a non-steam app, and this script is launched using
# ./script %command%
# then this script will relaunch the command with this script inside the
# SteamLaunch wrapper so that Zenity will be displayed in GameScope
args=("${@}")
for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "SteamLaunch" ]; then
        # Insert $0 at position i+3 (two after SteamLaunch)
        debug "Steam detected, relaunching with gamescope integration"
        insert_pos="$((i + 3))"
        new_args=("${args[@]:0:$insert_pos}" "${0}" "${args[@]:$insert_pos}")
        exec "${new_args[@]}"
        exit
    fi
done

if [[ -n "${authToken}" ]]; then
    debug "Auth token found"
    manifest="$(curl -s -H "Authorization: Bearer ${authToken}" "${manifest_api}")"
    if ! jq -e '.success' <<< "${manifest}" >/dev/null 2>&1; then
        debug "Token invalid, asking user to login"
        unset authToken manifest
    else
        debug "Token works, manifest fetched"
    fi
fi

if [[ -z "${manifest}" ]]; then
    [[ -z "${ebonhold_user}" ]] && { ebonhold_user="$(prompt_text "Ebonhold Login" "Enter your username:")" || exit 1; }
    [[ -z "${ebonhold_password}" ]] && { ebonhold_password="$(prompt_password "Ebonhold Login" "Password for ${ebonhold_user}")" || exit 1; }

    # open a session, and extract http_code
    session="$(curl -s -X POST -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${ebonhold_user}\",\"password\":\"${ebonhold_password}\",\"rememberMe\":true}" \
        "${login_api}")"
    http_code="$(tail -n1 <<< "${session}")"
    debug "HTTP return code ${http_code}"
    session="$(head -n-1 <<< "${session}")"
    if ! jq -e '.success' <<< "${session}" >/dev/null 2>&1; then
        message="$(jq -r '.message' <<< "${session}")"
        [[ -z "${message}" ]] && message="HTTP code: ${http_code}"
        error 1 "session invalid\n${message}\nExiting"
    else
        debug "session works, fetching manifest"
        authToken="$(jq -r '.token' <<< "${session}")"
        echo -n "${authToken}" > "${token_file}"
        debug "Auth token stored"
        manifest="$(curl -s -H "Authorization: Bearer ${authToken}" "${manifest_api}")"
    fi
fi

if [[ ! -n "$(find "${scriptdir}/" -maxdepth 1 -iname "wow.exe")" ]]; then
    if prompt_yes_no "Project Ebonhold Updater" "Wow.exe not found in the current directory.\n\nDownload the full client?"; then
        include_common="true"
    else
        notify "Project Ebonhold Updater" "Aborting"
        exit 1
    fi
fi

game_index="$(jq -r --arg slug "${game}" '
  [ .data.games[] | .slug ] | index($slug)
' <<< "${manifest}")"
debug "${game} has index ${game_index}"
if [ -z "${game_index}" ]; then
  error 1 "Error: game '${game}' not found in manifest"
fi

if [[ "${include_common}" == "true" ]]; then
    debug "Verifying and downloading all files"
    game_files="$(jq -cM --arg i "${game_index}" '
        (.data.common.files[]?, .data.games[($i|tonumber)].files[]?) | select(.option_slug? == null)
    ' <<< "${manifest}")"
else
    debug "Verifying and downloading only update files"
    game_files="$(jq -cM --arg i "${game_index}" '
        .data.games[($i|tonumber)].files[]? | select(.option_slug? == null)
    ' <<< "${manifest}")"
fi

if [[ -n "${option_slugs}" ]]; then
    debug "Looking for mods: ${option_slugs//,/ }"
    mod_files="$(jq -cM --arg slugs "${option_slugs:-}" --arg i "${game_index}" '
      ($slugs | split(",") | map(select(length > 0))) as $allowed
      |
      if ($allowed | length) == 0 then
        empty
      else
        (.data.common.files[]?, .data.games[($i|tonumber)].files[]?)
        | select(.option_slug? as $s | $s != null and ($allowed | index($s)))
      end
    ' <<< "${manifest}")"
    debug "Mods found and added to queue: $(while read -r mod; do
        jq -r '.option_slug' <<< "${mod}"
    done <<< "${mod_files}"  | sort -u | tr '\n' ' ')"
    game_files="$(printf "%s\n%s\n" "${mod_files}" "${game_files}" | grep -v '^$')"
fi

downloadFiles "${game_files}"

[[ -f "${scriptdir}/Cache/invalid" ]] && clearCache

if [ ${#} -gt 0 ]; then
    exec "${@}"
fi
