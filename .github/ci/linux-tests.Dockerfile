ARG SWIFT_IMAGE
FROM ${SWIFT_IMAGE}

ARG TEST_UID
ARG TEST_GID
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/* \
    && (getent group "$TEST_GID" || groupadd --gid "$TEST_GID" test-runner) \
    && (getent passwd "$TEST_UID" || useradd --create-home --uid "$TEST_UID" --gid "$TEST_GID" test-runner)

USER ${TEST_UID}:${TEST_GID}
WORKDIR /workspace
