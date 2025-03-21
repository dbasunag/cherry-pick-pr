#!/bin/bash

set -e

REPO_NAME=$(jq -r ".repository.full_name" "$GITHUB_EVENT_PATH")

onerror() {
	gh pr comment $PR_NUMBER --body "‼️ cherry pick action failed.<br/>See: https://github.com/$REPO_NAME/actions/runs/$GITHUB_RUN_ID"
	exit 1
}
trap onerror ERR

if [ -z "$PR_NUMBER" ]; then
	PR_NUMBER=$(jq -r ".pull_request.number" "$GITHUB_EVENT_PATH")
	if [[ "$PR_NUMBER" == "null" ]]; then
		PR_NUMBER=$(jq -r ".issue.number" "$GITHUB_EVENT_PATH")
	fi
	if [[ "$PR_NUMBER" == "null" ]]; then
		echo "Failed to determine PR Number."
		exit 1
	fi
fi

echo "Collecting information about PR #$PR_NUMBER from repository: $GITHUB_REPOSITORY..."

if [[ -z "$GITHUB_TOKEN" ]]; then
	echo "Set the GITHUB_TOKEN env variable."
	exit 1
fi

URI=https://api.github.com
API_HEADER="Accept: application/vnd.github.v3+json"
AUTH_HEADER="Authorization: token $GITHUB_TOKEN"

MAX_RETRIES=${MAX_RETRIES:-6}
RETRY_INTERVAL=${RETRY_INTERVAL:-10}
MERGED=""
MERGE_COMMIT=""
pr_resp=""

for ((i = 0 ; i < $MAX_RETRIES ; i++)); do
	pr_resp=$(gh api "${URI}/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER")
	MERGED=$(echo "$pr_resp" | jq -r .merged)
	MERGE_COMMIT=$(echo "$pr_resp" | jq -r .merge_commit_sha)
	if [[ "$MERGED" == "null" ]]; then
		echo "The PR is not ready to cherry-pick, retry after $RETRY_INTERVAL seconds"
		sleep $RETRY_INTERVAL
		continue
	else
		break
	fi
done

if [[ "$MERGED" != "true" ]] ; then
	echo "PR is not merged! Can't cherry pick it."
	gh pr comment $PR_NUMBER --body "‼️ PR can't be cherry-picked, please merge it first."
	exit 1
fi

PR_TITLE=$(echo "$pr_resp" | jq -r .title)
PR_URL=$(echo "$pr_resp" | jq -r .html_url)

TARGET_BRANCH=$(jq -r ".comment.body" "$GITHUB_EVENT_PATH" | awk '{ print $2 }'  | tr -d '[:space:]')

USER_LOGIN=$(jq -r ".comment.user.login" "$GITHUB_EVENT_PATH")

if [[ "$USER_LOGIN" == "null" ]]; then
	USER_LOGIN=$(jq -r ".pull_request.user.login" "$GITHUB_EVENT_PATH")
fi

user_resp=$(curl -X GET -s -H "${AUTH_HEADER}" -H "${API_HEADER}" \
	"${URI}/users/${USER_LOGIN}")

USER_NAME=$(echo "$user_resp" | jq -r ".name")
if [[ "$USER_NAME" == "null" ]]; then
	USER_NAME=$USER_LOGIN
fi
USER_NAME="${USER_NAME} (Cherry Pick PR Action)"

USER_EMAIL=$(echo "$user_resp" | jq -r ".email")
if [[ "$USER_EMAIL" == "null" ]]; then
	USER_EMAIL="$USER_LOGIN@users.noreply.github.com"
fi

if [[ -z "$TARGET_BRANCH" ]]; then
	echo "Cannot get target branch information for PR #$PR_NUMBER!"
	gh pr comment $PR_NUMBER --body "‼️ Cannot get target branch information."
	exit 1
fi

USER_TOKEN=${USER_LOGIN//-/_}_TOKEN
UNTRIMMED_COMMITTER_TOKEN=${!USER_TOKEN:-$GITHUB_TOKEN}
COMMITTER_TOKEN="$(echo -e "${UNTRIMMED_COMMITTER_TOKEN}" | tr -d '[:space:]')"

# See https://github.com/actions/checkout/issues/766 for motivation.
git config --global --add safe.directory /github/workspace

git remote set-url origin https://$USER_LOGIN:$COMMITTER_TOKEN@github.com/$GITHUB_REPOSITORY.git
git config --global user.email "$USER_EMAIL"
git config --global user.name "$USER_NAME"

git remote add origindest https://$USER_LOGIN:$COMMITTER_TOKEN@github.com/$REPO_NAME.git

set -o xtrace

#Check if the target branch is a found in the remote repository:
REPO_CLONE_URL=$(echo "$pr_resp" | jq -r .base.repo.clone_url)

if [[ $(git ls-remote --heads $REPO_CLONE_URL refs/heads/$TARGET_BRANCH) ]]; then
	echo "Target branch for PR #$PR_NUMBER $TARGET_BRANCH found for repository: $GITHUB_REPOSITORY"
else
   	echo "Invalid target branch used for PR #$PR_NUMBER!"
	gh pr comment $PR_NUMBER --body "‼️ Please use a valid target branch name."
	exit 1
fi

# Fetch branches
git fetch origin $TARGET_BRANCH
git fetch origindest $TARGET_BRANCH

# create unique branch name
UUID=$(uuidgen)
CHERRY_PICK_BRANCH="CherryPick-$TARGET_BRANCH-${UUID:0:4}"
# do the cherry-pick
git checkout -b $CHERRY_PICK_BRANCH origindest/$TARGET_BRANCH

git cherry-pick $MERGE_COMMIT &> /tmp/error.log || (
		gh pr comment $PR_NUMBER --body "Error cherry-picking.<br/><br/>$(cat /tmp/error.log)"
		exit 1
)

# push back
git push origindest $CHERRY_PICK_BRANCH

# create the cherry-pick PR
CHERRY_PICK_NUM=$(gh pr create -B $TARGET_BRANCH -H $CHERRY_PICK_BRANCH \
-b "Cherry-picked $PR_URL into $TARGET_BRANCH. Requested by: $USER_LOGIN " \
  -t "[Cherry-pick][$TARGET_BRANCH] $PR_TITLE")

# add a comment to the original pr
gh pr comment $PR_NUMBER --body "Cherry pick action created PR $CHERRY_PICK_NUM successfully 🎉!<br/>See: https://github.com/$REPO_NAME/actions/runs/$GITHUB_RUN_ID"
