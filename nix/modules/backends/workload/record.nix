# The type of the record of a workload, which `records.nix` derives from its
# options and every unit, the gateway and the assertions read. Its
# capabilities, such as `gpu` or `unlisted`, tell consumers what the
# workload needs instead of what kind it is.
lib:
let
  inherit (lib) mkOption types;
  field = type: description: mkOption { inherit type description; };
in
{
  recordModule.options = {
    name = field types.str "Name of the workload, the `model` clients send.";
    unit = field types.str "Name of its server unit.";
    owner = field types.str "Option path of the workload, naming it in the claims.";
    description = field types.str "Description of its server unit.";
    port = field (with types; nullOr port) "Port it binds, or null for its socket.";
    host = field types.str "Address it binds `port` to, or a container publishes it on.";
    socket = field (with types; nullOr str) "Unix socket it binds, or null for its port.";
    exposed = field types.bool "Whether it is reachable beyond loopback.";
    offline = field types.bool "Whether its server runs without network access.";
    openFirewall = field types.bool "Whether its port is opened in the firewall.";
    package = field types.package "Environment of its server natively.";
    fetches = field types.bool "Whether a native fetcher downloads its repositories.";
    repositories = field (types.listOf (
      types.submodule {
        options = {
          repo = field types.str "Hugging Face repository.";
          tag = field (with types; nullOr str) "Quantization tag of llama.cpp, or null.";
          revision = field (with types; nullOr str) "Branch, tag or commit, or null for the default branch.";
          include = field (with types; listOf str) "Glob patterns of the files to download, or all if empty.";
        };
      }
    )) "Repositories its fetcher downloads.";
    command = field (
      with types;
      listOf (oneOf [
        str
        path
        package
      ])
    ) "Command of its server, followed by `settings`.";
    settings = field (
      with types; attrsOf json
    ) "Flags of its server, its `settings` with the derived ones.";
    credentials = field (
      with types; attrsOf (nullOr str)
    ) "Credentials of its server, with its watermark keys.";
    environment = field (with types; attrsOf str) "Environment of its server, over the backend's.";
    environmentFile = field (with types; nullOr str) "File of further environment of its server.";
    mounts = field (with types; listOf str) "Further volumes of its container.";
    aliases = field (with types; attrsOf (nullOr str)) ''
      Further names it serves, its LoRA adapters, each with the `model` the
      gateway rewrites a request to, or null to forward it verbatim.
    '';
    dataParallelSize = field (types.ints.between 1 256) "Ranks the gateway pins requests to.";
    watermarks = field (types.listOf (
      types.submodule {
        options = {
          credential = field types.str "Credential holding the key.";
          secondaryCredential = field (with types; nullOr str) "Credential holding the second key, or null.";
          settings = field (with types; attrsOf json) "Watermark config without its keys.";
        };
      }
    )) "Watermarks of a model, or of the profiles of a detector.";
    unlisted = field types.bool "Whether the gateway routes it outside the models API.";
    chained = field types.bool "Whether it joins the startup chain of its backend.";
    gpu = field (types.nullOr (
      types.submodule {
        options = {
          nativeDevices = field (with types; nullOr (listOf str)) "`DeviceAllow=` entries, or null for all.";
          containerDevices = field (with types; listOf str) "`AddDevice=` entries of its container.";
          shmSize = field types.str "Size of the `/dev/shm` of its container.";
        };
      }
    )) "GPU access of a model, or null for an auxiliary service.";
    assertions = field (types.listOf (
      types.submodule {
        options = {
          assertion = field types.bool "Whether the workload is valid.";
          message = field types.str "Error if it is not.";
        };
      }
    )) "Checks of its configuration.";
  };
}
