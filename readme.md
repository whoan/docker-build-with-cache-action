# Docker build-with-cache action

This action builds your docker image and caches the stages (supports multi-stage builds) to improve building times in subsequent builds.

By default, it pushes the image with all the stages to a registry (needs username and password), but you can disable this feature by setting `push_image_and_stages` to `false`.

Built-in support for the most known registries: Docker Hub, AWS ECR, GitHub's registry, and Google Cloud.

## Inputs

### Required

`image_name`: Image name (e.g. *node*).

### Optional

`username`: Docker registry's user (needed to push images to the repository, or to pull from a private repository).

`password`: Docker registry's password (needed to push images to the repository, or to pull from a private repository).

`registry`: Docker registry (default: *Docker Hub's registry*).

`image_tag`: Tag(s) of the image to build. Allows multiple comma-separated tags (e.g. `one,another`) (default: `latest`).

`context`: Docker context (default: `./`).

`dockerfile`: Dockerfile filename path (default: `"$context"/Dockerfile`)

`push_image_and_stages`: Set to `false` to avoid pushing to the registry. Useful when you use `on: pull_request` (default: `true`).

`push_git_tag`: In addition to `image_tag`, you can also push the git tag in your [branch tip][branch tip] (default: `false`).

`pull_image_and_stages`: Set to `false` to avoid pulling from the registry or to build from scratch (default: `true`).

`build_extra_args`: Provide extra arguments to `docker build` (e.g. `"--compress=true --build-arg=hello=world"`).

[branch tip]: https://stackoverflow.com/questions/16080342/what-is-a-branch-tip-in-git

## Outputs

None

## How it works

The action does the following every time it is triggered:

- (Optional) Pull previously pushed [stages](https://docs.docker.com/develop/develop-images/multistage-build/) (if any) from the specified `registry` (default: https://hub.docker.com)
- Build the image using cache (i.e. using any of the pulled stages)
- Tag the image (multiple tags are allowed)
- (Optional) Push the image with the tag(s) specified in `image_tag`
- (Optional) Push each stage of the built image to the registry with the name `<image_name>-stages:<1,2,3,...>`
- (Optional) Push the git tag (if available) as `<image_name>:<git_tag>`

## Example usage

Find working minimal examples for the most known registries in [this repo](https://github.com/whoan/hello-world/tree/master/.github/workflows).

### Docker Hub

> If you don't specify a registry, Docker Hub is the default

```yml
- uses: whoan/docker-build-with-cache-action@v5
  with:
    username: whoan
    password: "${{ secrets.DOCKER_HUB_PASSWORD }}"
    image_name: hello-world
```

### GitHub Registry

> [GitHub automatically creates a GITHUB_TOKEN secret to use in your workflow](https://help.github.com/en/actions/configuring-and-managing-workflows/authenticating-with-the-github_token#about-the-github_token-secret).

```yml
- uses: whoan/docker-build-with-cache-action@v5
  with:
    username: whoan
    password: "${{ secrets.GITHUB_TOKEN }}"  # you don't need to manually set this secret. GitHub does it on your behalf
    registry: docker.pkg.github.com
    image_name: hello-world
```

### Google Cloud Registry

> More info [here](https://cloud.google.com/container-registry/docs/advanced-authentication#json-key) on how to get GCloud JSON key.

```yml
- uses: whoan/docker-build-with-cache-action@v5
  with:
    username: _json_key
    password: "${{ secrets.GCLOUD_JSON_KEY }}"
    registry: gcr.io
    image_name: hello-world
```

### AWS ECR

> You don't even need to create the repositories in advance, as this action takes care of that for you!

```yml
- uses: whoan/docker-build-with-cache-action@v5
  with:
    username: "${{ secrets.AWS_ACCESS_KEY_ID }}"
    password: "${{ secrets.AWS_SECRET_ACCESS_KEY }}"
    registry: 861729690598.dkr.ecr.us-west-1.amazonaws.com
    image_name: hello-world
```

### Example with more options

```yml
- uses: whoan/docker-build-with-cache-action@v5
  with:
    username: whoan
    password: "${{ secrets.GITHUB_TOKEN }}"
    image_name: whoan/docker-images/node
    image_tag: alpine-slim,another-tag
    push_git_tag: true
    registry: docker.pkg.github.com
    context: node-alpine-slim
    dockerfile: custom.Dockerfile
    build_extra_args: "--compress=true --build-arg=hello=world"
    push_image_and_stages: false  # useful when you are setting a workflow to run on PRs
```

## Cache is not working?

Be aware of the conditions that can invalidate your cache:

- Be specific with the base images. If you start from an image with the `latest` tag, it may download different versions when the action is triggered, and it will invalidate the cache.

## License

[MIT](https://github.com/whoan/docker-build-with-cache-action/blob/master/LICENSE)
