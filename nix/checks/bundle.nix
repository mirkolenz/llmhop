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
  for file in vllm-qwen.container vllm-qwen-fetch.container vllm-detector.container vllm.image llmhop.container llmhop.image; do
    test -f etc/containers/systemd/$file
  done

  # Every asset a unit references is bundled.
  grep -rhoE '/usr/local/lib/llmhop/[^ :"]+' etc | sort -u | while read -r asset; do
    test -e ".$asset"
  done

  grep -qx 'WantedBy=multi-user.target' etc/containers/systemd/vllm-qwen.container
  grep -qE '^ExecStart=\+"/usr/local/lib/llmhop/[^ ]+-hub-cache-[^/]+/bin/hub-cache" "restart" "vllm-qwen"$' etc/systemd/system/vllm-qwen-refresh.service
  ! grep -q PATH= etc/systemd/system/vllm-qwen-refresh.service
  grep -qx 'Requires=vllm-qwen-fetch.service' etc/systemd/system/vllm-qwen-refresh.service
  grep -qx 'PathChanged=/var/cache/vllm/qwen/hub/models--Qwen--Qwen3-8B/snapshots' etc/systemd/system/vllm-qwen-refresh.path
  grep -qE 'Volume=/usr/local/lib/llmhop/[^ ]+-fetch.sh:' etc/containers/systemd/vllm-qwen-fetch.container
  grep -qx 'OnCalendar=weekly' etc/systemd/system/vllm-update.timer
  grep -q '/usr/bin/systemctl restart vllm-qwen-fetch.service' etc/systemd/system/vllm-update.service
  test -f etc/tmpfiles.d/10-llmhop.conf
  grep -qE '^Image=docker-archive:/usr/local/lib/llmhop/[^ ]+\.tar\.gz$' etc/containers/systemd/llmhop.image
  grep -q '^ImageTag=localhost/llmhop:' etc/containers/systemd/llmhop.image
  if grep -q AutoUpdate etc/containers/systemd/llmhop.container; then
    exit 1
  fi
  grep -q 'enable --now .*vllm-qwen-refresh.path' install.sh
  grep -q 'cmp -s etc/containers/systemd/vllm-qwen.container /etc/containers/systemd/vllm-qwen.container || changed="$changed vllm-qwen.service"' install.sh
  sh -n install.sh
  touch $out
''
