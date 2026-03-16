#!/usr/bin/env bash

set -e
export DOCKER_BUILDKIT=${DOCKER_BUILDKIT:-1}

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

_is_old_github_registry() {
  [ "$INPUT_REGISTRY" = docker.pkg.github.com ]
}

_is_new_github_registry() {
  [ "$INPUT_REGISTRY" = ghcr.io ]
}

_is_gcloud_registry() {
  [[ "$INPUT_REGISTRY" =~ ^(.+\.)?gcr\.io$ ]]
}

_is_aws_ecr() {
  _is_aws_ecr_private || _is_aws_ecr_public
}

_is_aws_ecr_private() {
  [[ "$INPUT_REGISTRY" =~ ^.+\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$ ]]
}

_is_aws_ecr_public() {
  [[ "$INPUT_REGISTRY" =~ ^public.ecr.aws$ ]]
}

_buildkit_is_enabled() {
  [[ "$DOCKER_BUILDKIT" != 0 ]]
}

_get_aws_region() {
  _is_aws_ecr_public && echo "us-east-1" && return
  # tied to _is_aws_ecr_private implementation
  _is_aws_ecr_private && echo "${BASH_REMATCH[1]}" && return
  echo "Could not get AWS region" >&2
}

_image_name_contains_namespace() {
  [[ "$INPUT_IMAGE_NAME" =~ / ]]
}

_set_namespace() {
  if ! _image_name_contains_namespace; then
    if _is_docker_hub || _is_new_github_registry; then
      NAMESPACE=${INPUT_USERNAME:?A username is needed if no namespace is provided}
    elif _is_old_github_registry; then
      NAMESPACE=$GITHUB_REPOSITORY
    elif _is_gcloud_registry; then
      # take project_id from Json Key
      NAMESPACE=$(echo "${INPUT_PASSWORD}" | sed -rn 's@.+project_id" *: *"([^"]+).+@\1@p' 2> /dev/null)
      [ "$NAMESPACE" ] || return 1
    elif _is_aws_ecr_public; then
      NAMESPACE=$(_aws_get_public_ecr_registry_name)
    fi
    # aws-ecr (private) does not need a namespace
  fi
  # set namespace to all lower, capital letters are not supported
  NAMESPACE=${NAMESPACE,,}
}

_get_max_stage_number() {
  (( ${#tags[@]} == 0 )) || echo "${tags[-1]}"
}

_get_stages() {
  grep -EB1 '^Step [0-9]+/[0-9]+ : FROM' "$BUILD_LOG" |
    sed -rn 's/ *-*> (.+)/\1/p'
}

_get_image_namespace() {
  echo ${INPUT_REGISTRY:+$INPUT_REGISTRY/}${NAMESPACE:+$NAMESPACE/}
}

_get_full_image_name() {
  echo "$(_get_image_namespace)${INPUT_IMAGE_NAME}"
}

_get_stages_image_name() {
  echo "${INPUT_STAGES_IMAGE_NAME:-${INPUT_IMAGE_NAME}-stages}"
}

_get_full_stages_image_name() {
  echo "$(_get_image_namespace)$(_get_stages_image_name)"
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

_is_logged_in() {
  [ "$not_logged_in" != true ]
}

_must_pull() {
  [ "$INPUT_PULL_IMAGE_AND_STAGES" == true ]
}

_can_pull() {
  _must_pull && _is_logged_in
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

_can_push() {
  _must_push && _is_logged_in
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
    stage_image=$(_get_full_stages_image_name):$stage_number
    docker tag "$stage" "$stage_image"
    docker push "$stage_image"
    stage_number=$(( stage_number+1 ))
  done

  # push the image itself as a stage (the last one)
  echo -e "\nPushing stage: $stage_number"
  stage_image=$(_get_full_stages_image_name):$stage_number
  docker tag "$DUMMY_IMAGE_NAME" "$stage_image"
  docker push "$stage_image"
}

_aws() (
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN
  aws --region "$(_get_aws_region)" "$@"
)

_aws_get_public_ecr_registry_name() {
  _aws ecr-public describe-registries --output=text --query 'registries[0].aliases[0].name'
}

_aws_get_image_tags() {
  mapfile -t tags < <(_aws ecr-public describe-image-tags --repository-name "$(_get_stages_image_name)" | jq ".imageTagDetails[].imageTag")
  tags=( "${tags[@]#\"}" )
  tags=( "${tags[@]%\"}" )
}

_login_to_aws_ecr() {
  local array="[]"
  if _is_aws_ecr_public; then
    array=""
  fi
  _aws "$(_aws_ecr)" get-authorization-token --output text --query "authorizationData${array}.authorizationToken" |
    base64 -d | cut -d: -f2 | docker login --username AWS --password-stdin "$INPUT_REGISTRY"
}

_aws_ecr() {
  if _is_aws_ecr_public; then
    echo ecr-public
  else
    echo ecr
  fi
}

_aws_repo_exists() {
  local repo=$1
  : "${repo:?}"
  local subcommand  # use already-needed permissions to avoid new ones
  if _is_aws_ecr_public; then
    subcommand=describe-image-tags
  else
    subcommand=list-images
  fi

  local error_log
  error_log=$(command -p mktemp)
  _aws "$(_aws_ecr)" "$subcommand" --repository-name "$repo" > /dev/null 2> "$error_log"
  if [ -s "$error_log" ]; then
    if ! grep -q RepositoryNotFoundException "$error_log"; then
      # unknown error. exit
      cat "$error_log"
      exit 1
    fi
    return 1
  fi
}

_skip_create_repos() {
  [ "$INPUT_SKIP_CREATE_REPOS" = true ]
}

_create_aws_ecr_repos() {
  echo -e "\n[Action Step - AWS] Creating repositories (if needed)..."
  local main_repo stages_repo
  main_repo=$INPUT_IMAGE_NAME stages_repo=$(_get_stages_image_name)
  for repo in "$main_repo" "$stages_repo"; do
    _aws_repo_exists "$repo" || _aws "$(_aws_ecr)" create-repository --repository-name "$repo" || return 1
  done
}

_docker_login() {
  if _is_aws_ecr; then
    _login_to_aws_ecr || return 1
  else
    echo "${INPUT_PASSWORD}" | docker login -u "${INPUT_USERNAME}" --password-stdin "${INPUT_REGISTRY}" || return 1
  fi
  trap logout_from_registry EXIT
}

_parse_extra_args() {
  # non-json
  if ! [[ $INPUT_BUILD_EXTRA_ARGS =~ ^\{ ]]; then
    return
  fi

  # json
  declare -ga extra_args=()
  local key
  local value
  while read -r key; do
    while read -r value; do
      extra_args+=("$key")
      extra_args+=("${value//\\n/
}")
    done < <(jq --raw-output "[.\"$key\"] | flatten[]" <<<"${INPUT_BUILD_EXTRA_ARGS}")
  done < <(jq --raw-output "keys[]" <<<"${INPUT_BUILD_EXTRA_ARGS}")
  INPUT_BUILD_EXTRA_ARGS=""
}

# action steps
init_variables() {
  DUMMY_IMAGE_NAME="$INPUT_IMAGE_NAME":tmp_tag_ignore
  BUILD_LOG=build-output.log
  : "${INPUT_CONTEXT:=.}"
  : "${INPUT_DOCKERFILE:=Dockerfile}"
  : "${GITHUB_OUTPUT:=/dev/stdout}"
  # ! ignore any tag in the custom cache image name
  INPUT_STAGES_IMAGE_NAME=${INPUT_STAGES_IMAGE_NAME%:*}

  if _is_aws_ecr; then
    if [ -z "$INPUT_USERNAME" ]; then
        INPUT_USERNAME=$AWS_ACCESS_KEY_ID
        INPUT_PASSWORD=$AWS_SECRET_ACCESS_KEY
    fi
    if [ -z "$INPUT_SESSION" ]; then
        INPUT_SESSION=$AWS_SESSION_TOKEN
    fi
    AWS_ACCESS_KEY_ID=$INPUT_USERNAME
    AWS_SECRET_ACCESS_KEY=$INPUT_PASSWORD
    AWS_SESSION_TOKEN=$INPUT_SESSION
  fi

  # split tags (to allow multiple comma-separated tags)
  IFS=, read -ra INPUT_IMAGE_TAG <<< "$INPUT_IMAGE_TAG"
  if ! _set_namespace; then
    echo "Could not set namespace" >&2
    exit 1
  fi
}

check_aws_cli() {
  if _is_aws_ecr; then
    _aws --version
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

create_repos() {
  if ! _can_push || ! _skip_create_repos; then
    return
  fi
  if _is_aws_ecr; then
    _create_aws_ecr_repos || return 1
  fi
}

pull_cached_stages() {
  if ! _can_pull; then
    return
  fi
  # cache importing/exporting is done in build statement when BuildKit is enabled
  if _buildkit_is_enabled; then
    return
  fi
  echo -e "\n[Action Step] Pulling image..."

  if _is_aws_ecr_public; then
    _aws_get_image_tags
    local tag
    for tag in "${tags[@]}"; do
      docker pull "$(_get_full_stages_image_name)":"$tag" || true
    done
  else
    local PULL_STAGES_LOG=pull-stages-output.log
    docker pull --all-tags "$(_get_full_stages_image_name)" | tee "$PULL_STAGES_LOG" || true
    mapfile -t tags < <(sed -nr 's/^([0-9]+): Pulling from.+/\1/p' "$PULL_STAGES_LOG" | sort -n)
    if (( ${#tags[@]} == 0 )); then
      echo "Expected error ^ if this is the first time you build the image" >&2
    fi
  fi
}

_build_image_legacy() {
  echo -e "\n[Action Step] Building image..."
  max_stage=$(_get_max_stage_number)

  # create param to use (multiple) --cache-from options
  if [ "$max_stage" ]; then
    cache_from=$(eval "echo --cache-from=$(_get_full_stages_image_name):{1..$max_stage}")
  fi

  _parse_extra_args

  set -o pipefail
  set -x
  # shellcheck disable=SC2086
  docker build \
    $cache_from \
    --tag "$DUMMY_IMAGE_NAME" \
    --file "${INPUT_CONTEXT}"/"${INPUT_DOCKERFILE}" \
    ${INPUT_BUILD_EXTRA_ARGS} \
    "${extra_args[@]}" \
    "${INPUT_CONTEXT}" | tee "$BUILD_LOG"
  set +x
}

_build_image_buildkit() {
  echo -e "\n[Action Step] Building image with BuildKit..."

  local cache_image
  cache_image="$(_get_full_stages_image_name)":latest

  local cache_from
  if _can_pull; then
    cache_from="--cache-from type=registry,ref=$cache_image"
  fi

  local cache_to
  if _can_push; then
    cache_to="--cache-to mode=max,image-manifest=true,type=registry,compression=zstd,ref=$cache_image"
  fi

  _parse_extra_args

  set -x
  docker buildx create --use --name action-builder-instance |& grep -v "existing instance" || true
  # shellcheck disable=SC2086
  docker buildx build \
    --load \
    $cache_from \
    $cache_to \
    --tag "$DUMMY_IMAGE_NAME" \
    --file "${INPUT_CONTEXT}"/"${INPUT_DOCKERFILE}" \
    ${INPUT_BUILD_EXTRA_ARGS} \
    "${extra_args[@]}" \
    "${INPUT_CONTEXT}"
}

build_image() {
  if _buildkit_is_enabled; then
    _build_image_buildkit
  else
    _build_image_legacy
  fi
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

  if ! _is_logged_in; then
    echo "ERROR: Can't push when not logged in to registry. Set \"push_image_and_stages: false\" if you don't want to push" >&2
    return 1
  fi

  _push_image_tags
  if ! _buildkit_is_enabled; then
    _push_image_stages
  fi
}

logout_from_registry() {
  echo -e "\n[Action Step] Log out from registry..."
  docker logout "${INPUT_REGISTRY}"
}


# run the action
check_aws_cli
init_variables
check_required_input
login_to_registry
create_repos
pull_cached_stages
build_image
tag_image
push_image_and_stages

echo "FULL_IMAGE_NAME=$(_get_full_image_name)" >> "$GITHUB_OUTPUT"

echo "End of script"
