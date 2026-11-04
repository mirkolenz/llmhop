# Names the bundle of quadlet-nix after llmhop, adds its tmpfiles rules and
# rejects the backends and gateways that it cannot hold.
{ config, lib, ... }:
let
  llmhop = config.services.llmhop;
  native = lib.filter (engine: llmhop.${engine}.enable) (lib.attrNames (import ./engines.nix lib));
  gateway = llmhop.gateway.type;
in
{
  virtualisation.quadlet.bundle = {
    name = "llmhop";
    tmpfiles = [ "10-llmhop" ];
    assertions = [
      {
        assertion = native == [ ];
        message = "services.llmhop: only Quadlet backends can be bundled, but `${lib.concatStringsSep "`, `" native}` is enabled.";
      }
      {
        assertion = gateway == null || lib.hasSuffix "-quadlet" gateway;
        message = "services.llmhop: only Quadlet gateways can be bundled, but the gateway is `${toString gateway}`.";
      }
    ];
  };
}
