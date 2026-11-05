# Bundles Quadlet backends and the llmhop gateway for a host without Nix,
# rejects what cannot be bundled, and checks that `vllm-bundle` holds a
# single container.
{
  lib,
  mkQuadletBundle,
  runCommand,
  vllm-bundle,
}:
let
  config = {
    gateway = {
      type = "llmhop";
      llmhop = {
        credentials."llmhop.client-token" = null;
        settings.authTokens.client = "\${cred:llmhop.client-token}";
      };
    };
    vllm = {
      enable = true;
      container.image = "docker.io/vllm/vllm-openai:latest";
      fetch.schedule = "weekly";
      models.qwen = {
        model = "Qwen/Qwen3-8B";
        port = 8001;
        offline = false;
        watermark.settings.algorithm = "gumbel";
      };
      detectors.detector = {
        port = 8002;
        offline = false;
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
    runtime = "native";
    package = bundle;
    models.qwen.model = "Qwen/Qwen3-8B";
  };
};
assert rejects {
  gateway = {
    type = "llmhop";
    llmhop.runtime = "native";
  };
};
assert rejects {
  vllm = {
    enable = true;
    cache.directory = null;
    container.image = "docker.io/vllm/vllm-openai:latest";
    models.qwen.model = "Qwen/Qwen3-8B";
  };
};
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
  grep -qx 'Sockets=llmhop-default.socket' etc/containers/systemd/llmhop.container
  grep -qx 'ListenStream=127.0.0.1:8080' etc/systemd/system/llmhop-default.socket
  grep -qx 'Wants=llmhop-default.socket' etc/systemd/system/sockets.target.d/llmhop.conf
  grep -qE '^ExecStartPre="/usr/local/lib/llmhop/[^ ]+-llmhop-[^/]+/bin/llmhop" "internal" "hub-prune" ' etc/systemd/system/vllm-qwen-refresh.service
  grep -qx 'ExecStart=+/usr/bin/systemctl try-restart --no-block vllm-qwen.service' etc/systemd/system/vllm-qwen-refresh.service
  grep -qx 'Requires=vllm-qwen-fetch.service' etc/systemd/system/vllm-qwen-refresh.service
  grep -qx 'OnCalendar=weekly' etc/systemd/system/vllm-update.timer
  grep -qE '^Image=docker-archive:/usr/local/lib/llmhop/[^ ]+\.tar\.gz$' etc/containers/systemd/llmhop.image
  grep -qx 'Policy=missing' etc/containers/systemd/vllm.image

  cd ${vllm-bundle}/etc
  test "$(find . -type f | sort)" = "./containers/systemd/vllm-qwen3.8-27b.container
  ./systemd/system/multi-user.target.d/llmhop.conf"
  container=containers/systemd/vllm-qwen3.8-27b.container
  grep -qx 'Image=docker.io/vllm/vllm-openai:latest' $container
  grep -qx 'Volume=vllm-qwen3.8-27b:/var/cache/vllm/qwen3.8-27b' $container
  grep -qx 'AddDevice=nvidia.com/gpu=all' $container

  if grep -E '^(Pull|PartOf|Wants|After)=|HF_HUB_OFFLINE' $container; then
    exit 1
  fi

  touch $out
''
