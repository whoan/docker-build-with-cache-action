# Docker build-with-cache action

This action builds your docker image, caching the stages to improve building times in subsequent builds.

## Inputs

### `username`

**Required** Docker registry's user.

### `password`

**Required** Docker registry's password.

### `registry`

Docker registry (**default: Docker Hub's registry**).


### `image_name`

**Required** Docker's registry user.

### `image_tag`

Tag of the image to build (**default: latest**).

### `context`

Docker context (**default: ./**).

### `push_image_and_stages`

Set to `false` to avoid pushing to registry (**default: true**).

You might want to set this option to `false` if you plan to use this action for PRs to avoid overriding cached stages in the registry.

## Outputs

None

## Example usage

```yml
  - uses: whoan/docker-build-with-cache-action@master
    with:
      docker_username: "${{ secrets.DOCKER_USERNAME }}"
      docker_password: "${{ secrets.DOCKER_PASSWORD }}"
      image_name: ${{ github.actor }}/node
```
