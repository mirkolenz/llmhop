# The records of the enabled workloads of a backend, which every unit, the
# gateway and the assertions read: `key`, `name`, `unit`, `owner`,
# `description`, `port`, `host`, `socket`, `exposed`, `offline`,
# `openFirewall`, `package`, `fetches`, `repositories`, `command`,
# `settings`, `credentials`, `environment`, `environmentFile`, `mounts`,
# `aliases`, `dataParallelSize`, `unlisted`, `gpu` and `metricsPath`, null
# for a detector, and `assertions`.
lib:
let
  util = import ../../lib lib;
  inherit (import ./options.nix lib)
    watermarkScriptFor
    containerScript
    exposed
    isolable
    namePattern
    ;
in
rec {
  # Enabled workloads of `collection` sorted by ascending `name`, the order
  # servers are emitted and chained in, by the key they are declared under.
  sorted =
    collection:
    lib.pipe collection [
      (lib.filterAttrs (_: w: w.enable))
      (lib.mapAttrsToList (key: workload: { inherit key workload; }))
      (lib.sortOn (entry: entry.workload.name))
    ];

  # The flag of a key of `settings`, as vLLM reads `_` as `-`, `no-<key>`
  # negates `<key>` and `<key>.<field>` sets a field of it.
  flag =
    key:
    lib.removePrefix "no-" (lib.replaceStrings [ "_" ] [ "-" ] (lib.head (lib.splitString "." key)));

  # The repository `repo` of `engine` at `revision`, with the quantization tag
  # of llama.cpp split off.
  repository =
    engine: repo: revision:
    let
      parts = lib.splitString ":" repo;
      tagged = engine.tags && lib.length parts == 2;
    in
    {
      repo = if tagged then lib.head parts else repo;
      tag = if tagged then lib.last parts else null;
      inherit revision;
      include = [ ];
    };

  # Every enabled workload of the backend of `engine` as a record, so every
  # consumer agrees with the server. Its `settings` are those of the
  # workload with the ones llmhop derives, which the workload must not set.
  workloads =
    {
      engine,
      llmhop,
      pkgs,
    }:
    let
      cfg = llmhop.${engine.name};
      native = llmhop.runtime == "native";
      reference = credential: "\${cred:${credential}}";
      secondaryReference = watermark: lib.mapNullable reference watermark.secondaryCredential;
      # A watermark with the second key only SGLang has.
      normalize = watermark: { secondaryCredential = null; } // watermark;
      # The keys of `watermarks`, imported unless `credentials` names a file.
      keyCredentials =
        watermarks:
        lib.genAttrs (lib.filter (credential: credential != null) (
          lib.concatMap (watermark: [
            watermark.credential
            watermark.secondaryCredential
          ]) watermarks
        )) (_: null);
      # The flags of a watermark, reserved whether or not a model sets one.
      watermarkFlags = lib.optionals (engine.watermark != null) (
        lib.attrNames (engine.watermark.settings { settings = { }; } "" null)
      );

      # The Python of `package` or of the image running `script`, natively
      # checked against `package`, with the mount of a container.
      python = package: if native then [ (lib.getExe' package "python") ] else [ "python" ];
      scriptCommand =
        package: script: arguments:
        python package ++ [ (if native then script else containerScript) ] ++ arguments;
      scriptMounts = script: lib.optional (!native) "${script}:${containerScript}:ro";

      # A container binds its published port on every interface of its own
      # network, a native server its socket or `host`.
      listener =
        socketSettings: workload:
        if !native then
          {
            host = "0.0.0.0";
            inherit (workload) port;
          }
        else if workload.socket != null then
          socketSettings workload.socket
        else
          { inherit (workload) host port; };

      # The record of `workload`, declared under `<collection>.<key>`, from
      # the fields `rest` of its kind, its settings `forced` and the flags
      # `reserved` beside them, which `settings` must not set either, and
      # the `watermarks` whose keys it reads.
      record =
        {
          collection,
          noun,
          key,
          workload,
          forced,
          reserved ? [ ],
          watermarks ? [ ],
          assertions ? [ ],
        }:
        rest:
        let
          owner = "services.llmhop.${engine.name}.${collection}.${key}";
          isFlag = key: lib.elem (flag key) (map flag (lib.attrNames forced ++ reserved));
          clashing = lib.filter isFlag (lib.attrNames workload.settings);
          fetches = native && cfg.fetch.enable && rest.repositories != [ ];
        in
        {
          inherit key owner fetches;
          inherit (workload)
            name
            unit
            port
            host
            socket
            offline
            openFirewall
            package
            environment
            environmentFile
            ;
          description = "${engine.displayName} ${noun} ${workload.name}";
          exposed = exposed workload;
          settings = workload.settings // forced;
          credentials = keyCredentials watermarks // workload.credentials;
          aliases = { };
          dataParallelSize = 1;
          unlisted = false;
          gpu = null;
          metricsPath = null;
          assertions = [
            (util.firewallAssertion owner workload)
            {
              assertion = lib.match namePattern key != null;
              message = "services.llmhop: `${owner}` is declared under a key that cannot name its units, which takes letters, digits, underscores, dots and hyphens.";
            }
            {
              assertion = clashing == [ ];
              message = "services.llmhop: `${owner}.settings` or the backend's `modelSettings` set ${
                lib.concatMapStringsSep ", " (key: "`${key}`") clashing
              }, which llmhop derives from the other options.";
            }
            {
              assertion = workload.offline -> isolable llmhop.runtime workload;
              message = "services.llmhop: `${owner}` sets `offline = true`, which needs a native server on its socket or a loopback `host`, so set `offline = false`.";
            }
            {
              assertion = native && !cfg.fetch.enable && rest.repositories != [ ] -> !workload.offline;
              message = "services.llmhop: `${owner}` downloads its repositories itself without the backend's `fetch.enable`, so it needs `offline = false`.";
            }
            {
              assertion = native || workload.port != null;
              message = "services.llmhop: `${owner}` has no `port`, which a container publishes.";
            }
            {
              # It would enter the Nix store and the command line.
              assertion =
                !lib.any (watermark: lib.any (key: watermark.settings ? ${key}) engine.watermark.keys) watermarks;
              message = "services.llmhop: `${owner}` configures a watermark key inline, which its `credential` provides.";
            }
          ]
          ++ assertions;
        }
        // rest;

      model =
        { key, workload }:
        let
          watermark = lib.mapNullable normalize (workload.watermark or null);
          marked = watermark != null;
          loras = engine.loras != null && workload.loras != { };
          # In the shape of llmhop's config, the model of a body rewritten
          # for each adapter, or null to forward it verbatim.
          aliases = lib.optionalAttrs loras (
            lib.mapAttrs (adapter: _: { model = engine.loras.alias workload adapter; }) workload.loras
          );
          # SGLang reads its key from its config, which the script writes.
          wrapped = marked && engine.watermark.wrapped;
          script = watermarkScriptFor pkgs llmhop engine workload.package;
        in
        record
          {
            inherit key workload;
            collection = "models";
            noun = "model";
            reserved = watermarkFlags ++ engine.reservedSettings;
            watermarks = lib.optional marked watermark;
            forced =
              listener engine.socketSettings workload
              // engine.modelSettings workload
              // engine.shutdownSettings cfg.shutdownTimeoutSeconds
              # The default size of one stays off the command line, but
              # `settings` must not set it either way.
              // lib.optionalAttrs engine.dataParallel {
                data-parallel-size = if workload.dataParallelSize > 1 then workload.dataParallelSize else null;
              }
              // lib.optionalAttrs loras (engine.loras.settings workload.loras)
              // lib.optionalAttrs marked (
                engine.watermark.settings watermark (reference watermark.credential) (secondaryReference watermark)
              );
            assertions = [
              {
                assertion = !aliases ? ${workload.name};
                message = "services.llmhop: `services.llmhop.${engine.name}.models.${key}.loras` names an adapter `${workload.name}` like the model itself.";
              }
            ];
          }
          (
            {
              inherit aliases;
              repositories =
                lib.optional (util.isRepository workload.model) (
                  repository engine workload.model (workload.revision or null)
                )
                ++ map (repo: repository engine repo null) (
                  workload.extraRepositories ++ lib.optionals loras (lib.attrValues workload.loras)
                );
              command =
                (
                  if wrapped then
                    scriptCommand workload.package script [ "serve" ]
                  else if native then
                    engine.command.native workload.package
                  else
                    engine.command.container
                )
                ++ engine.positional workload;
              mounts = lib.optionals wrapped (scriptMounts script);
              inherit (engine) metricsPath;
              gpu = {
                nativeDevices = workload.native.devices;
                containerDevices = workload.container.devices;
                inherit (workload.container) shmSize;
              };
            }
            // lib.optionalAttrs engine.dataParallel { inherit (workload) dataParallelSize; }
          );

      detector =
        { key, workload }:
        record
          {
            inherit key workload;
            collection = "detectors";
            noun = "watermark detector";
            watermarks = lib.mapAttrsToList (_: profile: normalize profile.watermark) workload.profiles;
            forced = listener (path: { uds = path; }) workload // {
              engine = engine.name;
              profiles = lib.mapAttrs (_: profile: {
                inherit (profile) tokenizer revision;
                key_file = reference profile.watermark.credential;
                key_b_file = secondaryReference (normalize profile.watermark);
                config = profile.watermark.settings;
              }) workload.profiles;
            };
            assertions = [
              {
                assertion = workload.profiles != { };
                message = "services.llmhop: `services.llmhop.${engine.name}.detectors.${key}` has no `profiles`.";
              }
            ];
          }
          {
            # Only the files of a repository that a tokenizer may need.
            repositories = lib.pipe workload.profiles [
              lib.attrValues
              (lib.filter (profile: util.isRepository profile.tokenizer))
              (map (
                profile:
                repository engine profile.tokenizer profile.revision
                // {
                  include = [
                    "*.json"
                    "*.jinja"
                    "*.model"
                    "*.py"
                    "*.tiktoken"
                    "*.txt"
                  ];
                }
              ))
              lib.unique
            ];
            command = scriptCommand workload.package workload.script [ "detect" ];
            mounts = scriptMounts workload.script;
            unlisted = true;
          };
    in
    lib.optionals cfg.enable (
      map model (sorted cfg.models)
      ++ lib.optionals (engine.watermark != null) (map detector (sorted cfg.detectors))
    );
}
