#!/usr/bin/env bash

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

REPO_NAME=$(jq -r .repository.name /github/workflow/event.json)
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to {repo_name}-pr-{pr_number}
app="${INPUT_NAME:-$REPO_NAME-pr-$PR_NUMBER}"
# # Default the Fly app name to {repo_name}-pr-{pr_number}-postgres
postgres_app="${INPUT_POSTGRES:-$REPO_NAME-pr-$PR_NUMBER-postgres}"
region="${INPUT_REGION:-${FLY_REGION:-ewr}}"

org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
config="${INPUT_CONFIG:-fly.toml}"

# only wait for the deploy to complete if the user has requested the wait option
# otherwise detach so the GitHub action doesn't run as long
if [ "$INPUT_WAIT" = "true" ]; then
  detach=""
else
  detach="--detach"
fi

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true

  message="Review app deleted."
  echo "message=$message" >>$GITHUB_OUTPUT
  exit 0
fi

# Deploy the Fly app, creating it first if needed.
if ! flyctl status --app "$app"; then
  # Backup the original config file since 'flyctl launch' messes up the [build.args] section
  cp "$config" "$config.bak"
  flyctl launch --no-deploy --copy-config --name "$app" --image "$image" --regions "$region" --org "$org"
  # Restore the original config file
  cp "$config.bak" "$config"
fi

echo "::add-mask::$INPUT_SECRETS"
if [ -n "$INPUT_SECRETS" ]; then
  flyctl_command="flyctl secrets set -a $app"
  while IFS= read -r secret; do
    flyctl_command+=" $secret"
  done <<<"$INPUT_SECRETS"
  eval "$flyctl_command" # Execute the constructed command
fi

# Attach postgres cluster to the app if specified.
if [ -n "$INPUT_POSTGRES" ]; then
  flyctl postgres attach "$INPUT_POSTGRES" --app "$app" || true
fi

# Trigger the deploy of the new version.
echo "Contents of config $config file: " && cat "$config"
if [ -n "$INPUT_VM" ]; then
  flyctl deploy $detach --config "$config" --app "$app" --regions "$region" --image "$image" --strategy immediate --ha=$INPUT_HA --vm-size "$INPUT_VMSIZE" --remote-only

  statusmessage="Review app created. It may take a few minutes for the app to deploy."
elif [ "$EVENT_TYPE" = "synchronize" ]; then
  flyctl deploy $detach --config "$config" --app "$app" --regions "$region" --image "$image" --strategy immediate --ha=$INPUT_HA --vm-cpu-kind "$INPUT_CPUKIND" --vm-cpus $INPUT_CPU --vm-memory "$INPUT_MEMORY" --remote-only
  statusmessage="Review app updated. It may take a few minutes for your changes to be deployed."
fi

flyctl status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "hostname=$hostname" >>$GITHUB_OUTPUT
echo "url=https://$hostname" >>$GITHUB_OUTPUT
echo "id=$appid" >>$GITHUB_OUTPUT
echo "name=$app" >>$GITHUB_OUTPUT
