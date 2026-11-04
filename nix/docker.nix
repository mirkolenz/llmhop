# The llmhop image, streamed for publishing or, with `stream = false`, as the
# archive that the llmhop-quadlet gateway loads.
{
  dockerTools,
  tzdata,
  lib,
  llmhop,
  stream ? true,
}:
(if stream then dockerTools.streamLayeredImage else dockerTools.buildLayeredImage) {
  name = "llmhop";
  contents = [
    dockerTools.caCertificates
    dockerTools.fakeNss
    llmhop
    tzdata
  ];
  extraCommands = ''
    mkdir -m 1777 tmp
  '';
  config = {
    Entrypoint = [ (lib.getExe llmhop) ];
    Cmd = [
      "serve"
      "/config.json"
    ];
    User = "nobody:nobody";
    # The mounted config must set `listen: [":8080"]`.
    ExposedPorts."8080/tcp" = { };
    Labels = {
      "org.opencontainers.image.source" = "https://github.com/mirkolenz/llmhop";
      "org.opencontainers.image.licenses" = "MIT";
      "org.opencontainers.image.title" = "llmhop";
      "org.opencontainers.image.description" = llmhop.meta.description;
    };
  };
}
