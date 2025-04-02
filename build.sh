#!/bin/bash
set -e # Exit on error

TAG="beta"
INSTALL=false          # Default: No installation
HASH_FILE=".dynv_hash" # File to store last build hash

# Root Check Function
check_root() {
	local message="$1"

	if su -c "echo" >/dev/null 2>&1; then
		return 1 # Not root
	elif [ "$EUID" -ne 0 ]; then
		echo "$message"
		exit 1
	fi
}

# Validate Arguments
validate_args() {
	for arg in "$@"; do
		if [[ ! "$arg" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
			echo "> Error: Arguments must be numeric"
			exit 1
		fi
	done
}

# Read version from module.prop
read_version_info() {
	grep -Eo 'version=v[0-9.]+' module.prop | cut -d'=' -f2 | sed 's/v//'
}

# Read versionCode from module.prop
read_version_code() {
	grep -Eo 'versionCode=[0-9]+' module.prop | cut -d'=' -f2
}

# Get latest package matching fogimp*
get_latest_fogimp_pkg() {
	ls -tr packages/fogimp* 2>/dev/null | tail -n1
}

# Update JSON configuration
update_json() {
	local file="$1"
	local versionCode="${2:-$versionCode}"
	local version="${3:-$version}"
	local zipUrl="${4:-https://github.com/lululoid/LMKD-PSI-Activator/releases/download/v${version}_$versionCode/fmiop-v${version}_${versionCode}-$TAG.zip}"
	local changelog="${5:-https://github.com/lululoid/LMKD-PSI-Activator/releases/download/v${version}_${versionCode}/fmiop-v${version}_${versionCode}-changelog.md}"

	jq --arg code "$versionCode" \
		--arg ver "$version" \
		--arg zip "$zipUrl" \
		--arg log "$changelog" \
		'.versionCode = $code | .version = $ver | .zipUrl = $zip | .changelog = $log' "$file" | sponge "$file"
}

# Check if dynv.cpp has changed
should_rebuild_dynv() {
	local new_hash
	new_hash=$(sha256sum dynv.cpp 2>/dev/null | awk '{print $1}')

	if [[ -f "$HASH_FILE" ]]; then
		local old_hash
		old_hash=$(cat "$HASH_FILE")

		if [[ "$new_hash" == "$old_hash" ]]; then
			echo "- No changes detected in dynv.cpp, skipping rebuild."
			return 1 # No rebuild needed
		fi
	fi

	echo "$new_hash" >"$HASH_FILE"
	return 0 # Rebuild needed
}

# Generate Changelog from Git and remove old ones
generate_changelog() {
	local version="$1"
	local versionCode="$2"
	local changelog_file="fmiop-v${version}_${versionCode}-changelog.md"
	local message="
📣 For more updates and discussions about bugs, features, etc.,
join our Telegram channel: [Initechzer0](https://t.me/initentangtech)"

	# Remove previous changelogs
	rm -f fmiop-v*-changelog.md
	echo "- Removed old changelogs"

	echo "# Changelog for v${version} (Build ${versionCode})" >"$changelog_file"
	echo "$message" >>"$changelog_file"
	echo "" >>"$changelog_file"

	# Get last version commit hash
	local last_version_commit
	last_version_commit=$(git log --grep="version=v" --pretty=format:"%H" -n 1)

	if [[ -n "$last_version_commit" ]]; then
		git log --pretty=format:"- %s (%h)" --date=short "$last_version_commit"..HEAD >>"$changelog_file"
	else
		git log --pretty=format:"- %s (%h)" --date=short >>"$changelog_file"
	fi

	echo "" >>"$changelog_file"
	echo "- Auto-generated from Git commits" >>"$changelog_file"

	echo "- Changelog generated: $changelog_file"
}

# Parse arguments
while getopts ":i" opt; do
	case "$opt" in
	i) INSTALL=true ;; # Enable installation
	*)
		echo "Usage: $0 [-i] <version> <versionCode>"
		exit 1
		;;
	esac
done
shift $((OPTIND - 1))

# Main Execution
main() {
	local version="${1:-$(read_version_info)}"
	local versionCode="${2:-$(($(read_version_code) + 1))}"

	validate_args "$version" "$versionCode"

	# Update module.prop
	sed -i -E "s/^version=v[0-9.]+/version=v$version/; s/^versionCode=[0-9]+/versionCode=$versionCode/" module.prop

	local module_name
	module_name=$(grep -Eo '^id=.*' module.prop | cut -d'=' -f2)
	local fogimp_pkg
	fogimp_pkg=$(get_latest_fogimp_pkg)

	update_json update_config.json "$versionCode" "$version"

	# Generate Changelog
	generate_changelog "$version" "$versionCode"

	# Check if dynv.cpp changed before rebuilding
	if should_rebuild_dynv; then
		echo "- Building dynamic virtual memory..."
		g++ -o system/bin/dynv dynv.cpp -std=c++17 -pthread \
			./libyaml-cpp.a -static-libgcc -static-libstdc++ \
			-L"$PREFIX"/aarch64-linux-android/lib -llog
	fi

	local package_name="packages/${module_name}-v${version}_${versionCode}-$TAG.zip"

	echo "- Creating zip package: $package_name"
	7za a "$package_name" \
		META-INF fmiop.sh customize.sh module.prop "*service.sh" \
		uninstall.sh action.sh config.yaml \
		system/bin tools "$fogimp_pkg" "fmiop-v${version}_${versionCode}-changelog.md"

	if $INSTALL; then
		check_root "You need ROOT to install this module" || su -c "magisk --install-module $package_name"
	else
		echo "- Skipping installation. Package built at: $package_name"
	fi
}

# Run the script
main "$@"
