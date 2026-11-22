# Accounts, directories, start limits and the hardening of native units.
lib:
let
  inherit (lib) mkOption types;
in
rec {
  # The note of an option that only `runtime` reads.
  runtimeOnly = runtime: "Only used if `services.llmhop.runtime` is `\"${runtime}\"`.";

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

  # `InaccessiblePaths=` entries of `paths`, which may not exist.
  optionalPaths = map (path: "-${path}");

  # Hard-fail after 3 errors/hour so journald surfaces the underlying error
  # instead of an endless restart loop.
  startLimitConfig = {
    StartLimitBurst = 3;
    StartLimitIntervalSec = 3600;
  };

  # The account options of a native backend or gateway, a named account
  # rather than a `DynamicUser`, `name` by default. `prefix` is the option
  # path, for the documented defaults, and `runsAs` what runs as it.
  identityOptions =
    {
      name,
      cfg,
      prefix,
      runsAs,
    }:
    let
      native = runtimeOnly "native";
    in
    {
      user = mkOption {
        type = types.str;
        default = name;
        description = ''
          System user ${runsAs}, declared by the module while it keeps the
          name `${name}`. ${native}
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
        default = cfg.user;
        defaultText = lib.literalExpression "config.${prefix}.user";
        description = "Primary group of `user`, declared by the module while it keeps the name `${name}`. ${native}";
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
}
