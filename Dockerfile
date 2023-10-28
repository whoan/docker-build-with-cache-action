FROM docker:24.0.7

LABEL "maintainer"="whoan <juaneabadie@gmail.com>"
LABEL "repository"="https://github.com/whoan/docker-build-with-cache-action"

RUN apk add --no-cache bash grep jq yq aws-cli

COPY --link docker-build.sh /docker-build.sh
COPY --link entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
