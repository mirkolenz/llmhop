{
  lib,
  dockerTools,
  cacert,
  tzdata,
  llmhop,
}:
dockerTools.streamLayeredImage {
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
