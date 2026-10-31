# The llmhop image, streamed for publishing or, with `stream = false`, as the
# archive that the llmhop-quadlet gateway loads.
{
  dockerTools,
  cacert,
  tzdata,
  lib,
  llmhop,
  stream ? true,
}:
(if stream then dockerTools.streamLayeredImage else dockerTools.buildLayeredImage) {
  name = "llmhop";
  contents = [
    cacert
    tzdata
  ];
  extraCommands = ''
    mkdir -m 1777 tmp
  '';
  config.Entrypoint = [ (lib.getExe llmhop) ];
}
