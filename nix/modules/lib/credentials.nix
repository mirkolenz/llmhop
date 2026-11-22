# systemd credentials and the `${cred:…}` references to them.
lib:
let
  inherit (lib) mkOption types;
in
rec {
  credentialsOption = mkOption {
    type = with types; attrsOf (nullOr externalPath);
    default = { };
    # A credential name becomes a systemd credential ID, a plain file name
    # under `$CREDENTIALS_DIRECTORY`, so anything systemd would reject is
    # caught here. An imported name may end in `*`, which systemd globs.
    apply = lib.mapAttrs (
      name: source:
      if
        lib.match "[[:alnum:]_][[:alnum:]_.-]{0,254}${lib.optionalString (source == null) "[*]?"}" name
        != null
      then
        source
      else
        throw "services.llmhop: `${name}` is not a valid systemd credential name. Start with an alphanumeric character or `_`, continue with those plus `.` and `-`, and stay within 255 characters. Only an imported one may end in `*`."
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
}
