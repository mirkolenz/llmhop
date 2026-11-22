# systemd credentials, the `${cred:…}` references to them and the
# environment of a service, where they expand.
lib:
let
  inherit (lib) mkOption types;
in
rec {
  # The credential names llmhop accepts, a subset of those systemd accepts
  # that needs no escaping in a unit, as in llmhop and llmhopctl.
  credentialNamePattern = "[[:alnum:]_][[:alnum:]_.-]{0,254}";

  credentialsOption = mkOption {
    type = with types; attrsOf (nullOr externalPath);
    default = { };
    # A credential name becomes a systemd credential ID, a plain file name
    # under `$CREDENTIALS_DIRECTORY`, so anything systemd would reject is
    # caught here. An imported name may end in `*`, which systemd globs.
    apply = lib.mapAttrs (
      name: source:
      if
        lib.match "${credentialNamePattern}${lib.optionalString (source == null) "[*]?"}" name != null
      then
        source
      else
        throw "services.llmhop: `${name}` is not a valid credential name. Start with an alphanumeric character or `_`, continue with those plus `.` and `-`, and stay within 255 characters. Only an imported one may end in `*`."
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
      `ImportCredential=`, where a trailing `*` imports every credential
      starting with the rest. Reference the read-only file from `settings` as
      `''${cred:<name>}`.
    '';
  };

  # The `environment` and `environmentFile` options of a service, from the
  # further `mkOption` arguments of each, such as its description.
  environmentOptions =
    { environment, environmentFile }:
    {
      environment = mkOption (
        {
          type = with types; attrsOf str;
          default = { };
        }
        // environment
      );
      environmentFile = mkOption (
        {
          type = with types; nullOr externalPath;
          default = null;
        }
        // environmentFile
      );
    };

  # The set `environmentFile` of each of `configs`, later ones overriding
  # the entries of earlier ones.
  environmentFiles = lib.concatMap (
    cfg: lib.optional (cfg.environmentFile != null) cfg.environmentFile
  );

  # The `[Service]` settings granting `credentials`. `toString` keeps a path
  # value from being copied into the Nix store.
  # systemd expands specifiers in the source path.
  credentialServiceConfig = credentials: {
    LoadCredential = lib.mapAttrsToList (name: source: escapeSpecifiers "${name}:${toString source}") (
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

  # systemd's specifier of `$CREDENTIALS_DIRECTORY`, which it expands in
  # `Environment=` as well.
  credentialDirectory = "%d";

  # `value` with every `${cred:…}` resolved to systemd's `%d` in the syntax
  # of a unit setting that `escape` renders. A placeholder survives
  # `escape`, which would turn `%d` into a literal, and is swapped for it
  # afterwards.
  resolveForSystemd =
    escape: credentials: value:
    let
      credentialPlaceholder = "@llmhopCredentialsDirectory@";
    in
    lib.replaceStrings [ credentialPlaceholder ] [ credentialDirectory ] (
      escape (resolveCredentialRefs credentialPlaceholder credentials value)
    );

  # The `ExecStart=` of `command`.
  execStart = utils: resolveForSystemd utils.escapeSystemdExecArgs;

  # The `Environment=` of `environment`, where systemd expands specifiers.
  systemdEnvironment = credentials: lib.mapAttrs (_: resolveForSystemd escapeSpecifiers credentials);

  escapeSpecifiers = lib.replaceStrings [ "%" ] [ "%%" ];
}
