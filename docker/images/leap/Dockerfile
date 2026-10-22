# openSUSE Leap 16 workload image for the OpenShell labs.
# OpenShell replaces CMD/ENTRYPOINT with its supervisor, so the image only
# needs a userspace, a non-root USER, and the tools the labs exercise.
FROM registry.opensuse.org/opensuse/leap:16.0

RUN zypper --non-interactive refresh \
 && zypper --non-interactive install --no-recommends \
      bash coreutils findutils which less file tar gzip \
      curl ca-certificates jq git-core \
      python3 \
      procps psmisc util-linux iproute2 bind-utils netcat-openbsd \
      strace libcap-progs shadow sudo \
 && zypper clean --all

# Workload identity. Docker uses the image USER when policy omits run_as_user.
RUN groupadd --gid 1000 sandbox \
 && useradd --uid 1000 --gid sandbox --create-home --shell /bin/bash sandbox \
 && install -d -o sandbox -g sandbox /sandbox
# Deliberately misconfigured: passwordless sudo. The process lab shows that
# OpenShell's no_new_privs + zero capabilities still stop escalation.
RUN echo 'sandbox ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/sandbox \
 && chmod 0440 /etc/sudoers.d/sandbox

# Fixtures for the filesystem lab. None of /lab is in OpenShell baseline
# paths, so every directory is invisible until a policy lists it.
RUN install -d -m 0755 /lab/public /lab/scratch /lab/secret \
 && echo "public data: readable when /lab/public is read_only" > /lab/public/readme.txt \
 && echo "TOP-SECRET: should never be readable"            > /lab/secret/creds.txt \
 && chown sandbox:sandbox /lab/scratch /lab/secret /lab/secret/creds.txt \
 && chmod 0600 /lab/secret/creds.txt
# Fixture outside baseline paths but inside the image, owned by the user:
# Unix permissions alone would allow access; Landlock must be what blocks it.
RUN install -d -o sandbox -g sandbox /opt/agent-home \
 && echo "owned by sandbox, but /opt is not in policy" > /opt/agent-home/notes.txt \
 && chown sandbox:sandbox /opt/agent-home/notes.txt

COPY --chmod=0755 probes/ /usr/local/bin/

WORKDIR /sandbox
USER sandbox
CMD ["/bin/bash", "-l"]
