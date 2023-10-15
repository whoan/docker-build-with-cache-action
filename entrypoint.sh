#!/usr/bin/env bash

export DOCKER_BUILDKIT=0
set -e

_build_image() {
  /docker-build.sh
}

# no compose file: original behavior
if [ -z "$INPUT_COMPOSE_FILE" ]; then
  _build_image
  exit
fi

merged_compose=/tmp/merged-compose.yml
original_INPUT_IMAGE_TAG=$INPUT_IMAGE_TAG

build_from_compose_file() {
   echo -e "\nBuilding from Compose file(s)"
  _merge_yamls
  _gather_images

  if (( ${#images[@]} == 0 )); then
    echo "No images detected for registry (${INPUT_REGISTRY:-DockerHub})" >&2
    return 1
  fi

  for image in "${images[@]}"; do
    echo -e "\n[Compose file] Building image: $image"
    _set_variables "$image"
    _build_image
    echo -e "[Compose file] $image - DONE\n"
  done
}

_yq() {
  local yq
  yq=$(which yq || true)
  if [ -z "$yq" ]; then
    yq=/usr/bin/yq
    _copy_yq_from_docker_image "$yq" > /dev/null
  fi
  "$yq" "$@"
}

_copy_yq_from_docker_image() {
  local yq_path=$1
  : "${yq_path:?I need a path where yq will be copied}"
  local hash
  yq=/usr/bin/yq
  docker pull mikefarah/yq:4.28.2 >&2
  hash=$(docker create mikefarah/yq:4.28.2)
  docker cp "$hash":/usr/bin/yq "$yq_path"
  docker rm "$hash"
}

_merge_yamls() (
  local yamls=()
  mapfile -d ">" -t yamls < <(echo -n "$INPUT_COMPOSE_FILE")
  shopt -s extglob
  yamls=( "${yamls[@]##*( )}") # trim leading spaces
  yamls=( "${yamls[@]%%*( )}") # trim trailing spaces
  # shellcheck disable=SC2016
  _yq ea '. as $item ireduce ({}; . * $item )' "${yamls[@]}" > "$merged_compose"
  echo -e "\nCompose file:"
  cat "$merged_compose"
  echo
)

_gather_images() {
  local registry=$INPUT_REGISTRY
  : "${registry:=$INPUT_USERNAME}" # an empty registry defaults to DockerHub, and a username is needed to detect its images
  : "${registry:?Either registry or username (for DockerHub) is needed to build from a compose file}"

  images=()
  mapfile -t images < <(_yq e "
    .services
     | with_entries(select(.key | test(\"^${INPUT_SERVICES_REGEX:-.+}\$\")))
     | .[].image
     | select(. != null and test(\"^${registry}/\"))
    " "$merged_compose"
  )
}

_set_variables() {
  local image_name
  image_name="${1:?I need an image name}"

  # if image already has a tag set in the compose file
  if [[ $image_name =~ : ]];then
    INPUT_IMAGE_TAG=${image_name##*:}
  else
    INPUT_IMAGE_TAG=${original_INPUT_IMAGE_TAG}
  fi

  local service_name
  service_name=$(_get_service_name_by_image_name "$image_name")

  INPUT_IMAGE_NAME=${image_name%:*}
  if [ "$INPUT_REGISTRY" ]; then
    INPUT_IMAGE_NAME=${INPUT_IMAGE_NAME#"$INPUT_REGISTRY"/}
  fi

  INPUT_CONTEXT=$(_get_context_by_service_name "$service_name")
  INPUT_CONTEXT=${INPUT_CONTEXT:-.}

  INPUT_DOCKERFILE=$(_get_dockerfile_by_service_name "$service_name")
  INPUT_DOCKERFILE=${INPUT_DOCKERFILE:-Dockerfile}

  echo "Exporting variables:"
  echo "INPUT_IMAGE_NAME=$INPUT_IMAGE_NAME"
  echo "INPUT_IMAGE_TAG=$INPUT_IMAGE_TAG"
  echo "INPUT_CONTEXT=$INPUT_CONTEXT"
  echo "INPUT_DOCKERFILE=$INPUT_DOCKERFILE"

  export INPUT_IMAGE_NAME
  export INPUT_IMAGE_TAG
  export INPUT_CONTEXT
  export INPUT_DOCKERFILE
}

_get_service_name_by_image_name() {
  local image_name
  image_name="${1:?I need an image_name}"
  local service_name
  service_name=$(_yq e ".services.[] | select(.image == \"${image_name}\") | path | .[1]" "$merged_compose")
  if [ -z "$service_name" ]; then
    echo "Failed to get service name" >&2
    return 1
  fi
  echo "$service_name"
}

_get_context_by_service_name() {
  local service_name
  service_name="${1:?I need a service name}"
  local context
  context=$(_yq e ".services.${service_name}.build.context // \"\"" "$merged_compose" || true)
  if [ -z "$context" ]; then
    context=$(_yq e ".services.${service_name}.build // \"\"" "$merged_compose" || true)
  fi
  echo "$context"
}

_get_dockerfile_by_service_name() {
  local service_name
  service_name="${1:?I need a service name}"
  _yq e ".services.${service_name}.build.dockerfile // \"\"" "$merged_compose" || true
}

_yq --version
build_from_compose_file
