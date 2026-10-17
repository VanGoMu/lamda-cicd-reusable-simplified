#!/usr/bin/env bash
# Deploys one function stack and moves its `live` alias, directly or as a canary:
#   hold (new version, no traffic) -> smoke test -> canary -> watch the alarm -> all
# usage: deploy.sh <dist-dir>   (function.zip and, optionally, smoke-event.json)
# Environment: INPUTS (the inputs of lambda.yml as JSON), CFN_ROLE_ARN, ARTIFACT_BUCKET.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$(cd "${1:?usage: deploy.sh <dist-dir>}" && pwd)"
: "${INPUTS:?}" "${CFN_ROLE_ARN:?set by the bootstrap}" "${ARTIFACT_BUCKET:?set by the bootstrap}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

input() { jq -r --arg k "$1" '.[$k] // "" | tostring' <<<"${INPUTS}"; }
stack="$(input function-name)-$(input environment)"
percent="$(input canary-percent)"

note() { echo "$*" && echo "- $*" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"; }
fail() { note "**$***" && echo "::error::$*" && exit 1; }

output() {
  aws cloudformation describe-stacks --stack-name "${stack}" --output text \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue"
}

prepare() {
  local hash weight=0 tg="${stack}"
  cp "${root}/template.yaml" "${dist}/function.zip" "${work}/"
  if [[ -n "$(input environment-variables)" ]]; then
    ENV_VARS="$(input environment-variables)" yq -i \
      '.Resources.Function.Properties.Environment.Variables = (strenv(ENV_VARS) | from_json)' \
      "${work}/template.yaml"
  fi
  # VersionHash: what Lambda versions. A new version is published only when it changes.
  hash="$(jq -r '[.runtime, .handler, .architecture, .memory, .timeout,
    ."environment-variables"] | tostring' <<<"${INPUTS}" \
    | cat - "${work}/function.zip" "${root}/template.yaml" | sha256sum | cut -c1-64)"
  ((percent == 0)) || weight="$(printf '0.%02d' "${percent}")"
  # Target group names: 32 characters at most.
  ((${#tg} <= 32)) || tg="${stack:0:23}-$(sha256sum <<<"${stack}" | cut -c1-8)"
  params=(
    "FunctionName=${stack}" "Handler=$(input handler)" "Runtime=$(input runtime)"
    "Architecture=$(input architecture)" "MemorySize=$(input memory)"
    "Timeout=$(input timeout)" "VersionHash=${hash}" "CanaryWeight=${weight}"
    "ReservedConcurrency=$(input reserved-concurrency)" "Exposure=$(input exposure)"
    "TargetGroupName=${tg}" "AlbListenerArn=$(input alb-listener-arn)" "AlbPath=$(input alb-path)"
    "AlbPriority=$(input alb-priority)" "ApiId=$(input api-id)" "ApiRouteKey=$(input api-route)"
  )
  aws cloudformation package --template-file "${work}/template.yaml" \
    --s3-bucket "${ARTIFACT_BUCKET}" --s3-prefix "${stack}" \
    --output-template-file "${work}/packaged.yaml" >/dev/null
}

# Every step sends the same parameters; only TrafficMode and StableVersion change.
deploy() {
  note "CloudFormation ${stack}: TrafficMode=$1${2:+ StableVersion=$2}"
  aws cloudformation deploy --stack-name "${stack}" --template-file "${work}/packaged.yaml" \
    --role-arn "${CFN_ROLE_ARN}" --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
    --parameter-overrides "${params[@]}" "TrafficMode=$1" "StableVersion=${2:-}"
}

smoke() {
  [[ -f "${dist}/smoke-event.json" ]] || { note "smoke test: not configured" && return 0; }
  aws lambda invoke --function-name "$1" --payload "fileb://${dist}/smoke-event.json" \
    "${work}/response.json" >"${work}/invoke.json" || return 1
  if jq -e 'has("FunctionError")' "${work}/invoke.json" >/dev/null \
    || ! jq -e "$(input smoke-check)" "${work}/response.json" >/dev/null; then
    note "smoke test on $1: **failed**: $(head -c 300 "${work}/response.json")"
    return 1
  fi
  note "smoke test on $1: passed"
}

# Polls the canary alarm for canary-minutes. An alarm it cannot read counts as fired.
watch_alarm() {
  local alarm state deadline=$((SECONDS + $(input canary-minutes) * 60))
  alarm="$(output CanaryAlarmName)" || return 1
  while ((SECONDS < deadline)); do
    sleep 30
    state="$(aws cloudwatch describe-alarms --alarm-names "${alarm}" --output text \
      --query 'MetricAlarms[0].StateValue')" || return 1
    [[ "${state}" != ALARM ]] || return 1
  done
}

finish() {
  note "traffic: $1"
  printf '%s\n' "function-arn=$(output FunctionArn)" "alias-arn=$(output AliasArn)" \
    "version=$(output LiveVersion)" >>"${GITHUB_OUTPUT:-/dev/null}"
}

main() {
  local status stable="" new
  prepare
  status="$(aws cloudformation describe-stacks --stack-name "${stack}" --output text \
    --query 'Stacks[0].StackStatus' 2>/dev/null || echo NONE)"
  if [[ "${status}" == ROLLBACK_COMPLETE ]]; then  # a failed creation can only be deleted
    aws cloudformation delete-stack --stack-name "${stack}" --role-arn "${CFN_ROLE_ARN}"
    aws cloudformation wait stack-delete-complete --stack-name "${stack}"
    status=NONE
  fi
  [[ "${status}" == NONE ]] || stable="$(output LiveVersion)"

  if ((percent == 0)) || [[ -z "${stable}" ]]; then
    deploy all
    finish "$(output NewVersion) 100 %"
    smoke "${stack}:live"
    return
  fi
  deploy hold "${stable}"
  new="$(output NewVersion)"
  if [[ "${new}" == "${stable}" ]]; then
    deploy all
    finish "${new} 100 % (no new version to canary)"
    return
  fi
  smoke "${stack}:${new}" || fail "traffic not moved: version ${stable} keeps 100 %"
  deploy canary "${stable}"
  note "traffic: ${stable} $((100 - percent)) % · ${new} ${percent} %"
  if ! watch_alarm; then
    deploy hold "${stable}"
    fail "canary alarm fired (or unreadable): version ${stable} back to 100 %"
  fi
  deploy all
  finish "${new} 100 %"
}

main
