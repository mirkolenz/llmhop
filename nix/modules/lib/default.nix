# Plain helpers shared by the backends and the gateway: endpoints and CLI
# rendering here, the rest merged from files that each define their names
# independently.
lib:
rec {
  # `host:port`, with IPv6 literals bracketed.
  hostPort =
    host: port:
    if lib.hasInfix ":" host then "[${host}]:${toString port}" else "${host}:${toString port}";

  # The loopback addresses, not all of `127.0.0.0/8`, which holds the stub
  # resolver of systemd-resolved.
  loopbackAddresses = [
    "127.0.0.1"
    "::1"
  ];

  isLoopback = host: lib.elem host loopbackAddresses;

  # Assertion that the listener of `owner`, with its `host` and `openFirewall`,
  # opens no port that it serves on loopback only.
  firewallAssertion = owner: listener: {
    assertion = listener.openFirewall -> !isLoopback listener.host;
    message = "services.llmhop: `${owner}` sets `openFirewall`, but its `host` ${listener.host} is loopback, so set `host` to an address remote clients reach.";
  };

  # `value` without the null members of its attribute sets, recursively,
  # which leaves the unset options of a JSON config out of it.
  withoutNulls =
    value:
    if lib.isList value then
      map withoutNulls value
    else if lib.isAttrs value && !lib.isDerivation value then
      lib.mapAttrs (_: withoutNulls) (lib.filterAttrs (_: member: member != null) value)
    else
      value;

  # Whether `model` names a repository to fetch rather than a local path.
  isRepository = model: !lib.hasPrefix "/" model;

  # The path every server answers with success once it is ready.
  healthPath = "/health";

  # The address of a server listening on `socket`, or else on its bind
  # address, loopback for a wildcard, as `llmhop internal wait-healthy` takes
  # it.
  # The `ListenStream=` of a listener, its `socket` without a `port`, or its
  # `port` on `host`, alone for every interface.
  listenStream =
    {
      host,
      port,
      socket,
      ...
    }:
    if port == null then
      socket
    else if host == "" then
      toString port
    else
      hostPort host port;

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
        else if value == [ ] then
          [ ]
        else if listStyle == "values" then
          [ "--${name}" ] ++ map cliValue value
        else
          [
            "--${name}"
            (lib.concatMapStringsSep "," cliValue value)
          ];
      rendered = if negateBools then negate settings else settings;
    in
    lib.concatLists (lib.mapAttrsToList render rendered);
}
// lib.mergeAttrsList (
  map (file: import file lib) [
    ./container.nix
    ./credentials.nix
    ./systemd.nix
  ]
)
