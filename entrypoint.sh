#!/usr/bin/env bash

set -e

# helper functions
_has_value() {
  local var_name=${1}
  local var_value=${2}
  if [ -z "$var_value" ]; then
    echo "INFO: Missing value $var_name" >&2
    return 1
  fi
}

_is_docker_hub() {
  [ -z "$INPUT_REGISTRY" ] || [[ "$INPUT_REGISTRY" =~ \.docker\.(com|io)(/|$) ]]
}

_is_github_registry() {
  [ "$INPUT_REGISTRY" = docker.pkg.github.com ]
}

_is_gcloud_registry() {
  [[ "$INPUT_REGISTRY" =~ ^(.+\.)?gcr\.io$ ]]
}

_is_aws_ecr() {
  [[ $INPUT_REGISTRY =~ ^.+\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$ ]]
  is_aws_ecr=$?
  aws_region=${BASH_REMATCH[1]}
  return $is_aws_ecr
}

_image_name_contains_namespace() {
  [[ "$INPUT_IMAGE_NAME" =~ / ]]
}

_set_namespace() {
  if ! _image_name_contains_namespace; then
    if _is_docker_hub; then
      NAMESPACE=$INPUT_USERNAME
    elif _is_github_registry; then
      NAMESPACE=$GITHUB_REPOSITORY
    elif _is_gcloud_registry; then
      # take project_id from Json Key
      NAMESPACE=$(jq -r '.project_id' <<< "$INPUT_PASSWORD" 2> /dev/null)
      [ "$NAMESPACE" ] || return 1
    fi
    # aws-ecr does not need a namespace
  fi
  # set namespace to all lower, capital letters are not supported
  NAMESPACE=${NAMESPACE,,}
}

_get_max_stage_number() {
  sed -nr 's/^([0-9]+): Pulling from.+/\1/p' "$PULL_STAGES_LOG" |
    sort -n |
    tail -n 1
}

_get_stages() {
  grep -EB1 '^Step [0-9]+/[0-9]+ : FROM' "$BUILD_LOG" |
    sed -rn 's/ *-*> (.+)/\1/p'
}

_get_full_image_name() {
  echo ${INPUT_REGISTRY:+$INPUT_REGISTRY/}${NAMESPACE:+$NAMESPACE/}"${INPUT_IMAGE_NAME}"
}

_tag() {
  local tag
  tag="${1:?You must provide a tag}"
  echo "Tag: $(_get_full_image_name):$tag"
  docker tag "$DUMMY_IMAGE_NAME" "$(_get_full_image_name):$tag"
}

_push() {
  local tag
  tag="${1:?You must provide a tag}"
  docker push "$(_get_full_image_name):$tag"
}


_must_push() {
  if [ "$INPUT_PUSH_IMAGE_AND_STAGES" = on:push ]; then
    [ "$GITHUB_EVENT_NAME" = push ]
    return
  fi

  if [ "$INPUT_PUSH_IMAGE_AND_STAGES" = on:pull_request ]; then
    [ "$GITHUB_EVENT_NAME" = pull_request ]
    return
  fi

  $INPUT_PUSH_IMAGE_AND_STAGES
}

_push_git_tag() {
  [[ "$GITHUB_REF" =~ /tags/ ]] || return 0
  local git_tag=${GITHUB_REF##*/tags/}
  echo -e "\nPushing git tag: $git_tag"
  _tag "$git_tag"
  _push "$git_tag"
}

_push_image_tags() {
  local tag
  for tag in "${INPUT_IMAGE_TAG[@]}"; do
    echo "Pushing: $tag"
    _push "$tag"
  done
  if [ "$INPUT_PUSH_GIT_TAG" = true ]; then
    _push_git_tag
  fi
}

_push_image_stages() {
  local stage_number=1
  local stage_image
  for stage in $(_get_stages); do
    echo -e "\nPushing stage: $stage_number"
    stage_image=$(_get_full_image_name)-stages:$stage_number
    docker tag "$stage" "$stage_image"
    docker push "$stage_image"
    stage_number=$(( stage_number+1 ))
  done

  # push the image itself as a stage (the last one)
  echo -e "\nPushing stage: $stage_number"
  stage_image=$(_get_full_image_name)-stages:$stage_number
  docker tag "$DUMMY_IMAGE_NAME" "$stage_image"
  docker push "$stage_image"
}

_aws() {
  docker run --rm \
    --env AWS_ACCESS_KEY_ID="$INPUT_USERNAME" \
    --env AWS_SECRET_ACCESS_KEY="$INPUT_PASSWORD" \
    --env AWS_SESSION_TOKEN="$INPUT_SESSION" \
    amazon/aws-cli:2.0.7 --region "$aws_region" "$@"
}

_login_to_aws_ecr() {
  _aws ecr get-authorization-token --output text --query 'authorizationData[].authorizationToken' | base64 -d | cut -d: -f2 | docker login --username AWS --password-stdin "$INPUT_REGISTRY"
}

_create_aws_ecr_repos() {
  _aws ecr create-repository --repository-name "$INPUT_IMAGE_NAME" 2>&1 | grep -v RepositoryAlreadyExistsException
  _aws ecr create-repository --repository-name "$INPUT_IMAGE_NAME"-stages 2>&1 | grep -v RepositoryAlreadyExistsException
  return 0
}

_docker_login() {
  if _is_aws_ecr; then
    { _login_to_aws_ecr && _create_aws_ecr_repos; } || return 1
  else
    echo "${INPUT_PASSWORD}" | docker login -u "${INPUT_USERNAME}" --password-stdin "${INPUT_REGISTRY}" || return 1
  fi
  trap logout_from_registry EXIT
}

# action steps
init_variables() {
  DUMMY_IMAGE_NAME=my_awesome_image
  PULL_STAGES_LOG=pull-stages-output.log
  BUILD_LOG=build-output.log
  # split tags (to allow multiple comma-separated tags)
  IFS=, read -ra INPUT_IMAGE_TAG <<< "$INPUT_IMAGE_TAG"
  if ! _set_namespace; then
    echo "Could not set namespace" >&2
    exit 1
  fi
}

check_required_input() {
  echo -e "\n[Action Step] Checking required input..."
  #shellcheck disable=SC2128
  _has_value IMAGE_NAME "${INPUT_IMAGE_NAME}" \
    && _has_value IMAGE_TAG "${INPUT_IMAGE_TAG}" \
    && return
  exit 1
}

login_to_registry() {
  echo -e "\n[Action Step] Log in to registry..."
  if _has_value USERNAME "${INPUT_USERNAME}" && _has_value PASSWORD "${INPUT_PASSWORD}"; then
    _docker_login && return 0
    echo "Could not log in (please check credentials)" >&2
  else
    echo "No credentials provided" >&2
  fi
  not_logged_in=true
  echo "INFO: Won't be able to pull from private repos, nor to push to public/private repos" >&2
}

pull_cached_stages() {
  if [ "$INPUT_PULL_IMAGE_AND_STAGES" != true ]; then
    return
  fi
  echo -e "\n[Action Step] Pulling image..."
  docker pull --all-tags "$(_get_full_image_name)"-stages 2> /dev/null | tee "$PULL_STAGES_LOG" || true
}

build_image() {
  echo -e "\n[Action Step] Building image..."
  max_stage=$(_get_max_stage_number)

  # create param to use (multiple) --cache-from options
  if [ "$max_stage" ]; then
    cache_from=$(eval "echo --cache-from=$(_get_full_image_name)-stages:{1..$max_stage}")
    echo "Use cache: $cache_from"
  fi

  # build image using cache
  set -o pipefail
  set -x
  # shellcheck disable=SC2086
  docker build \
    $cache_from \
    --tag "$DUMMY_IMAGE_NAME" \
    --file "${INPUT_CONTEXT}"/"${INPUT_DOCKERFILE}" \
    ${INPUT_BUILD_EXTRA_ARGS} \
    "${INPUT_CONTEXT}" | tee "$BUILD_LOG"
  set +x
}

tag_image() {
  echo -e "\n[Action Step] Tagging image..."
  local tag
  for tag in "${INPUT_IMAGE_TAG[@]}"; do
    _tag "$tag"
  done
}

push_image_and_stages() {
  echo -e "\n[Action Step] Pushing image..."
  if ! _must_push; then
    echo "Not pushing" >&2
    # only stop the action on errors of custom commands set in the input variable
    [ "$INPUT_PUSH_IMAGE_AND_STAGES" = false ] || [[ "$INPUT_PUSH_IMAGE_AND_STAGES" =~ ^on: ]]
    return
  fi

  if [ "$not_logged_in" ]; then
    echo "ERROR: Can't push when not logged in to registry. Set \"push_image_and_stages: false\" if you don't want to push" >&2
    return 1
  fi

  _push_image_tags
  _push_image_stages
}

logout_from_registry() {
  echo -e "\n[Action Step] Log out from registry..."
  docker logout "${INPUT_REGISTRY}"
}


# run the action
init_variables
check_required_input
login_to_registry
pull_cached_stages
build_image
tag_image
push_image_and_stages

echo "::set-output name=FULL_IMAGE_NAME::$(_get_full_image_name)"
