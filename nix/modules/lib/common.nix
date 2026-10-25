# Credentials, settings and naming shared by every backend.
lib: self:
let
  inherit (lib)
    mkOption
    types
    ;
  inherit (self)
    appendList
    checkCredentialName
    containerRuntimeDirectory
    credentialReferencePrefix
    credentialSources
    credentialType
    resolveCredentialRefs
    ;
in
{
  # Append to a systemd list setting that an earlier layer may have set as a
  # scalar, or not at all.
  appendList =
    attrs: key: entries:
    lib.toList (attrs.${key} or [ ]) ++ entries;

  # `host:port`, with IPv6 literals bracketed.
  hostPort =
    host: port:
    if lib.hasInfix ":" host then "[${host}]:${toString port}" else "${host}:${toString port}";

  # Unit name of a model or auxiliary workload. Everything keyed by unit, from
  # its socket path to its credential directory, derives from this.
  workloadUnit = prefix: workload: "${prefix}-${workload.name}";

  # The cache and state directories of the server in `unit`, named after it
  # like its `CacheDirectory=` and `StateDirectory=`, at the same path in a
  # container.
  unitCacheDirectory = unit: "/var/cache/${unit}";
  unitStateDirectory = unit: "/var/lib/${unit}";

  # Permissive label for unit and routing-key names. Allows dots so
  # `qwen3.6-…`-style version suffixes work.
  modelLabel = types.strMatching "[[:alnum:]][[:alnum:].-]*";

  credentialReferencePrefix = "\${cred:";
  # Root of everything llmhop mounts into a container.
  containerRuntimeDirectory = "/run/llmhop";
  credentialDirectory = "${containerRuntimeDirectory}/credentials";

  # A plain path is shorthand for `source`, so every value reaches the module
  # in one shape. Every path is coerced, as a submodule would import one as a
  # module, and `source` keeps it outside the Nix store, which every local
  # user can read.
  credentialType = types.coercedTo types.path (source: { inherit source; }) (
    types.submodule {
      options = {
        source = mkOption {
          type = types.nullOr types.externalPath;
          default = null;
          description = ''
            File or socket from which systemd loads the credential. `null`
            imports the credential of the same name with `ImportCredential=`
            from the system credential store, such as `/etc/credstore` and
            `/etc/credstore.encrypted`, and from the credentials passed to the
            system.
          '';
        };
        encrypted = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether to load and decrypt `source` with `LoadCredentialEncrypted=`.
            Imported credentials are decrypted as needed.
          '';
        };
      };
    }
  );

  # A credential name becomes a systemd credential ID, which systemd renders as
  # a plain file name under `$CREDENTIALS_DIRECTORY`. Anything carrying a path
  # separator or exceeding 255 characters is rejected by systemd itself, so it
  # is caught here rather than at rebuild or service start. The credential
  # passes through unchanged, so the check composes with `mapAttrs`.
  checkCredentialName =
    name:
    lib.throwIfNot (lib.match "[[:alnum:]_][[:alnum:]_.-]{0,254}" name != null)
      "services.llmhop: `${name}` is not a valid systemd credential name. Start with an alphanumeric character or `_`, continue with those plus `.` and `-`, and stay within 255 characters.";

  # How a credential's source maps onto systemd, shared by every `credentials`
  # description. `example` names an imported credential.
  credentialSources = example: ''
    A path outside the Nix store uses `LoadCredential=`. The attribute form
    can select `LoadCredentialEncrypted=` for a `systemd-creds` encrypted
    source, which must be encrypted under the same name, or omit `source`
    to import the credential of that name from the system credential store.
    That store is shared by every service, so prefix an imported name with
    its service, as in `${example}`.'';

  credentialsOption = mkOption {
    type = types.attrsOf credentialType;
    default = { };
    apply = lib.mapAttrs checkCredentialName;
    example = lib.literalExpression ''
      {
        api-keys = "/run/secrets/api-keys";
        tls-key = {
          source = "/run/secrets/tls-key.cred";
          encrypted = true;
        };
        "llmhop.hf-token" = { };
      }
    '';
    description = ''
      Credentials granted exclusively to this service through systemd.
      ${credentialSources "llmhop.hf-token"}

      Reference the resulting read-only file from `settings` as
      `''${cred:<name>}`. The module resolves the reference to the native or
      container credential path without copying its contents to the Nix store
      or command line.
    '';
  };

  # Append this workload's `LoadCredential=`, `LoadCredentialEncrypted=` and
  # `ImportCredential=` entries to whatever `serviceConfig` already declares.
  mergeCredentialServiceConfig =
    serviceConfig: credentials:
    let
      loaded = lib.filterAttrs (_: value: value.source != null) credentials;
      render =
        encrypted:
        lib.mapAttrsToList (name: value: "${name}:${value.source}") (
          lib.filterAttrs (_: value: value.encrypted == encrypted) loaded
        );
    in
    serviceConfig
    // lib.optionalAttrs (credentials != { }) {
      LoadCredential = appendList serviceConfig "LoadCredential" (render false);
      LoadCredentialEncrypted = appendList serviceConfig "LoadCredentialEncrypted" (render true);
      ImportCredential = appendList serviceConfig "ImportCredential" (
        lib.attrNames (lib.filterAttrs (_: value: value.source == null) credentials)
      );
    };

  # Rewrite every `${cred:<name>}` reference in a settings tree to the path the
  # credential is mounted at, so secrets reach the server as a file name rather
  # than a value on the command line.
  resolveCredentialRefs =
    directory: credentials:
    let
      names = lib.attrNames credentials;
      references = map (name: "${credentialReferencePrefix}${name}}") names;
      paths = map (name: "${directory}/${name}") names;
      resolve =
        value:
        if lib.isString value then
          let
            resolved = lib.replaceStrings references paths value;
          in
          if lib.hasInfix credentialReferencePrefix resolved then
            throw "unknown credential reference in `${value}`"
          else
            resolved
        else if lib.isList value then
          map resolve value
        else if lib.isAttrs value && !lib.isDerivation value then
          lib.mapAttrs (_: resolve) value
        else
          value;
    in
    resolve;

  # Settings as a server receives them, with every `${cred:…}` resolved against
  # the credential `directory`. The flags llmhop derives from its own options
  # (listener, routing name) in `managed` win over the user's `settings`, so an
  # override can neither move a server off loopback nor off the port or socket
  # the readiness probe and llmhop route to.
  resolveSettings =
    directory: credentials: managed: settings:
    resolveCredentialRefs directory credentials (settings // managed);

  isQuadlet = lib.hasSuffix "-quadlet";

  # Quadlet backends live under the `<service>-quadlet` option namespace but
  # emit units named `<service>-<model>`, matching their native twin (hence the
  # mutual-exclusion assertion in `quadlet.mkConfig`).
  quadletServiceName = lib.removeSuffix "-quadlet";
}
