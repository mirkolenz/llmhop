# Renders the Quadlet backends and gateway of a system into files for a host
# without Nix, which needs podman 5 and systemd. Every store path the
# units reference moves below `assetDirectory`, except `systemctl`, which maps
# to the host's own.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.services.llmhop.bundle;
  llmhop = config.services.llmhop;
  inherit (config.virtualisation) quadlet;
  inherit (builtins) storeDir;

  systemctl = lib.getExe' config.systemd.package "systemctl";

  # The file `path` of the bundle holding `text` as the host sees it, which
  # defines `unit`, beside the store paths it references, which carry the
  # context of `text`, so the bundle can copy them.
  file =
    path: unit: text:
    let
      withHostTools = lib.replaceStrings [ systemctl ] [ "/usr/bin/systemctl" ] text;
      matches = builtins.split "(${storeDir}/[0-9a-z]{32}-[-.+_?=0-9a-zA-Z]+)" withHostTools;
    in
    {
      inherit path unit;
      text = builtins.unsafeDiscardStringContext (
        lib.replaceStrings [ "${storeDir}/" ] [ "${cfg.assetDirectory}/" ] withHostTools
      );
      assets = lib.pipe matches [
        (lib.filter lib.isList)
        lib.concatLists
        (map (asset: builtins.appendContext asset (builtins.getContext text)))
      ];
    };

  # Every unit llmhop defines claims its name.
  claimed = name: llmhop.claims.unit ? ${name};
  quadletUnits = lib.filter (unit: claimed unit.serviceName) (
    lib.attrValues quadlet.containers ++ lib.attrValues quadlet.images
  );
  # The servers and gateway, which start at boot.
  wantedUnits = lib.filter (unit: unit.wantedBy != [ ]) quadletUnits;
  # A Quadlet file, installed into the targets that NixOS makes it wanted by.
  quadletFile =
    unit:
    file "etc/containers/systemd/${unit.ref}" "${unit.serviceName}.service" (
      unit.text
      + lib.optionalString (unit.wantedBy != [ ]) ''

        [Install]
        WantedBy=${lib.concatStringsSep " " unit.wantedBy}
      ''
    );

  # The plain units beside them, rendered here, since those of NixOS set a
  # store `PATH=`, and the timers triggering them.
  toUnit = lib.generators.toINI { listsAsDuplicateKeys = true; };
  plainFile =
    name: type: sections:
    file "etc/systemd/system/${name}.${type}" "${name}.${type}" (toUnit sections);
  quadletServices = map (unit: unit.serviceName) quadletUnits;
  services = lib.filterAttrs (
    name: _: claimed name && !lib.elem name quadletServices
  ) config.systemd.services;
  timers = lib.filterAttrs (_: service: service.startAt != [ ]) services;
  triggers = lib.mapAttrsToList (name: _: "${name}.timer") timers;
  plainFiles =
    lib.mapAttrsToList (
      name: service:
      plainFile name "service" {
        Unit = service.unitConfig;
        Service = service.serviceConfig;
      }
    ) services
    ++ lib.mapAttrsToList (
      name: service:
      plainFile name "timer" {
        Unit.Description = service.description;
        Timer.OnCalendar = service.startAt;
        Install.WantedBy = "timers.target";
      }
    ) timers;

  # The rules of every llmhop setting, as NixOS renders them.
  tmpfiles = lib.findFirst (
    package: package.name == "10-llmhop.conf"
  ) null config.systemd.tmpfiles.packages;

  files = map quadletFile quadletUnits ++ plainFiles;

  # Restarts every running unit whose file the installation changes, an image
  # unit with every container requiring it.
  installScript = ''
    #!/bin/sh
    # Installs this bundle, starts its units and restarts those it changed.
    set -eu
    cd "$(dirname "$0")"
    changed=
    ${lib.concatMapStrings (bundled: ''
      cmp -s ${bundled.path} /${bundled.path} || changed="$changed ${bundled.unit}"
    '') files}
    cp -r etc/. /etc/
    rm -rf ${cfg.assetDirectory}
    mkdir -p ${cfg.assetDirectory}
    cp -r .${cfg.assetDirectory}/. ${cfg.assetDirectory}/
    systemctl daemon-reload
    ${lib.optionalString (tmpfiles != null) "systemd-tmpfiles --create /etc/tmpfiles.d/10-llmhop.conf"}
    ${lib.optionalString (triggers != [ ]) "systemctl enable --now ${toString triggers}"}
    systemctl start --no-block ${
      lib.concatMapStringsSep " " (unit: "${unit.serviceName}.service") wantedUnits
    }

    if [ -n "$changed" ]; then
      systemctl try-restart --no-block $changed
    fi
  '';

  native = lib.filter (engine: llmhop.${engine}.enable) (lib.attrNames (import ./engines.nix lib));
  gateway = llmhop.gateway.type;
  errors =
    map (a: a.message) (lib.filter (a: !a.assertion) config.assertions)
    ++ lib.optional (
      native != [ ]
    ) "only Quadlet backends can be bundled, but `${lib.concatStringsSep "`, `" native}` is enabled."
    ++ lib.optional (
      gateway != null && !lib.hasSuffix "-quadlet" gateway
    ) "only Quadlet gateways can be bundled, but the gateway is `${gateway}`.";

  package =
    lib.throwIf (errors != [ ])
      "services.llmhop.bundle:\n${lib.concatMapStringsSep "\n" (error: "- ${error}") errors}"
      (
        pkgs.runCommand "llmhop-bundle" { } ''
          ${lib.concatMapStrings (file: ''
            install -Dm644 ${builtins.toFile (baseNameOf file.path) file.text} $out/${file.path}
          '') files}
          install -Dm755 ${builtins.toFile "install.sh" installScript} $out/install.sh
          ${lib.optionalString (tmpfiles != null) ''
            install -Dm644 ${tmpfiles}/lib/tmpfiles.d/10-llmhop.conf $out/etc/tmpfiles.d/10-llmhop.conf
          ''}
          mkdir -p $out${cfg.assetDirectory}
          ${lib.concatMapStrings (asset: ''
            cp -r ${asset} $out${cfg.assetDirectory}/
          '') (lib.unique (lib.concatMap (file: file.assets) files))}

          # Every asset must be self-contained. Nix base32 lacks `e`, so the
          # `eeee…` placeholders of `nuke-refs` pass.
          if grep -rlE '${storeDir}/[0-9a-df-np-sv-z]{32}-' $out; then
            echo "these bundle files still reference the Nix store" >&2
            exit 1
          fi
        ''
      );
in
{
  options.services.llmhop.bundle = {
    assetDirectory = mkOption {
      type = types.strMatching "/.+";
      default = "/usr/local/lib/llmhop";
      description = "Directory of the scripts and generated files that the units of a bundle reference.";
    };
    package = mkOption {
      type = types.package;
      readOnly = true;
      default = package;
      defaultText = lib.literalMD "the bundle of this system's Quadlet backends and gateways";
      description = ''
        The Quadlet backends and gateway of this system as files for a host
        without Nix, with podman 5 and systemd, below the root they
        belong to. Its `install.sh` copies them into place and starts them.
        Firewall and user options do not apply there.
      '';
    };
  };
}
