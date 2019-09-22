#!/usr/bin/env bash

set -e

echo ${INPUT_DOCKER_PASSWORD} | docker login -u ${INPUT_DOCKER_USERNAME} --password-stdin ${INPUT_DOCKER_REGISTRY}

# PULL CACHED STAGES
docker pull --all-tags ${INPUT_IMAGE_NAME}-stages | tee "$PULL_STAGES_LOG" || true


# BUILD DOCKER IMAGE
get_max_stage_number() {
  sed -nr 's/^([0-9]+): Pulling from.+/\1/p' "$PULL_STAGES_LOG" |
  sort -n |
  tail -n 1
}
max_stage=$(get_max_stage_number)

# create param to use (multiple) --cache-from options
if [ "$max_stage" ]; then
  echo "max stage: $max_stage"
  cache_from=$(eval "echo --cache-from=${INPUT_IMAGE_NAME}-stages:{1..$max_stage}")
  echo "Use cache: $cache_from"
fi

# build image using cache
docker build \
  $cache_from \
  --tag ${INPUT_IMAGE_NAME}:${INPUT_IMAGE_TAG} \
  ${INPUT_CONTEXT} | tee "$BUILD_LOG"


# PUSH IMAGE AND STAGES
get_stages() {
  grep -EB1 '^Step [0-9]+/[0-9]+ : FROM' "$BUILD_LOG" |
  sed -rn 's/ *-*> (.+)/\1/p'
}

# push image
docker push ${INPUT_IMAGE_NAME}:${INPUT_IMAGE_TAG}

# push each building stage
stage_number=0
for stage in $(get_stages); do
  stage_image=${INPUT_IMAGE_NAME}-stages:$stage_number
  docker tag $stage $stage_image
  docker push $stage_image
  stage_number=$(( stage_number+1 ))
done

# push the image itself as a stage (the last one)
stage_image=${INPUT_IMAGE_NAME}-stages:$stage_number
docker tag ${INPUT_IMAGE_NAME}:${INPUT_IMAGE_TAG} $stage_image
docker push $stage_image

docker logout
