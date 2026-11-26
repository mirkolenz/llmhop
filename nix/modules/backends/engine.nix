# The backend of `engine` under `services.llmhop.<name>`: its options, the
# claims and assertions both runtimes share, and the units of `native.nix`
# with `fetch.nix`, or of `container.nix`.
engine:
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  inherit (engine) name;
  llmhop = config.services.llmhop;
  cfg = llmhop.${name};
  native = llmhop.runtime == "native";
  inherit (cfg) workloads;
  # What the units of either runtime derive from.
  backend = {
    inherit
      lib
      pkgs
      utils
      engine
      llmhop
      cfg
      workloads
      ;
  };

in
{
  imports = [
    (lib.modules.importApply ./options.nix engine)
  ];

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf native (import ./native.nix backend))
      (lib.mkIf native (import ./fetch.nix backend))
      (lib.mkIf (!native) (import ./container.nix backend))
      {
        services.llmhop.claims = lib.mkMerge (
          map (
            w:
            {
              unit.${w.unit} = [ w.owner ];
            }
            // lib.optionalAttrs (w.port != null) {
              port.${toString w.port} = [ w.owner ];
            }
          ) workloads
        );

        services.llmhop.${name} = {
          # Below what the backend or a model sets, as every `modelSettings`.
          modelSettings = lib.mapAttrs (_: lib.mkDefault) engine.defaultModelSettings;

          fetch.credentials = lib.mkIf (cfg.fetch.hfTokenCredential != null) {
            ${cfg.fetch.hfTokenCredential} = lib.mkDefault null;
          };
        };

        assertions = lib.concatMap (w: w.assertions) workloads;

        networking.firewall.allowedTCPPorts = lib.pipe workloads [
          (lib.filter (w: w.exposed && w.openFirewall))
          (lib.catAttrs "port")
        ];
      }
    ]
  );
}
