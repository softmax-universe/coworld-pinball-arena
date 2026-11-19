# The Coworld image of Pinball Arena, for episodes that Softmax runs: the command-line runner (one Episode, no
# window) behind a small game server. See coworld/README.md.
FROM --platform=linux/amd64 ubuntu:24.04 AS compiler
RUN ["apt-get", "update"]
RUN ["apt-get", "install", "-y", "--no-install-recommends", "gcc", "g++", "git", "curl", "ca-certificates", "xz-utils"]
RUN ["curl", "-fsSL", "-o", "/tmp/nim.tar.xz", "https://github.com/nim-lang/nightlies/releases/download/2026-04-24-version-2-2-bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef/nim-2.2.10-linux_x64.tar.xz"]
RUN ["tar", "xJf", "/tmp/nim.tar.xz", "-C", "/opt"]
RUN ["curl", "-fsSL", "-o", "/usr/local/bin/nimby", "https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64"]
RUN ["chmod", "+x", "/usr/local/bin/nimby"]
ENV PATH=/opt/nim-2.2.10/bin:$PATH
WORKDIR /workspace/deps
COPY nimby.lock /workspace/nimby.lock
RUN ["nimby", "sync", "/workspace/nimby.lock"]
WORKDIR /workspace
COPY config.nims ./
COPY src src
COPY players players
RUN ["nim", "c", "-d:release", "--hints:off", "--nimcache:/tmp/nimcache", "--out:/out/headless", "src/pinball/headless.nim"]

FROM --platform=linux/amd64 docker.io/library/python:3.12-slim
RUN pip install --no-cache-dir websockets==15.0.1
WORKDIR /app
COPY --from=compiler /out/headless /app/headless
COPY coworld/server.py coworld/viewer.html /app/
ENV PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["python", "/app/server.py"]
