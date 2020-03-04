# Docker build-with-cache action

This action builds your docker image and cache the stages (supports multi-stage builds) to improve building times in subsequent builds.

By default it pushes the image with all the stages to a registry (needs username and password), but you can disable this feature setting `push_image_and_stages` to `false`.

## Inputs

### Required

`image_name`: Image name with namespace (eg: *whoan/node*).

### Optional

`username`: Docker registry's user (needed to push image to repository, or to pull from private repository).

`password`: Docker registry's password (needed to push image to repository, or to pull from private repository).

`registry`: Docker registry (**default: Docker Hub's registry**).

`image_tag`: Tag of the image to build (**default: latest**).

`context`: Docker context (**default: ./**).

`dockerfile`: Dockerfile filename path (**default: "$context"/Dockerfile**)

`push_image_and_stages`: Set to `false` to avoid pushing to registry (**default: true**). You might want to set this option to `false` if you plan to use this action for PRs to avoid overriding cached stages in the registry.

`push_git_tag`: In addition to `image_tag`, you can also push the git tag in your [branch tip][branch tip] (**default: false**)

`pull_image_and_stages`: Set to `false` to avoid pulling from registry (**default: true**). You might want to set this option to `false` if you plan to rebuild image from the scratch.

`build_extra_args`: Provide extra arguments to `docker build`. eg: `"--compress=true --build-arg=hello=world"`

[branch tip]: https://stackoverflow.com/questions/16080342/what-is-a-branch-tip-in-git

## Outputs

None

## How it works

The action does the following every time it is triggered:

- Pull previously pushed [stages](https://docs.docker.com/develop/develop-images/multistage-build/) (if any) from the specified `registry` (default: https://hub.docker.com)
- Build the image using cache (ie: using the pulled stages)
- Push each stage of the built image to the registry with the name `<image_name>-stages:<1,2,3,...>`
- Push the image itself like `<image_name>:<image_tag>`
- (Optional) Push any git tag if available as `<image_name>:<git_tag>`

## Example usage

Minimal example:

```yml
- uses: whoan/docker-build-with-cache-action@v4
  with:
    image_name: whoan/node
```

You can see a full **[working example in this repo](https://github.com/whoan/docker-images/blob/master/.github/workflows/node-alpine-slim.yml)** using GitHub's registry:

```yml
- uses: whoan/docker-build-with-cache-action@v4
  with:
    username: "${{ secrets.DOCKER_USERNAME }}"
    password: "${{ secrets.DOCKER_PASSWORD }}"
    image_name: whoan/docker-images/node
    image_tag: alpine-slim
    push_git_tag: true
    registry: docker.pkg.github.com
    context: node-alpine-slim
    build_extra_args: "--compress=true --build-arg=hello=world"
```

> More info [here](https://help.github.com/en/github/managing-packages-with-github-packages/configuring-docker-for-use-with-github-packages#authenticating-to-github-packages) on how to get username/password for GitHub's registry.

Another example for **Google Cloud Platform** and more custom settings:

```yml
- uses: whoan/docker-build-with-cache-action@v4
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

## Cache is not working?

Be aware of the conditions that can invalidate your cache:

- Be specific with the base images. If you start from an image with `latest` tag, it may download different versions when the action is triggered, and it will invalidate the cache.

## License

[MIT](https://github.com/whoan/docker-build-with-cache-action/blob/master/LICENSE)
