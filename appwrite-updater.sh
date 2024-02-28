#!/bin/bash

# disable suppression
# shellcheck disable=SC2086
# shellcheck disable=SC2206

NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
PINK='\033[38;5;213m'

compare_versions() {
    IFS='.' read -ra VER1 <<< "$1"
    IFS='.' read -ra VER2 <<< "$2"
    # Compare each part of the version
    for ((i=0; i<${#VER1[@]} || i<${#VER2[@]}; i++)); do
        # Default to 0 if index is not set
        local num1=${VER1[i]:-0}
        local num2=${VER2[i]:-0}

        if ((num1 > num2)); then
            return 1  # $1 is greater than $2
        elif ((num1 < num2)); then
            return 2  # $1 is less than $2
        fi
    done
    return 0  # $1 is equal to $2
}

echo -e "${PINK}"
echo "   _                        _ _         _   _          _      _           _ ";
echo "  /_\  _ __ _ ____ __ ___ _(_) |_ ___  | | | |_ __  __| |__ _| |_ ___ _ _| |";
echo " / _ \| '_ \ '_ \ V  V / '_| |  _/ -_) | |_| | '_ \/ _\` / _\` |  _/ -_) '_|_|";
echo "/_/ \_\ .__/ .__/\_/\_/|_| |_|\__\___|  \___/| .__/\__,_\__,_|\__\___|_| (_)";
echo "      |_|  |_|                               |_|                            ";
echo -e "${NC}"

echo ""
echo -e "Update & Migrate Appwrite Installations easily!"
echo ""

# Check if Docker daemon is running
if ! docker info &>/dev/null; then
    echo -e "${RED}Error: The Docker daemon is not running. Please start Docker before proceeding."
    echo -e "If you're using Docker Desktop, ensure it's open and running.${NC}"
    echo ""
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ Error: 'jq' is not installed. 'jq' is required for processing JSON data.${NC}"
    echo -e "Please install 'jq' following these instructions: ${GREEN}https://stedolan.github.io/jq/download/${NC}"
    echo ""
    exit 1
fi

# Check prerequisites: Appwrite installation and jq
if [ ! -f "./appwrite/docker-compose.yml" ]; then
    echo -e "${RED}❌ Appwrite directory not detected in the current directory.${NC}"
    echo ""
    exit 1
fi

# Extract the current Appwrite version
current_version=$(sed -n 's/.*appwrite\/appwrite:\([^ ]*\).*/\1/p' ./appwrite/docker-compose.yml | head -n 1)

# Fetch the latest Appwrite version from GitHub releases
latest_version=$(curl -s "https://api.github.com/repos/appwrite/appwrite/releases" | jq -r '.[] | select(.prerelease == false and .draft == false) | .tag_name' | sort -Vr | head -1)

if [[ "$current_version" == "$latest_version" ]]; then
    echo -e "${GREEN}Already on the latest version.${NC}"
    echo ""
    exit 1
fi

echo -e "Detected current Appwrite version: ${PINK}$current_version${NC}"
echo -e "Latest available Appwrite version: ${GREEN}$latest_version${NC}"
echo ""

# Generate a sorted list of versions from GitHub releases
versions=$(curl -s "https://api.github.com/repos/appwrite/appwrite/releases" | \
           jq -r '.[] | select(.prerelease == false and .draft == false) | .tag_name' | \
           sort -Vr)

IFS=$'\n' versions_array=($versions)

# Reverse the order of versions_array in place
for ((i=0; i<${#versions_array[@]} / 2; i++)); do
    temp="${versions_array[$i]}"
    versions_array[$i]="${versions_array[${#versions_array[@]} - 1 - $i]}"
    versions_array[${#versions_array[@]} - 1 - $i]="$temp"
done

echo -e "Available versions for update:"
for version in "${versions_array[@]}"; do
    if [ "$(printf '%s\n' "$version" "$current_version" | sort -V | head -n1)" = "$current_version" ] && [ "$version" != "$current_version" ]; then
        echo -e "  - ${GREEN}$version${NC}"
    fi
done

echo ""

# Prompt for the version to update to
echo "Enter the version you want to update to (default: $latest_version): "
read -r selected_version

if [ -z "$selected_version" ]; then
    selected_version=$latest_version
    echo -e "No version entered. Defaulting to latest version: ${GREEN}$selected_version${NC}."
fi

version_found=false
for version in "${versions_array[@]}"; do
    if [[ "$version" == "$selected_version" ]]; then
        version_found=true
        break
    fi
done

echo ""
if ! $version_found; then
    echo -e "${RED}Error: Selected version $selected_version is not available for update. Exiting.${NC}"
    exit 1
fi

echo -e "${GREEN}Preparing Update${NC}"
echo ""

previous_version=$current_version

for version in "${versions_array[@]}"; do
    compare_versions "$version" "$current_version"
    comparison_result=$?

    # Skip if current version is greater than or equal to the version
    if [[ $comparison_result -eq 0 ]] || [[ $comparison_result -eq 2 ]]; then
        continue
    fi

    echo -e "${GREEN}##################################################${NC}"
    echo -e "  └── Pulling image: $version..."

    if echo Y | docker run -i --rm \
        --volume /var/run/docker.sock:/var/run/docker.sock \
        --volume "$(pwd)/appwrite:/usr/src/code/appwrite:rw" \
        --entrypoint="upgrade" \
        appwrite/appwrite:$version > /dev/null 2>&1; then
        echo -e "  └── Image successfully pulled."

        echo -e "  └── Attempting version change migration..."
        (cd appwrite/ && docker compose exec appwrite migrate > /dev/null 2>&1)
        echo -e "  └── Migration completed successfully."

        # remove previous version image
        echo -e "  └── Removing old image ($previous_version)"
        docker rmi appwrite/appwrite:$previous_version > /dev/null 2>&1
        echo -e "  └── Unused appwrite image removed!"
    else
        echo -e "${RED}Upgrade to $version failed.${NC}"
        echo ""
        break
    fi

    previous_version=$version

    # Stop if we've reached the selected version
    if [[ "$version" == "$selected_version" ]]; then
        echo -e "${GREEN}##################################################${NC}"
        echo ""
        echo -e "${GREEN}Reached target version $selected_version.${NC}"
        echo ""
        echo "Restarting appwrite instance..."
        (cd appwrite/ && docker compose restart > /dev/null 2>&1)
        echo "Appwrite restarted successfully!"
        echo ""

        break
    fi

    echo ""

done