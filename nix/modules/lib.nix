# Plain helpers shared by the backends and the gateways: CLI rendering,
# credentials, identities, systemd hardening and Quadlet containers.
lib:
let
  inherit (lib) mkOption types;
in
rec {
  # `host:port`, with IPv6 literals bracketed.
  hostPort =
    host: port:
    if lib.hasInfix ":" host then "[${host}]:${toString port}" else "${host}:${toString port}";

  isLoopback =
    host:
    lib.elem host [
      "127.0.0.1"
      "::1"
    ];

  # Assertion that the listener of `owner`, with its `host` and `openFirewall`,
  # opens no port that it serves on loopback only.
  firewallAssertion = owner: listener: {
    assertion = listener.openFirewall -> !isLoopback listener.host;
    message = "services.llmhop: `${owner}` sets `openFirewall`, but its `host` ${listener.host} is loopback, so set `host` to an address remote clients reach.";
  };

  # Whether `model` names a repository to fetch rather than a local path.
  isRepository = model: !lib.hasPrefix "/" model;

  # The path every server answers with success once it is ready.
  healthPath = "/health";

  # The address of a server listening on `socket`, or else on its bind
  # address, loopback for a wildcard, as `llmhop internal wait-healthy` takes
  # it.
  probeUrl =
    {
      socket,
      host,
      port,
      ...
    }:
    let
      probeHost =
        if host == "0.0.0.0" then
          "127.0.0.1"
        else if host == "::" then
          "::1"
        else
          host;
    in
    if socket != null then "unix://${socket}" else "http://${hostPort probeHost port}";

  # Render `settings` into the argv of a parser with the given `negateBools`
  # and `listStyle`, flag and value as separate entries. Strings, paths and
  # derivations render verbatim, everything else through JSON. See "CLI
  # dialects" in the module internals documentation.
  renderCliArgs =
    { negateBools, listStyle, ... }:
    settings:
    let
      cliValue = value: if lib.isStringLike value then toString value else lib.toJSON value;
      # `false` becomes `--no-<key>` (and `no-<key> = false` becomes `--<key>`)
      # for the parsers that auto-register the negated twin.
      negate =
        attrs:
        lib.mapAttrs' (
          name: value:
          if value == false then
            lib.nameValuePair (
              if lib.hasPrefix "no-" name then lib.removePrefix "no-" name else "no-${name}"
            ) true
          else
            lib.nameValuePair name value
        ) attrs;
      render =
        name: value:
        if value == null || value == false then
          [ ]
        else if value == true then
          [ "--${name}" ]
        else if !lib.isList value then
          [
            "--${name}"
            (cliValue value)
          ]
        else if listStyle == "values" then
          lib.optionals (value != [ ]) ([ "--${name}" ] ++ map cliValue value)
        else
          lib.concatMap (element: [
            "--${name}"
            (cliValue element)
          ]) value;
      rendered = if negateBools then negate settings else settings;
    in
    lib.concatLists (lib.mapAttrsToList render rendered);

  credentialsOption = mkOption {
    type = with types; attrsOf (nullOr externalPath);
    default = { };
    # A credential name becomes a systemd credential ID, a plain file name
    # under `$CREDENTIALS_DIRECTORY`, so anything systemd would reject is
    # caught here.
    apply = lib.mapAttrs (
      name: source:
      if lib.match "[[:alnum:]_][[:alnum:]_.-]{0,254}" name != null then
        source
      else
        throw "services.llmhop: `${name}` is not a valid systemd credential name. Start with an alphanumeric character or `_`, continue with those plus `.` and `-`, and stay within 255 characters."
    );
    example = lib.literalExpression ''
      {
        api-keys = "/run/secrets/api-keys";
        "llmhop.hf-token" = null;
      }
    '';
    description = ''
      Credentials granted exclusively to this service. A path outside the
      Nix store is loaded with `LoadCredential=`, while `null` imports the
      credential of the same name from the system credential store with
      `ImportCredential=`. Reference the read-only file from `settings` as
      `''${cred:<name>}`.
    '';
  };

  # The `[Service]` settings granting `credentials`. `toString` keeps a path
  # value from being copied into the Nix store.
  credentialServiceConfig = credentials: {
    LoadCredential = lib.mapAttrsToList (name: source: "${name}:${toString source}") (
      lib.filterAttrs (_: source: source != null) credentials
    );
    ImportCredential = lib.attrNames (lib.filterAttrs (_: source: source == null) credentials);
  };

  # Rewrite every `${cred:<name>}` reference in the strings of `value`, a
  # settings tree, to the path the credential is mounted at in `directory`,
  # so secrets reach the server as a file name rather than a value on the
  # command line.
  resolveCredentialRefs =
    directory: credentials: value:
    let
      names = lib.attrNames credentials;
      resolve =
        string:
        let
          resolved = lib.replaceStrings (map (name: "\${cred:${name}}") names) (map (
            name: "${directory}/${name}"
          ) names) string;
        in
        if lib.hasInfix "\${cred:" resolved then
          throw "services.llmhop: `${string}` references a credential that `credentials` does not declare."
        else
          resolved;
    in
    if lib.isString value then
      resolve value
    else if lib.isList value then
      map (resolveCredentialRefs directory credentials) value
    else if lib.isAttrs value && !lib.isDerivation value then
      lib.mapAttrs (_: resolveCredentialRefs directory credentials) value
    else
      value;

  # The tmpfiles rule creating `directory` for the `user` and `group` of
  # `owner` with `mode`.
  directoryRule = owner: mode: directory: {
    ${directory}.d = {
      inherit (owner) user group;
      inherit mode;
    };
  };

  # The tmpfiles rule of a root `directory`, which anyone may pass but not
  # list, such as that of every socket. See "Unix sockets" in the module
  # internals documentation.
  rootDirectoryRule = directoryRule {
    user = "root";
    group = "root";
  } "0711";

  # Hard-fail after 3 errors/hour so journald surfaces the underlying error
  # instead of an endless restart loop.
  startLimitConfig = {
    StartLimitBurst = 3;
    StartLimitIntervalSec = 3600;
  };

  # The `runtime` of a backend or gateway, whose units run natively as
  # hardened services or as Quadlet containers, defaulting to `default`.
  runtimeOption =
    default:
    mkOption {
      type = types.enum [
        "native"
        "quadlet"
      ];
      inherit default;
      defaultText = lib.literalExpression "config.services.llmhop.runtime";
      description = "Whether the units run natively as hardened services or as Quadlet containers.";
    };

  # The account options of llmhop and of the backends, a named account rather
  # than a `DynamicUser`, defaulting to `user`. `prefix` is the option path,
  # for the documented defaults, and `nativeOnly` marks an account that only
  # native units use.
  identityOptions =
    {
      name,
      cfg,
      prefix,
      user ? name,
      userText ? null,
      group ? cfg.user,
      groupText ? lib.literalExpression "config.${prefix}.user",
      runsAs ? "the native units and any refresh units run as, which owns their directories",
      nativeOnly ? false,
    }:
    let
      native = ''Only used if `runtime` is `"native"`.'';
      declaration = ''
        ${
          if nativeOnly then "The module" else ''If `runtime` is `"native"`, the module''
        } declares it while it keeps the name `${name}`, and otherwise the
        deployer declares it.${lib.optionalString nativeOnly " ${native}"}
      '';
    in
    {
      user = mkOption {
        type = types.str;
        default = user;
        ${if userText == null then null else "defaultText"} = userText;
        description = ''
          System user ${runsAs}.
          ${declaration}
        '';
      };
      uid = mkOption {
        type = with types; nullOr ints.unsigned;
        default = null;
        example = 503;
        description = "UID of the declared `user`. `null` lets NixOS allocate one. ${native}";
      };
      group = mkOption {
        type = types.str;
        default = group;
        defaultText = groupText;
        description = ''
          Primary group of `user`.
          ${declaration}
        '';
      };
      gid = mkOption {
        type = with types; nullOr ints.unsigned;
        default = cfg.uid;
        defaultText = lib.literalExpression "config.${prefix}.uid";
        description = "GID of the declared `group`. `null` lets NixOS allocate one. ${native}";
      };
    };

  # Declares the account of `identityOptions` while it keeps its default name.
  identityConfig =
    { name, cfg }:
    {
      users.users = lib.mkIf (cfg.user == name) {
        ${cfg.user} = {
          description = "${name} service user";
          isSystemUser = true;
          inherit (cfg) group uid;
        };
      };
      users.groups = lib.mkIf (cfg.group == name) { ${cfg.group}.gid = cfg.gid; };
    };

  # Universal systemd-exec(5) hardening of every native unit, gateways and
  # workers alike. See "Worker hardening" in the module internals
  # documentation.
  hardenedServiceConfig = {
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateIPC = true;
    PrivateMounts = true;
    PrivateTmp = true;
    PrivateUsers = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectSystem = "strict";
    MemoryDenyWriteExecute = true;
    LockPersonality = true;
    RemoveIPC = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
    ];
    SystemCallErrorNumber = "EPERM";
    ProtectProc = "invisible";
    ProtectHostname = true;
    ProcSubset = "pid";
  };

  # The hardened baseline of a native unit running as the account of `cfg`
  # and binding no IP socket.
  accountServiceConfig =
    cfg:
    hardenedServiceConfig
    // {
      User = cfg.user;
      Group = cfg.group;
      SocketBindDeny = "any";
    };

  # The sandbox of a unit running as the account of `owner` that writes only
  # `directory` and opens no socket, since an `owner` that is root could reach
  # systemd or Podman through one.
  hubSandbox =
    owner: directory:
    accountServiceConfig owner
    // {
      PrivateNetwork = true;
      SystemCallFilter = hardenedServiceConfig.SystemCallFilter ++ [ "~@network-io" ];
      ReadWritePaths = [ directory ];
    };

  # systemd's specifier of `$CREDENTIALS_DIRECTORY`, which it expands in
  # `Environment=` as well.
  credentialDirectory = "%d";

  # The `ExecStart=` of `command` with every `${cred:…}` resolved to systemd's
  # `%d`. A placeholder survives `utils.escapeSystemdExecArgs`, which would
  # turn `%d` into a literal, and is swapped for it afterwards.
  execStart =
    utils: credentials: command:
    let
      credentialPlaceholder = "@llmhopCredentialsDirectory@";
    in
    lib.replaceStrings [ credentialPlaceholder ] [ credentialDirectory ] (
      utils.escapeSystemdExecArgs (resolveCredentialRefs credentialPlaceholder credentials command)
    );

  # Root of everything llmhop mounts into a container. Its socket directory
  # sits beside, not over, the credential mount.
  containerRuntimeDirectory = "/run/llmhop";
  containerCredentialDirectory = "${containerRuntimeDirectory}/credentials";
  containerSocketDirectory = "${containerRuntimeDirectory}/socket";

  # The `:<options>` suffix of a Quadlet `Volume=`.
  mountSuffix = options: lib.optionalString (options != [ ]) ":${lib.concatStringsSep "," options}";

  # The read-only mount of a container's `credentials` with further `options`.
  credentialMount =
    options: credentials:
    lib.optional (credentials != { })
      "%d:${containerCredentialDirectory}${mountSuffix ([ "ro" ] ++ options)}";

  # The variable naming that mount, which systemd sets natively.
  credentialEnvironment =
    credentials:
    lib.optionalAttrs (credentials != { }) { CREDENTIALS_DIRECTORY = containerCredentialDirectory; };

  # Minimal hardening, Podman isolates the rest. The rootfs stays writable,
  # `/tmp` is a tmpfs for fast scratch.
  baseContainerConfig = {
    NoNewPrivileges = true;
    DropCapability = "all";
    Tmpfs = [ "/tmp" ];
  };

  imageOption = mkOption {
    type = types.str;
    description = "Container image reference, including a tag or digest. Only used if `runtime` is `\"quadlet\"`.";
  };

  # `[Container]` keys of every container of `noun`, over the generated ones,
  # typed by quadlet-nix's `sectionType`.
  containerConfigOption =
    sectionType: noun:
    mkOption {
      type = sectionType;
      default = { };
      example = {
        UserNS = "auto";
      };
      description = ''
        `[Container]` keys of every container of ${noun}, over the generated
        ones, such as `UserNS=` or `UIDMap=` and `GIDMap=` to run it without
        host root, or `User=`. Only used if `runtime` is `"quadlet"`.
      '';
    };

  # Podman volume options of the credential mount of `noun`.
  credentialMountOptionsOption =
    noun:
    mkOption {
      type = with types; listOf str;
      default = [ ];
      example = [ "idmap" ];
      description = ''
        Podman volume options of the credential mount of every container of
        ${noun}, which stays read-only. `idmap` lets a user namespace read the
        credentials owned by host root, and `idmap=uids=0-<uid>-1;gids=0-<gid>-1`
        a non-root `User=` in it. Only used if `runtime` is `"quadlet"`.
      '';
    };

  # The image unit `<name>-image` pulling `image`, its claim by `owner`, and
  # the `containerConfig` of a container running it.
  # An archive `image` loads as `tag`, and only a registry reference without
  # a digest auto-updates.
  imageUnit =
    {
      images,
      name,
      image,
      owner,
      tag ? null,
    }:
    {
      images.${name}.imageConfig = {
        Image = image;
      }
      // lib.optionalAttrs (tag != null) { ImageTag = tag; };
      claims.unit.${images.${name}.serviceName} = [ owner ];
      unitConfig.PartOf = [ "${images.${name}.serviceName}.service" ];
      containerConfig = {
        Image = images.${name}.ref;
        Pull = "never";
      }
      // lib.optionalAttrs (tag == null && !lib.hasInfix "@" image) { AutoUpdate = "registry"; };
    };
}
