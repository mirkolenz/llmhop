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
      "-config"
      "/config.json"
    ];
    User = "nobody:nobody";
    # The default port of the config.
    ExposedPorts."8080/tcp" = { };
  };
}
