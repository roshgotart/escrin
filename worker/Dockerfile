FROM node:20-bookworm AS runner-builder

WORKDIR /escrin

RUN npm install -g pnpm

ARG WORKERD_TAG
RUN curl -sSL \
  https://github.com/escrin/workerd/releases/download/${WORKERD_TAG}/workerd-linux-64.gz \
  | gunzip > workerd
RUN chmod a+x workerd

COPY ./ ./


RUN pnpm --filter "@escrin/worker" install --frozen-lockfile
RUN pnpm --filter "@escrin/worker" build

ARG DEPLOY_ENV
RUN ./workerd compile worker/config/ne.capnp > escrin-runner

FROM gcr.io/distroless/cc-debian12

COPY --from=runner-builder /escrin/escrin-runner /escrin-runner

ENTRYPOINT ["/escrin-runner", "serve", "--verbose", "--experimental"]
