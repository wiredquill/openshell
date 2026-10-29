# Lab 06: the lab image plus Nous Research's Hermes Agent, configured for the
# lab's qwen vLLM server. Installed with Hermes's own installer (it refuses to
# build as a pip wheel), pinned to a release tag.
FROM localhost/openshell-lab/leap:16.0

# Hermes keeps its code, its private Python/uv/node toolchain, and its state
# (config, sessions, memories) in one data root. Using the install root as the
# data root means nothing has to be downloaded at runtime, when the sandbox
# has no route to PyPI. The agent user owns it, because Hermes writes there.
USER root
RUN install -d -o sandbox -g sandbox /opt/hermes
USER sandbox

ARG HERMES_REF=v0.22.2
RUN curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_REF}/scripts/install.sh" -o /tmp/install.sh \
 && HERMES_HOME=/opt/hermes bash /tmp/install.sh --branch "${HERMES_REF}" \
      --hermes-home /opt/hermes --dir /opt/hermes/hermes-agent \
      --non-interactive --skip-browser --skip-computer-use \
 && rm /tmp/install.sh

USER root
COPY --chmod=0755 hermes /usr/local/bin/hermes
USER sandbox

# Point Hermes at qwen. Fail fast instead of retrying for minutes when the
# sandbox blocks the connection: that's what the lab wants to see.
ARG OPENAI_BASE_URL=http://10.9.0.42:30400/v1
ARG OPENAI_MODEL=qwen3.8-27b
RUN hermes config set model.provider custom \
 && hermes config set model.base_url "${OPENAI_BASE_URL}" \
 && hermes config set model.default "${OPENAI_MODEL}" \
 && hermes config set agent.api_max_retries 1 \
 && hermes config set agent.auto_recovery_cycles 0
