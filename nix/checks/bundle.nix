# Bundles container backends and the gateway for a host without Nix, rejects
# the native runtime, and checks that `vllm-bundle` holds a single container.
{
  lib,
  mkQuadletBundle,
  runCommand,
  vllm-bundle,
}:
let
  config = {
    gateway = {
      enable = true;
      credentials."llmhop.client-token" = null;
      settings.authTokens.client = "\${cred:llmhop.client-token}";
    };
    vllm = {
      enable = true;
      container.image = "docker.io/vllm/vllm-openai:latest";
      models.qwen = {
        model = "Qwen/Qwen3-8B";
        port = 8001;
        watermark.settings.algorithm = "gumbel";
      };
      detectors.detector = {
        port = 8002;
        profiles.qwen.tokenizer = "Qwen/Qwen3-8B";
      };
    };
  };
  bundle = mkQuadletBundle { modules = [ { services.llmhop = config; } ]; };
in
assert
  !(lib.tryEval
    (mkQuadletBundle {
      modules = [
        {
          services.llmhop = config // {
            runtime = "native";
          };
        }
      ];
    }).drvPath
  ).success;
runCommand "llmhop-bundle-tests" { } ''
  set -euo pipefail
  cd ${bundle}
  test -f etc/containers/systemd/vllm-qwen.container
  test -f etc/containers/systemd/vllm-detector.container

  # Every asset a unit references is bundled.
  grep -rhoE '/usr/local/lib/llmhop/[^ :",]+' etc | sort -u | while read -r asset; do
    test -e ".$asset"
  done

  grep -qx 'PartOf=llmhop-default.socket' etc/containers/systemd/llmhop.container
  grep -qx 'PartOf=llmhop-image.service' etc/containers/systemd/llmhop.container
  grep -qx 'Sockets=llmhop-default.socket' etc/containers/systemd/llmhop.container
  grep -qx 'ListenStream=127.0.0.1:8080' etc/systemd/system/llmhop-default.socket
  grep -qx 'Wants=llmhop-default.socket' etc/systemd/system/sockets.target.d/llmhop.conf
  grep -qE '^Image=docker-archive:/usr/local/lib/llmhop/[^ ]+\.tar\.gz$' etc/containers/systemd/llmhop.image
  grep -qx 'Volume=%d:/run/llmhop/credentials:ro,idmap' etc/containers/systemd/llmhop.container
  grep -qE '^Volume=/usr/local/lib/llmhop/[^ ]+-watermark.py:/run/llmhop/watermark.py:ro$' etc/containers/systemd/vllm-detector.container

  cd ${vllm-bundle}/etc
  test "$(find . -type f | sort)" = "./containers/systemd/vllm-qwen3.8-27b.container
  ./systemd/system/multi-user.target.d/llmhop.conf"
  container=containers/systemd/vllm-qwen3.8-27b.container
  grep -qx 'Image=docker.io/vllm/vllm-openai:latest' $container
  grep -qx 'Volume=vllm-qwen3.8-27b:/var/cache/llmhop:idmap' $container
  grep -qx 'UserNS=auto:size=65536' $container
  grep -qx 'PublishPort=127.0.0.1:8000:8000' $container
  grep -qx 'AddDevice=nvidia.com/gpu=all' $container

  if grep -E '^(Pull|PartOf|Wants|After)=|HF_HUB_OFFLINE' $container; then
    exit 1
  fi

  touch $out
''
