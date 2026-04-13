{
  lib,
  dockerTools,
  cacert,
  tzdata,
  llmhop,
}:
dockerTools.streamLayeredImage {
  name = "llmhop";
  tag = "latest";
  created = "now";
  contents = [
    cacert
    tzdata
  ];
  extraCommands = ''
    mkdir -m 1777 tmp
  '';
  config.Entrypoint = [ (lib.getExe llmhop) ];
}
