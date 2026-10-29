# Lab 02: the base lab image plus wget. Built on top of the lab image so the
# base stays wget-free and Lab 02 can be repeated from the start.
FROM localhost/openshell-lab/leap:16.0

USER root
RUN zypper --non-interactive install --no-recommends wget \
 && zypper clean --all
USER sandbox
