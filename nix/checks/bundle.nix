# Bundles Quadlet backends and the llmhop gateway for a host without Nix, and
# rejects what cannot be bundled.
{
  lib,
  mkQuadletBundle,
  runCommand,
}:
let
  config = {
    gateway = {
      type = "llmhop-quadlet";
      llmhop-quadlet = {
        credentials."llmhop.client-token" = null;
        settings.authTokens = [ "\${cred:llmhop.client-token}" ];
      };
    };
    vllm-quadlet = {
      enable = true;
      image = "docker.io/vllm/vllm-openai:latest";
      fetch.interval = "weekly";
      models.qwen = {
        model = "Qwen/Qwen3-8B";
        port = 8001;
        watermark.algorithm = "gumbel";
      };
      detectors.detector = {
        port = 8002;
        profiles.qwen.tokenizer = "Qwen/Qwen3-8B";
      };
    };
  };
  bundle = mkQuadletBundle { modules = [ { services.llmhop = config; } ]; };
  rejects =
    services:
    !(lib.tryEval (mkQuadletBundle { modules = [ { services.llmhop = services; } ]; }).drvPath).success;
in
assert rejects {
  vllm = {
    enable = true;
    package = bundle;
    models.qwen.model = "Qwen/Qwen3-8B";
  };
};
assert rejects { gateway.type = "llmhop"; };
runCommand "llmhop-bundle-tests" { } ''
  set -euo pipefail
  cd ${bundle}
  test -f etc/containers/systemd/vllm-qwen.container
  test -f etc/containers/systemd/vllm-detector.container
  test -f etc/tmpfiles.d/10-llmhop.conf

  # Every asset a unit references is bundled.
  grep -rhoE '/usr/local/lib/llmhop/[^ :",]+' etc | sort -u | while read -r asset; do
    test -e ".$asset"
  done

  grep -qx 'PartOf=vllm-image.service' etc/containers/systemd/vllm-qwen.container
  grep -qx 'PartOf=llmhop-image.service' etc/containers/systemd/llmhop.container
  grep -qE '^ExecStartPre="/usr/local/lib/llmhop/[^ ]+-llmhop-[^/]+/bin/llmhop" "hub-prune" ' etc/systemd/system/vllm-qwen-refresh.service
  grep -qx 'ExecStart=+/usr/bin/systemctl try-restart --no-block vllm-qwen.service' etc/systemd/system/vllm-qwen-refresh.service
  grep -qx 'Requires=vllm-qwen-fetch.service' etc/systemd/system/vllm-qwen-refresh.service
  grep -qx 'OnCalendar=weekly' etc/systemd/system/vllm-quadlet-update.timer
  grep -qE '^Image=docker-archive:/usr/local/lib/llmhop/[^ ]+\.tar\.gz$' etc/containers/systemd/llmhop.image
  touch $out
''
