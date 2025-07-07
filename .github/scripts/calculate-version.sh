#!/usr/bin/env bash
set -e

# Check and switch to source directory if provided and exists
if [ -n "$SOURCE_DIR" ]; then
  if [ ! -d "$SOURCE_DIR" ]; then
    echo "::error title=Source directory not found::$SOURCE_DIR does not exist."
    exit 1
  fi
  cd "$SOURCE_DIR"
fi

# If the version file does not exist, create it with a default version
if [ ! -f "$VERSION_FILE" ]; then
  echo "0.0.1" > "$VERSION_FILE"
fi

# Read major, minor, and patch version from the version file
VERSION=$(cat "$VERSION_FILE" | tr -d ' \n\r')
IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"

# Validate version format
if ! [[ "$MAJOR" =~ ^[0-9]+$ && "$MINOR" =~ ^[0-9]+$ && "$PATCH" =~ ^[0-9]+$ ]]; then
  echo "::error title=Invalid version format::Version file '$VERSION_FILE' must contain a valid semantic version (e.g., 1.0.0)."
  exit 1
fi

# Iterate over modules and determine the highest version bump required
IFS=',' read -ra MOD_ARRAY <<< "$MODULES"

HIGHEST_BUMP="patch"

for mod in "${MOD_ARRAY[@]}"; do
  MOD=$(echo "${mod}" | xargs)
  MOD_API_FILE="${MOD}/${API_FILE}"

  TMP_API_FILE=$(mktemp)
  cp "$MOD_API_FILE" "$TMP_API_FILE"

  # Check API compatibility
  set +e
  ./gradlew ":${MOD}:metalavaCheckCompatibilityRelease"
  RESULT=$?
  set -e

  if [ $RESULT -ne 0 ]; then
    ./gradlew ":${MOD}:metalavaGenerateSignatureRelease"
    BUMP="major"
  else
    ./gradlew ":${MOD}:metalavaGenerateSignatureRelease"
    if ! cmp -s "$MOD_API_FILE" "$TMP_API_FILE"; then
      BUMP="minor"
    else
      BUMP="patch"
    fi
  fi

  # Determine the highest bump needed
  if [ "$BUMP" = "major" ]; then
    HIGHEST_BUMP="major"
  elif [ "$BUMP" = "minor" ] && [ "$HIGHEST_BUMP" = "patch" ]; then
    HIGHEST_BUMP="minor"
  fi

  # Add this module's API file to the commit
  git add "$MOD_API_FILE"

  rm -f "$TMP_API_FILE"
done

# Apply the highest bump
if [ "$HIGHEST_BUMP" = "major" ]; then
  MAJOR=$((MAJOR + 1))
  MINOR=0
  PATCH=0
elif [ "$HIGHEST_BUMP" = "minor" ]; then
  MINOR=$((MINOR + 1))
  PATCH=0
else
  PATCH=$((PATCH + 1))
fi

# Update version file with the new version
echo "$MAJOR.$MINOR.$PATCH" > "$VERSION_FILE"

echo "Updated version to $MAJOR.$MINOR.$PATCH"

# Commit the updated version
git add "$VERSION_FILE"
git commit -m "chore: update version to $MAJOR.$MINOR.$PATCH"

# Add version_suffix to the version and tag the commit with the new version number
git tag "v$MAJOR.$MINOR.$PATCH${VERSION_SUFFIX}"