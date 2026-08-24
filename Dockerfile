FROM scratch

LABEL org.opencontainers.image.title="SnakeMP" \
      org.opencontainers.image.description="Minimal runtime image for the prebuilt SnakeMP Zig server" \
      io.snakemp.runtime="true"

# The host-side start-docker.sh script builds this static executable first.
# Keeping compilation out of this file makes the final image contain only the
# runtime binary.
COPY --chmod=0555 servers/zig/snek-zig /snek-zig

ENV PORT=9687
EXPOSE 9687/tcp

USER 65532:65532
ENTRYPOINT ["/snek-zig"]
