#!/bin/bash

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
if [ -z "$version" ]; then
    version=$(grep -o 'version=v[0-9.]*' module.prop | cut -d'=' -f2 | sed 's/v//')
fi

if [ -z "$versionCode" ]; then
    versionCode=$(grep versionCode module.prop | cut -d '=' -f2)
    versionCode=$((versionCode + 1))
fi

# Update module.prop with the new version and versionCode
sed -i "s/\(^version=v\)[0-9.]*\(.*\)/\1$version\2/; s/\(^versionCode=\)[0-9]*/\1$versionCode/" module.prop

# Extract module name
module_name=$(sed -n 's/^id=\(.*\)/\1/p' module.prop)

# Create a zip package
7za a "packages/$module_name-v${version}_$versionCode-beta.zip" \
    META-INF \
    fmiop* \
    customize.sh \
    module.prop \
    service.sh \
    cleaner.zip
