FROM docker:19.03.2

LABEL "maintainer"="whoan <juaneabadie@gmail.com>"
LABEL "repository"="https://github.com/whoan/docker-build-with-cache-action"

COPY entrypoint.sh /entrypoint.sh

RUN apk add --no-cache bash

ENTRYPOINT ["/entrypoint.sh"]
