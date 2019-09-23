#!/usr/bin/env bash

set -e

# helper functions
_exit_if_empty() {
  local var_name=${1}
  local var_value=${2}
  if [ -z "$var_value" ]; then
    echo "Missing input $var_name" >&2
    exit 1
  fi
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
  echo ${INPUT_REGISTRY:+$INPUT_REGISTRY/}${INPUT_IMAGE_NAME}
}

# action steps
check_required_input() {
  _exit_if_empty USERNAME "${INPUT_USERNAME}"
  _exit_if_empty PASSWORD "${INPUT_PASSWORD}"
  _exit_if_empty IMAGE_NAME "${INPUT_IMAGE_NAME}"
  _exit_if_empty IMAGE_TAG "${INPUT_IMAGE_TAG}"
}

login_to_registry() {
  echo ${INPUT_PASSWORD} | docker login -u ${INPUT_USERNAME} --password-stdin ${INPUT_REGISTRY}
}

pull_cached_stages() {
  docker pull --all-tags "$(_get_full_image_name)"-stages 2> /dev/null | tee "$PULL_STAGES_LOG" || true
}

build_image() {
  max_stage=$(_get_max_stage_number)

  # create param to use (multiple) --cache-from options
  if [ "$max_stage" ]; then
    cache_from=$(eval "echo --cache-from=$(_get_full_image_name)-stages:{1..$max_stage}")
    echo "Use cache: $cache_from"
  fi

  # build image using cache
  docker build \
    $cache_from \
    --tag "$(_get_full_image_name)":${INPUT_IMAGE_TAG} \
    --file ${INPUT_CONTEXT}/${INPUT_DOCKERFILE} \
    ${INPUT_CONTEXT} | tee "$BUILD_LOG"
}

push_image_and_stages() {
  # push image
  docker push "$(_get_full_image_name)":${INPUT_IMAGE_TAG}

  # push each building stage
  stage_number=1
  for stage in $(_get_stages); do
    stage_image=$(_get_full_image_name)-stages:$stage_number
    docker tag $stage $stage_image
    docker push $stage_image
    stage_number=$(( stage_number+1 ))
  done

  # push the image itself as a stage (the last one)
  stage_image=$(_get_full_image_name)-stages:$stage_number
  docker tag "$(_get_full_image_name)":${INPUT_IMAGE_TAG} $stage_image
  docker push $stage_image
}

logout_from_registry() {
  docker logout
}

check_required_input
login_to_registry
pull_cached_stages
build_image

if [ "$INPUT_PUSH_IMAGE_AND_STAGES" = true ]; then
  push_image_and_stages
fi

logout_from_registry
