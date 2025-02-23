#!/bin/bash
check_root() {
	local message="$1"

	if su -c "echo"; then
		false
	elif [ "$EUID" -ne 0 ]; then
		echo "$message"
		exit 1
	fi
}

version=$1
versionCode=$2

# Check for decimal in arguments
for arg in "$@"; do
	if [[ $arg =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		true
	else
		echo "> Arguments must be number"
		exit 1
	fi
done

# Extract version information from module.prop
last_version=$(grep -o 'version=v[0-9.]*' module.prop |
	cut -d'=' -f2 | sed 's/v//')

if [ -z "$version" ]; then
	version=$(grep -o 'version=v[0-9.]*' module.prop |
		cut -d'=' -f2 | sed 's/v//')
fi

if [ -z "$versionCode" ]; then
	versionCode=$(grep versionCode module.prop | cut -d '=' -f2)
	versionCode=$((versionCode + 1))
fi

# Update module.prop with the new version and versionCode
sed -i "s/\(^version=v\)[0-9.]*\(.*\)/\1$version\2/; s/\(^versionCode=\)[0-9]*/\1$versionCode/" module.prop
sed -i "s/\(^version=v\)[0-9.]*\(.*\)/\1$version\2/; s/\(^versionCode=\)[0-9]*/\1$versionCode/" fmiop.sh

# Extract module name
module_name=$(sed -n 's/^id=\(.*\)/\1/p' module.prop)
fogimp_pkg=$(ls -tr packages/fogimp* | tail -n1)

# Create a zip package
package_name="packages/$module_name-v${version}_$versionCode-beta.zip"
7za a "$package_name" \
	META-INF \
	fmiop.sh \
	customize.sh \
	module.prop \
	cleaner.zip \
	./*service.sh \
	sed \
	yq \
	config.yaml \
	$fogimp_pkg

# check_root "You need ROOT to install this module" || su -c "magisk --install-module $package_name"
