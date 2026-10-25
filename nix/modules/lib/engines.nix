# How each engine is driven: its CLI dialect, fetch command and the
# flags derived from a model, and how `settings` render into argv.
lib: self:
let
  inherit (self)
    cliValue
    engine
    engines
    flipBoolFlags
    isRepository
    listenSettings
    quadletServiceName
    renderCliArgsWith
    resolveSettings
    ;
in
{
  # How each engine is driven, keyed by the unsuffixed service name so a
  # native backend and its quadlet twin share one entry.
  #
  # Its parser reads two `settings` shapes that have no portable rendering.
  # `negateBools` means the parser registers a `--no-<key>` twin for every
  # boolean; `listStyle` picks between `--key a b` ("values") and
  # `--key a --key b` ("repeat"). See the module internals documentation for
  # why neither axis can be delegated to `lib.cli`. `socketSettings` renders
  # the flags binding a unix socket, or is null for a server that only listens
  # on TCP.
  #
  # `fetch` renders the argv downloading one repository with the given
  # executable into the hub cache below `HF_HOME`, and `executable` names that
  # executable in a backend's package or in its image. `modelSettings` are the
  # flags derived from a model, `environment` is set on every server,
  # `containerEnvironment` on every server container, and `nativeRepositories`
  # are fetched for every native model. `llama download` resolves a
  # quantization tag, split files and the mmproj as the server would, but pins
  # no revision.
  engines =
    let
      base = {
        environment = { };
        containerEnvironment = { };
        nativeRepositories = [ ];
      };
      huggingFace = base // {
        listStyle = "values";
        revisions = true;
        modelSettings = model: {
          served-model-name = model.name;
          inherit (model) revision;
        };
        fetch =
          hf:
          {
            repo,
            revision ? null,
            include ? [ ],
          }:
          [
            hf
            "download"
            repo
          ]
          ++ lib.optionals (revision != null) [
            "--revision"
            revision
          ]
          ++ lib.concatMap (pattern: [
            "--include"
            pattern
          ]) include;
        executable = {
          native = package: lib.getExe' package "hf";
          container = "hf";
        };
      };
    in
    {
      llama-cpp = base // {
        negateBools = true;
        listStyle = "repeat";
        # llama-server binds a unix socket when the host ends in `.sock`.
        socketSettings = path: {
          host = path;
          port = null;
        };
        revisions = false;
        modelSettings =
          model:
          {
            alias = model.name;
            offline = if model.offline then true else null;
          }
          // (if isRepository model.model then { hf-repo = model.model; } else { inherit (model) model; });
        fetch = llama: { repo, ... }: [
          llama
          "download"
          "-hf"
          repo
        ];
        executable = {
          native = package: lib.getExe' package "llama";
          container = "/app/llama";
        };
      };
      # `model` is the positional argument of `vllm serve`.
      vllm = huggingFace // {
        negateBools = true;
        socketSettings = path: {
          uds = path;
          host = null;
          port = null;
        };
        # vLLM otherwise derives the address of its distributed workers from
        # the route to a public one, which an offline server lacks.
        environment.VLLM_HOST_IP = "127.0.0.1";
      };
      sglang = huggingFace // {
        negateBools = false;
        socketSettings = null;
        modelSettings = model: huggingFace.modelSettings model // { model-path = model.model; };
        # The images ship their flash-attention kernels in their own hub
        # cache, which the mounted `HF_HOME` replaces.
        containerEnvironment.KERNELS_CACHE = "/root/.cache/huggingface/hub";
        # Without the lockfile of its images, SGLang loads these kernels from
        # the hub at this revision.
        nativeRepositories = [
          {
            repo = "kernels-community/sgl-flash-attn3";
            revision = "v1";
          }
        ];
      };
    };

  engine = backend: engines.${quadletServiceName backend};

  # Whether `backend`'s server can bind a unix socket instead of a port.
  socketCapable = backend: (engine backend).socketSettings != null;

  # Listener flags binding `socket`, or `host:port` when `socket` is null.
  listenSettings =
    backend:
    {
      host,
      port,
      socket,
    }:
    if socket == null then { inherit host port; } else (engine backend).socketSettings socket;

  # The flags a workload's server receives: its `settings` under the backend's
  # `managed` flags and the `listen` flags, with every `${cred:…}` resolved
  # against the credential `directory`.
  workloadFlags =
    {
      backend,
      directory,
      listen,
      managed,
      workload,
      settings,
    }:
    resolveSettings directory workload.credentials (managed // listenSettings backend listen) settings;

  # `false` becomes `--no-<key>` (and `no-<key> = false` becomes `--<key>`) for
  # the backends whose parsers auto-register the negated twin. Other values
  # pass through untouched.
  flipBoolFlags = lib.mapAttrs' (
    name: value:
    if value == false then
      lib.nameValuePair (
        if lib.hasPrefix "no-" name then lib.removePrefix "no-" name else "no-${name}"
      ) true
    else
      lib.nameValuePair name value
  );

  # Strings, paths and derivations render verbatim, everything else through JSON.
  cliValue = value: if lib.isStringLike value then toString value else lib.toJSON value;

  # One-sentence dialect summary appended to every `settings` description.
  settingsRendering =
    backend:
    let
      dialect = engine backend;
    in
    "Rendered as `--<key> <value>`, with ${
      if dialect.negateBools then
        "`false` as `--no-<key>`"
      else
        "`false` dropped, since this CLI pairs `--enable-X` with `--disable-X`"
    } and a list ${
      if dialect.listStyle == "values" then "handed to a single flag" else "repeating the flag"
    }. See [settings rendering](../README.md#settings-rendering) for the full rules.";

  # Render a `settings` attribute set into the argv `backend`'s parser expects,
  # following its entry in `engines`. A `"values"` list always spends one
  # argv entry per element, `sep` or not: argparse stops consuming values after
  # the one glued onto `--<key>=`.
  renderCliArgsWith =
    sep: backend:
    let
      dialect = engine backend;
      flag =
        name: value:
        if sep == null then
          [
            "--${name}"
            (cliValue value)
          ]
        else
          [ "--${name}${sep}${cliValue value}" ];
      # `false` only reaches this point for dialects without a negated twin,
      # `flipBoolFlags` having rewritten the key otherwise.
      render =
        name: value:
        if value == null || value == false then
          [ ]
        else if value == true then
          [ "--${name}" ]
        else if !lib.isList value then
          flag name value
        else if dialect.listStyle == "values" then
          lib.optionals (value != [ ]) ([ "--${name}" ] ++ map cliValue value)
        else
          lib.concatMap (flag name) value;
    in
    attrs:
    lib.concatLists (
      lib.mapAttrsToList render (if dialect.negateBools then flipBoolFlags attrs else attrs)
    );

  # Flag and value as separate argv entries, what `utils.escapeSystemdExecArgs`
  # takes.
  renderCliArgs = renderCliArgsWith null;

  # One shell-quoted string of `--key=value` tokens, what a Quadlet `Exec=` takes.
  renderCliArgsShell =
    backend:
    let
      render = renderCliArgsWith "=" backend;
    in
    attrs: lib.escapeShellArgs (render attrs);

  # A model's effective settings, the backend-wide defaults overridden per model.
  modelSettings = cfg: model: cfg.modelSettings // model.settings;

}
