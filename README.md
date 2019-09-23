# Docker build-with-cache action

This action builds your docker image and cache the stages to improve building times in subsequent builds.

By default it pushes the image with all the stages to a registry, but you can disable this feature setting `push_image_and_stages` to `false`.

## Inputs

### Required

`username`: Docker registry's user.

`password`: Docker registry's password.

`image_name`: Image name with namespace (eg: *whoan/node*).

### Optional

`registry`: Docker registry (**default: Docker Hub's registry**).

`image_tag`: Tag of the image to build (**default: latest**).

`context`: Docker context (**default: ./**).

`dockerfile`: Name of the Dockerfile (**default: Dockerfile**)

`push_image_and_stages`: Set to `false` to avoid pushing to registry (**default: true**). You might want to set this option to `false` if you plan to use this action for PRs to avoid overriding cached stages in the registry.

## Outputs

None

## Example usage

Minimal example:

```yml
- uses: whoan/docker-build-with-cache-action@v1
  with:
    username: whoan
    password: "${{ secrets.DOCKER_PASSWORD }}"
    image_name: whoan/node
```

You can see a full **[working example in this repo](https://github.com/whoan/docker-images/blob/master/.github/workflows/node-alpine-slim.yml)**:

```yml
- uses: whoan/docker-build-with-cache-action@v1
  with:
    username: "${{ secrets.DOCKER_USERNAME }}"
    password: "${{ secrets.DOCKER_PASSWORD }}"
    image_name: whoan/node
    image_tag: alpine-slim
    context: node-alpine-slim
```

Another example for **Google Cloud Platform** and more custom settings:

```yml
- uses: whoan/docker-build-with-cache-action@v1
  with:
    username: _json_key
    password: "${{ secrets.DOCKER_PASSWORD }}"
    registry: gcr.io
    image_name: your_id/your_image
    image_tag: latest
    context: sub_folder_in_your_repo
    dockerfile: custom.dockerfile
    push_image_and_stages: false  # useful when you are setting a workflow to run on PRs
```
