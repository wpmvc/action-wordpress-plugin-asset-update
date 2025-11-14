#!/bin/bash

# Note that this does not use pipefail because if the grep later
# doesn't match I want to be able to show an error first
set -eo

# Function to check if a command exists
command_exists() {
	command -v "$1" >/dev/null 2>&1
}

# Check if SVN is installed
if command_exists svn; then
	echo "SVN is already installed."
else
	echo "SVN is not installed. Installing SVN..."

	# Update the package list
	sudo apt-get update -y

	# Install SVN
	sudo apt-get install -y subversion

	# Verify installation
	if command_exists svn; then
		echo "SVN was successfully installed."
	else
		echo "Failed to install SVN. Please check your system configuration."
		exit 1
	fi
fi

# Ensure SVN username and password are set
# IMPORTANT: while secrets are encrypted and not viewable in the GitHub UI,
# they are by necessity provided as plaintext in the context of the Action,
# so do not echo or use debug mode unless you want your secrets exposed!
if [[ -z "$SVN_USERNAME" ]]; then
	echo "Set the SVN_USERNAME secret"
	exit 1
fi

if [[ -z "$SVN_PASSWORD" ]]; then
	echo "Set the SVN_PASSWORD secret"
	exit 1
fi

# Set up variables
SLUG=${SLUG:-${GITHUB_REPOSITORY#*/}}
ASSETS_DIR=${ASSETS_DIR:-.wordpress-org}
README_NAME=${README_NAME:-readme.txt}

echo "ℹ︎ SLUG is $SLUG"
echo "ℹ︎ ASSETS_DIR is $ASSETS_DIR"
echo "ℹ︎ README_NAME is $README_NAME"

SVN_URL="https://plugins.svn.wordpress.org/${SLUG}/"
SVN_DIR="${HOME}/svn-${SLUG}"

# Checkout SVN trunk and assets
echo "➤ Checking out WordPress.org repository..."
svn checkout --depth immediates "$SVN_URL" "$SVN_DIR"
cd "$SVN_DIR"
svn update --set-depth infinity assets
svn update --set-depth infinity trunk

# Extract Stable Tag from local readme.txt
LOCAL_STABLE_TAG=$(grep -m 1 -E "^([*+-]\s+)?Stable tag:" "$GITHUB_WORKSPACE/$README_NAME" | tr -d '\r\n' | awk -F ' ' '{print $NF}')
if [[ -z "$LOCAL_STABLE_TAG" ]]; then
    echo "ℹ︎ Stable tag not found in readme.txt. Exiting."
    exit 1
fi
echo "ℹ︎ Local Stable Tag: $LOCAL_STABLE_TAG"

# Extract Stable Tag from SVN trunk readme.txt
if [[ -f "trunk/$README_NAME" ]]; then
    SVN_STABLE_TAG=$(grep -m 1 -E "^([*+-]\s+)?Stable tag:" "trunk/$README_NAME" | tr -d '\r\n' | awk -F ' ' '{print $NF}')
else
    SVN_STABLE_TAG=""
fi
echo "ℹ︎ SVN Stable Tag: $SVN_STABLE_TAG"

# Check if stable tag changed
if [[ "$LOCAL_STABLE_TAG" != "$SVN_STABLE_TAG" ]]; then
    echo "🛑 Stable tag has changed (Local: $LOCAL_STABLE_TAG, SVN: $SVN_STABLE_TAG). Exiting action."
    exit 1
fi

# Copy only readme.txt
echo "➤ Copying readme.txt to trunk..."
cp "$GITHUB_WORKSPACE/$README_NAME" "trunk/$README_NAME"

# Sync only assets folder, delete old assets
if [[ -d "$GITHUB_WORKSPACE/$ASSETS_DIR" ]]; then
    echo "➤ Syncing assets from $ASSETS_DIR to SVN assets (removing old files)..."
    rsync -rc --delete --delete-excluded "$GITHUB_WORKSPACE/$ASSETS_DIR/" assets/
else
    echo "⚠️ $ASSETS_DIR directory not found in your repo."
fi

# TMP_DIR needed for any future processing
TMP_DIR=$GITHUB_WORKSPACE

# Set MIME types for images
for ext in png jpg gif svg; do
    if test -d "$SVN_DIR/assets" && test -n "$(find "$SVN_DIR/assets" -maxdepth 1 -name "*.$ext" -print -quit)"; then
        case $ext in
            png) mime="image/png" ;;
            jpg) mime="image/jpeg" ;;
            gif) mime="image/gif" ;;
            svg) mime="image/svg+xml" ;;
        esac
        svn propset svn:mime-type "$mime" "$SVN_DIR/assets/"*.$ext || true
    fi
done

echo "➤ Preparing files for commit..."

# Show SVN status
svn status

if [[ -z $(svn stat) ]]; then
	echo "🛑 Nothing to deploy!"
	exit 0
fi

# Add new files and remove deleted files
svn add . --force > /dev/null
svn status | grep '^\!' | sed 's/! *//' | xargs -I% svn rm %@ > /dev/null

# Resolve SVN out-of-date errors
svn update

# Now show full SVN status
svn status

# Commit changes
# echo "➤ Committing files..."
# svn commit -m "Updating readme/assets from GitHub" --no-auth-cache --non-interactive --username "$SVN_USERNAME" --password "$SVN_PASSWORD"

# echo "✓ Plugin assets and readme updated!"
