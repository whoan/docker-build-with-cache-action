# Docker Build-with-cache action

This action builds your docker image, caching the stages to improve building times in subsequent builds.

## Inputs

### `docker_username`

**Required** Docker's registry user.

### `docker_password`

**Required** Docker's registry password.

### `docker_registry`

Docker registry (**default: Docker Hub's registry**).


### `image_name`

**Required** Docker's registry user.

### `image_tag`

**Required** Tag of the image to build.

### `context`

Docker context (**default: ./**).

## Outputs

None

## Example usage

```yml
  - uses: ./.github/actions/build-and-push-with-cache
    with:
      docker_username: "${{ secrets.DOCKER_USERNAME }}"
      docker_password: "${{ secrets.DOCKER_PASSWORD }}"
      image_name: ${{ github.actor }}/node
      image_tag: alpine-slim
```
