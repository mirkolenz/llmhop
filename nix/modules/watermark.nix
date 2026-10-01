# vLLM watermarking, configured declaratively apart from the key. The key is
# the systemd credential `vllm.watermark-key`, imported from the system
# credential store unless a workload's `credentials` names another source,
# which `mkVllmWatermark`'s script merges into the configuration in-process,
# so it enters neither the Nix store nor a command line. Shared by the
# generating workers and the detectors of both vLLM backends.
lib:
let
  inherit (lib) mkOption types;
  inherit (import ./lib.nix lib) containerRuntimeDirectory modelSettings;

  credential = "vllm.watermark-key";
  containerScript = "${containerRuntimeDirectory}/watermark.py";
in
{
  source = ../pkgs/mkVllmWatermark/watermark.py;
  mkScript = pkgs: pkgs.callPackage ../pkgs/mkVllmWatermark/package.nix { };

  # Argv running the script's `command` with `package`'s Python.
  nativeCommand = package: script: command: [
    (lib.getExe' package "python")
    script
    command
  ];

  # Container extras running the script's `command`, mounted into the image,
  # with the image's Python.
  container = script: command: {
    arguments = [
      containerScript
      command
    ];
    containerConfig.Entrypoint = lib.toJSON [ "python" ];
    mounts = [ "${script}:${containerScript}:ro" ];
  };

  # Submodule extension adding `watermark` and granting its key, optional for
  # model workers and always set for detectors.
  module =
    { optional }:
    { config, ... }:
    {
      options.watermark = mkOption {
        type = with types; if optional then nullOr (attrsOf anything) else attrsOf anything;
        default = if optional then null else { };
        example = {
          algorithm = "dual_key_gumbel";
          context_width = 4;
        };
        description = ''
          vLLM's `WatermarkConfig` without `key`, validated at startup by the
          installed release. A generating worker and its detector must share
          it.

          The key, an unsigned 64-bit integer, is the credential
          `${credential}`. It is imported from the system credential store,
          for example the root-only file `/etc/credstore/${credential}`,
          unless `credentials."${credential}"` names another source. An
          encrypted credential must be created under that name, e.g. with
          `systemd-creds encrypt --name=${credential}`.
        '';
      };
      config = lib.mkIf (config.watermark != null) {
        credentials.${credential} = lib.mkDefault { };
      };
    };

  # Flags `mkVllmWatermark`'s script reads, managed so `settings` cannot
  # displace them.
  flags =
    watermark:
    lib.optionalAttrs (watermark != null) {
      watermark-config = watermark;
      watermark-key-file = "\${cred:${credential}}";
    };

  # An inline configuration would put the key into the Nix store and onto the
  # command line, so only `watermark` may configure watermarking, and only the
  # credential provide its key.
  assertions =
    backend: cfg:
    let
      check =
        collection: name: workload: settings:
        let
          prefix = "services.llmhop.${backend}.${collection}.${name}";
        in
        [
          {
            assertion = !lib.any (lib.hasPrefix "watermark-config") (lib.attrNames settings);
            message = "${prefix} sets `watermark-config` in its settings. Use its `watermark` option, which keeps the key out of the Nix store.";
          }
          {
            assertion = !(workload.watermark ? key);
            message = "${prefix}.watermark sets `key`, which the `${credential}` credential provides.";
          }
        ];
    in
    lib.concatLists (
      lib.mapAttrsToList (name: model: check "models" name model (modelSettings cfg model)) cfg.models
      ++ lib.mapAttrsToList (
        name: detector: check "detectors" name detector detector.settings
      ) cfg.detectors
    );
}
