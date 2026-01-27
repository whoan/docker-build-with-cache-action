FROM docker:29.2.0

LABEL "maintainer"="whoan <juaneabadie@gmail.com>"
LABEL "repository"="https://github.com/whoan/docker-build-with-cache-action"

RUN apk add --no-cache bash grep jq yq aws-cli

COPY docker-build.sh /docker-build.sh
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
