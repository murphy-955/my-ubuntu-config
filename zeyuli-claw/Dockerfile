FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates git \
    && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g openclaw --allow-scripts=openclaw,koffi,protobufjs,@google/genai \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN usermod -l node -d /home/node -m ubuntu && groupmod -n node ubuntu
USER node
WORKDIR /home/node

EXPOSE 18789
CMD ["openclaw", "gateway", "run", "--bind", "lan", "--port", "18789"]
