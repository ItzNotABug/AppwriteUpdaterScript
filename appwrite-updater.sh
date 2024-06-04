#!/bin/bash

# disable suppression
# shellcheck disable=SC2086
# shellcheck disable=SC2034
# shellcheck disable=SC2206

NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PINK='\033[38;5;213m'

# Function to compare two semantic version strings
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

# Declare versions that require migration.
VERSIONS_THAT_REQUIRE_MIGRATION=("1.3.0" "1.3.4" "1.3.8" "1.4.0" "1.4.2" "1.4.14" "1.5.1", "1.5.5")

# Check if Docker is running
if ! docker info &>/dev/null; then
    echo -e "${RED}Error: The Docker daemon is not running. Please start Docker before proceeding."
    echo -e "If you're using Docker Desktop, ensure it's open and running.${NC}"
    echo ""
    exit 1
fi

# Check if `jq` is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ Error: 'jq' is not installed. 'jq' is required for processing JSON data.${NC}"
    echo -e "Please install 'jq' following these instructions: ${GREEN}https://stedolan.github.io/jq/download/${NC}"
    echo ""
    exit 1
fi

# Check if appwrite is installed
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
unset IFS

echo -e "Available versions for update:"
for version in "${versions_array[@]}"; do
    if [ "$(printf '%s\n' "$version" "$current_version" | sort -V | head -n1)" = "$current_version" ] && [ "$version" != "$current_version" ]; then
        requires_migration="false"

        for migration_version in "${VERSIONS_THAT_REQUIRE_MIGRATION[@]}"; do
          if [[ "$version" == "$migration_version" ]]; then
            requires_migration="true"
          fi
        done

        if [[ "$requires_migration" == "true" ]]; then
          echo -e "${GREEN}➤ $version${NC} (${YELLOW}Migration required${NC})"
        else
          echo -e "${GREEN}➤ $version${NC}"
        fi
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


optimized_versions=()

for version in "${versions_array[@]}"; do
    compare_versions "$version" "$current_version"
    result_with_current=$?

    compare_versions "$version" "$latest_version"
    result_with_latest=$?

    if [[ "$version" == "$selected_version" ]]; then
        optimized_versions+=("$version")
    fi

    if [[ $result_with_current -eq 1 && ( $result_with_latest -eq 2 || $result_with_latest -eq 0 ) ]]; then
        for migration_version in "${VERSIONS_THAT_REQUIRE_MIGRATION[@]}"; do
            if [[ "$version" == "$migration_version" ]]; then
                optimized_versions+=("$version")
                break
            fi
        done
    fi

done


# Reverse the order of optimized_versions in place
for ((i=0; i<${#optimized_versions[@]} / 2; i++)); do
    temp="${optimized_versions[$i]}"
    optimized_versions[$i]="${optimized_versions[${#optimized_versions[@]} - 1 - $i]}"
    optimized_versions[${#optimized_versions[@]} - 1 - $i]="$temp"
done

echo -e "${GREEN}Preparing Update${NC}"
echo ""

previous_version=$current_version

for version in "${optimized_versions[@]}"; do
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
        echo -e "  └── Image successfully installed."

        for migration_version in "${VERSIONS_THAT_REQUIRE_MIGRATION[@]}"; do
            if [[ "$version" == "$migration_version" ]]; then
                echo "  └── Migration is required for version: $version."
                echo "  └── Attempting migration..."
                cd appwrite/ && docker compose exec appwrite migrate > /dev/null 2>&1 && cd ../
                echo "  └── Migration completed successfully."
            fi
        done

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
        cd appwrite/ && docker compose restart > /dev/null 2>&1 && cd ../
        echo "Appwrite restarted successfully!"
        echo ""

        break
    fi

    echo ""

done
