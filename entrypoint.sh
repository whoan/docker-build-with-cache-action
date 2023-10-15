#!/usr/bin/env bash

export DOCKER_BUILDKIT=0
set -e

# no compose file: original behavior
if [ -z "$INPUT_COMPOSE_FILE" ]; then
  /docker-build.sh
  exit
fi

parsed_yaml=/tmp/parsed-yaml.txt
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
    export INPUT_IMAGE_NAME
    export INPUT_IMAGE_TAG
    export INPUT_CONTEXT
    export INPUT_DOCKERFILE
    /docker-build.sh
    echo -e "\n[Compose file] $image - DONE\n"
  done
}

# shellcheck disable=SC2086
_merge_yamls() {
  local yamls=()
  mapfile -d ">" -t yamls < <(echo -n "$INPUT_COMPOSE_FILE")

  touch "$parsed_yaml"
  local yaml
  for yaml in "${yamls[@]}"; do
    while read -r line; do
      if [[ $line =~ ^(services[^=]+)= ]]; then
        local fragment=${BASH_REMATCH[1]}
        if grep -q "$fragment" "$parsed_yaml"; then
          echo "Overriding: ${fragment//@/ > }"
          sed -i "/$fragment/d" "$parsed_yaml"
        fi
        echo "$line" >> "$parsed_yaml"
      fi
    done < <(_parse_yaml $yaml)
  done
}

# based on https://stackoverflow.com/a/21189044
_parse_yaml() {
   local prefix=$2
   local s
   s='[[:space:]]*'
   local w
   w='[a-zA-Z0-9_-]*'
   local fs
   fs=$(echo @|tr @ '\034')

   sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)\($w\)$s:${s}[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:${s}\(.*\)$s\$|\1$fs\2$fs\3|p" "$1" |
     awk -F"$fs" '{
        indent = length($1)/2;
        vname[indent] = $2;
        for (i in vname) {if (i > indent) {delete vname[i]}}
        if (length($3) > 0) {
           vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("@")}
           printf("%s%s%s=\"%s\"\n", "'"$prefix"'",vn, $2, $3);
        }
     }'
}

_gather_images() {
  images=()
  if [ -z "$INPUT_REGISTRY" ]; then
    # docker hub registry
    mapfile -t images < <(grep -Po "(?<=@image=\")${INPUT_USERNAME}/[^\"]+" "$parsed_yaml")
  else
    mapfile -t images < <(grep -Po "(?<=@image=\")${INPUT_REGISTRY}/[^\"]+" "$parsed_yaml")
  fi
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
    INPUT_IMAGE_NAME=${INPUT_IMAGE_NAME#$INPUT_REGISTRY/}
  fi

  INPUT_CONTEXT=$(_get_context_by_service_name "$service_name")
  INPUT_CONTEXT=${INPUT_CONTEXT:-.}

  INPUT_DOCKERFILE=$(_get_dockerfile_by_service_name "$service_name")
  INPUT_DOCKERFILE=${INPUT_DOCKERFILE:-"$INPUT_CONTEXT"/Dockerfile}
}

_get_service_name_by_image_name() {
  local image_name
  image_name="${1:?I need an image_name}"
  # regex info: https://github.com/distribution/distribution/blob/main/reference/regexp.go
  grep -Po "(?<=services@)[^@]+(?=@image=\"${image_name}(?![[:alnum:]-._]))" "$parsed_yaml" ||
    { echo "Failed to get service name" >&2 && false; }
}

_get_context_by_service_name() {
  local service_name
  service_name="${1:?I need a service name}"
  grep -Po "((?<=services@${service_name}@build@context=\")|(?<=services@${service_name}@build=\"))[^\"]+" "$parsed_yaml" ||
    { echo "Failed to get context" >&2 && false; }
}

_get_dockerfile_by_service_name() {
  local service_name
  service_name="${1:?I need a service name}"
  grep -Po "(?<=services@${service_name}@build@dockerfile=\")[^\"]+" "$parsed_yaml" || echo Dockerfile
}

build_from_compose_file
