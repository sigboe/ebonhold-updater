# Ebonhold Updater

A bash-based updater script for Project Ebonhold, a World of Warcraft custom server. The updater downloads and verifies game files by comparing MD5 hashes against a remote manifest.

![Screenshot](screenshot.png)

## Features

- **Automated File Verification**: Compares local file MD5 hashes against remote manifest
- **GUI Progress Tracking**: User-friendly progress dialogs using zenity
- **Steam Integration**: Seamlessly handles Steam launch arguments

## Prerequisites

The following system packages are required:
- `curl`
- `jq`
- `zenity`

*Note: `md5sum` and `stat` are also required but are usually pre-installed.*

## Installation

1. Place `ebonhold-updater.sh` in your World of Warcraft Wrath of the Litchking directory or the directory where you want to download World of Warcraft
2. Make the script executable:
   ```bash
   chmod +x ebonhold-updater.sh
   ```

## Usage

### Basic Usage

```bash
./epoch-updater.sh
```

### Steam Integration (Optional)

1. If you don't already have World of Warcraft Wrath of the Litchking installed, please run the ebonhold-updater.sh script one time first.
2. Add `Wow.exe` as a Non-Steam Game
3. Make sure "Start In" target in Steam is the folder that has `Wow.exe`, it should already be the correct value.
4. Set Force the Use of a Specific Steam Play Compatibility tool by: right clicking the game, Properties, Compatibility.
5. Add the following as a launch option

```
./ebonhold-updater.sh %command%
```

Technically, the script will detect it is running in Steam, and rewrite Steam's launch command so that the script is running inside the Steam Runtime, and inside gamescope (if in use). We need to do this so we are able to display the window with the progress bar on systems that use gamescope

## TODO

* Consider adding support for not downloading the HD patch when downloading or --verify the base client
* addign support for other game modes when they come, or ptr
