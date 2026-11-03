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
      }
    ) timers;
  # A drop-in rather than `systemctl enable`, so retiring a timer only
  # removes files, like it does for Quadlet units.
  triggersPath = "etc/systemd/system/timers.target.d/llmhop.conf";
  triggersFile = builtins.toFile "llmhop.conf" (toUnit {
    Unit.Wants = triggers;
  });

  # The rules of every llmhop setting, as NixOS renders them.
  tmpfiles = lib.findFirst (
    package: package.name == "10-llmhop.conf"
  ) null config.systemd.tmpfiles.packages;
  tmpfilesPath = "etc/tmpfiles.d/10-llmhop.conf";

  files = map quadletFile quadletUnits ++ plainFiles;

  # Every file the bundle installs below `/etc`, by its path there.
  etcFiles =
    lib.listToAttrs (
      map (file: lib.nameValuePair file.path (builtins.toFile (baseNameOf file.path) file.text)) files
    )
    // lib.optionalAttrs (tmpfiles != null) {
      ${tmpfilesPath} = "${tmpfiles}/lib/tmpfiles.d/10-llmhop.conf";
    }
    // lib.optionalAttrs (triggers != [ ]) { ${triggersPath} = triggersFile; };

  assetDirectory = lib.escapeShellArg cfg.assetDirectory;

  # The units and files of the installed bundle, by which the next one finds
  # those it drops.
  manifests = lib.mapAttrs (name: lines: builtins.toFile name (lib.concatLines lines)) {
    units = map (file: file.unit) files;
    files = map (path: "/${path}") (lib.attrNames etcFiles);
  };
  manifest = name: lib.escapeShellArg "${cfg.assetDirectory}/${name}";
  # The lines of the installed manifest `name` missing from the one at
  # `kept name`, if any is installed.
  dropped = kept: name: "grep -svxFf ${kept name} ${manifest name}";
  # Stops the installed units and removes the installed files that the
  # manifests at `kept` lack. A unit that never loaded, such as one the
  # generator rejected, does not abort.
  retire = kept: ''
    ${dropped kept "units"} | xargs -r systemctl stop || true
    ${dropped kept "files"} | xargs -r rm -f
  '';

  # A POSIX shell script for the host, linted at build time.
  script =
    name: text:
    pkgs.writeTextFile {
      inherit name;
      text = "#!/bin/sh\nset -eu\n" + text;
      executable = true;
      checkPhase = "${lib.getExe pkgs.shellcheck} $target";
    };

  # Restarts every running unit whose file the installation changes, an image
  # unit with every container requiring it. The units of the previous bundle
  # that this one drops stop before their files and assets go.
  installScript = script "install.sh" ''
    # Installs this bundle, starts its units and restarts those it changed,
    # collected as the positional parameters.
    cd "$(dirname "$0")"
    set --
    ${lib.concatMapStrings (bundled: ''
      cmp -s ${lib.escapeShellArg bundled.path} ${lib.escapeShellArg "/${bundled.path}"} || set -- "$@" ${lib.escapeShellArg bundled.unit}
    '') files}
    ${retire (name: ".${manifest name}")}
    cp -r etc/. /etc/
    rm -rf ${assetDirectory}
    mkdir -p ${assetDirectory}
    cp -r .${assetDirectory}/. ${assetDirectory}/
    systemctl daemon-reload
    ${lib.optionalString (tmpfiles != null) "systemd-tmpfiles --create /${tmpfilesPath}"}
    systemctl start --no-block ${
      lib.escapeShellArgs (map (unit: "${unit.serviceName}.service") wantedUnits ++ triggers)
    }

    if [ $# -gt 0 ]; then
      systemctl try-restart --no-block "$@"
    fi
  '';

  # Installed beside the assets, so it outlives the bundle it came with.
  uninstallScript = script "uninstall.sh" ''
    # Stops and removes the installed bundle, but keeps the state directories
    # its tmpfiles rules created, such as the hub cache.
    ${retire (_: "/dev/null")}
    rm -rf ${assetDirectory}
    systemctl daemon-reload
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
          install -Dm755 ${installScript} $out/install.sh
          install -Dm755 ${uninstallScript} $out${assetDirectory}/uninstall.sh
          ${lib.concatMapAttrsStringSep "\n" (
            path: source: "install -Dm644 ${source} $out/${lib.escapeShellArg path}"
          ) etcFiles}
          ${lib.concatMapAttrsStringSep "\n" (
            name: source: "install -Dm644 ${source} $out${manifest name}"
          ) manifests}
          # Dereferenced, since symlinks such as those of `linkFarm` point
          # into the store.
          ${lib.concatMapStrings (asset: ''
            cp -rL ${asset} $out${assetDirectory}/
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
