#!/usr/bin/env bash
set -e

echo "GITHUB_REF_NAME=$GITHUB_REF_NAME"
echo "GITHUB_REF=$GITHUB_REF"

BASE_PATH=$(pwd)

cd repo-with-unsigned-version-update-commits.git
RELEASE_TAG=$(git describe --tags --abbrev=0)

INCOMING_REPO_PATH="$(pwd)"

cd ../repo

if [ -n "$SOURCE_DIR" ]; then
  if [ ! -d "$SOURCE_DIR" ]; then
    echo "::error title=Source directory not found::$SOURCE_DIR does not exist."
    exit 1
  fi
  cd "$SOURCE_DIR"
fi

git remote add unsigned "$INCOMING_REPO_PATH"
git fetch unsigned

RELEASE_VERSION=${RELEASE_TAG#"v"}

if [[ "${RELEASE_TYPE}" = "FULL_MAIN_BRANCH" ]]; then
  RELEASE_NOTES_URL=$GITHUB_REPO_URL/releases/tag/$RELEASE_TAG
else
  # Use the PR url as the release notes url when doing a 'preview' release
  RELEASE_NOTES_URL=$( gh pr view "$GITHUB_REF_NAME" --json url -q .url )
fi

VERSION_FILE_PATH=$(git diff-tree --no-commit-id --name-only -r "$RELEASE_TAG" | grep "$VERSION_FILE")
VERSION_FILE_INITIAL_SHA=$( git rev-parse "$GITHUB_REF":"$VERSION_FILE_PATH" )
VERSION_FILE_RELEASE_SHA=$( git rev-parse "$RELEASE_TAG":"$VERSION_FILE_PATH" )
VERSION_FILE_RELEASE_CONTENT=$( git cat-file blob "$RELEASE_TAG":"$VERSION_FILE_PATH" | base64 -w0)
VERSION_FILE_POST_RELEASE_CONTENT=$( git cat-file blob unsigned/"$GITHUB_REF_NAME":"$VERSION_FILE_PATH" | base64 -w0)

# Create temporary branch to push the release commit- required for PREVIEW releases
gh api --method POST /repos/:owner/:repo/git/refs -f ref="refs/heads/$TEMPORARY_BRANCH" -f sha="$GITHUB_SHA"

# Parse modules and iterate over them, committing API files and collecting their details
# in a json object for later use
IFS=',' read -ra MOD_ARRAY <<< "$MODULES"

API_FILES_JSON="["

for mod in "${MOD_ARRAY[@]}"; do
  MOD=$(echo "${mod}" | xargs)
  API_FILE_PATH=$(git diff-tree --no-commit-id --name-only -r "$RELEASE_TAG" | grep "${MOD}/${API_FILE}")
  API_FILE_INITIAL_SHA=$(git rev-parse "$GITHUB_REF":"$API_FILE_PATH")
  API_FILE_RELEASE_SHA=$(git rev-parse "$RELEASE_TAG":"$API_FILE_PATH")
  API_FILE_RELEASE_CONTENT=$(git cat-file blob "$RELEASE_TAG":"$API_FILE_PATH" | base64 -w0)
  API_FILE_POST_RELEASE_CONTENT=$(git cat-file blob unsigned/"$GITHUB_REF_NAME":"$API_FILE_PATH" | base64 -w0)

  # Commit the API file changes for module
  gh api --method PUT /repos/:owner/:repo/contents/"$API_FILE_PATH" \
    --field branch="$TEMPORARY_BRANCH" \
    --field message="Update public API file for module $MOD for $RELEASE_TAG" \
    --field sha="$API_FILE_INITIAL_SHA" \
    --field content="$API_FILE_RELEASE_CONTENT" --jq '.commit.sha'

  API_FILES_JSON="${API_FILES_JSON}{\"module\":\"$MOD\",\"api_file_path\":\"$API_FILE_PATH\",\"api_file_release_sha\":\"$API_FILE_RELEASE_SHA\",\"api_file_post_release_content\":\"$API_FILE_POST_RELEASE_CONTENT\"},"
done

# Remove trailing comma and close JSON array
API_FILES_JSON="${API_FILES_JSON%,}]"

cd "$BASE_PATH"

cat << EndOfFile > commit-message.txt
$RELEASE_TAG published by $GITHUB_ACTOR

$GITHUB_ACTOR published release version $RELEASE_VERSION
using gha-gradle-library-release-workflow: https://github.com/guardian/gha-gradle-library-release-workflow

Release-Version: $RELEASE_VERSION
Release-Initiated-By: $GITHUB_SERVER_URL/$GITHUB_ACTOR
Release-Workflow-Run: $GITHUB_REPO_URL/actions/runs/$GITHUB_RUN_ID
Release-Notes: $RELEASE_NOTES_URL
EndOfFile

# Commit the version file
version_commit_id=$(gh api --method PUT /repos/:owner/:repo/contents/"$VERSION_FILE_PATH" \
  --field branch="$TEMPORARY_BRANCH" \
  --field message="@commit-message.txt" \
  --field sha="$VERSION_FILE_INITIAL_SHA" \
  --field content="$VERSION_FILE_RELEASE_CONTENT" --jq '.commit.sha')

# Set output
cat << EndOfFile >> "$GITHUB_OUTPUT"
release_tag=$RELEASE_TAG
release_notes_url=$RELEASE_NOTES_URL
release-version=$RELEASE_VERSION
release_commit_id=$version_commit_id
version_file_path=$VERSION_FILE_PATH
version_file_release_sha=$VERSION_FILE_RELEASE_SHA
version_file_post_release_content=$VERSION_FILE_POST_RELEASE_CONTENT
api_files=$API_FILES_JSON
EndOfFile

