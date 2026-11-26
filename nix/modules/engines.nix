# How each engine is driven, keyed by its service name, over `defaults`.
#
# `negateBools` and `listStyle` describe how its parser reads booleans and
# lists, see `renderCliArgs`. `socketSettings` renders the flags binding a
# unix socket, or is null for a server that only listens on TCP.
# `revisions` tells whether its models pin a revision, `dataParallel`
# whether its servers take `--data-parallel-size` and pin a request to a
# rank by the `X-Data-Parallel-Rank` header, and `loras` renders the
# adapters of a model and the `model` the gateway rewrites a request for
# one to, or is null without LoRA support. `tags` tells whether a repository
# may end in a quantization tag. `watermark`
# renders the watermark of a model from the references to its keys, or is
# null, and a `wrapped` one runs the server through `serve` of the
# watermark script, whose config must not inline any of `keys`. `command`
# is its server command, natively from its package or in its image,
# followed by `positional` and the settings, among them `modelSettings` and
# `shutdownSettings`, which renders how long its server drains requests on
# a stop. `defaultModelSettings` are the defaults of the backend's
# `modelSettings`, such as those serving its Prometheus metrics at
# `metricsPath`, which the gateway collects, and which vLLM serves without
# any.
# `reservedSettings` lists the aliases of the flags it renders or of
# `positional`, which the `settings` of a model must not set either.
# `fetch` renders the argv downloading one repository with its package into
# the hub cache below `HF_HOME`, after which its servers get
# `offlineEnvironment`.
# `implicitConfig` lists the files it reads beside its arguments, which every
# unit hides, and `environment` is set on every server.
lib:
let
  inherit (import ./lib lib) isRepository;

  defaults = {
    uv = false;
    tags = false;
    loras = null;
    watermark = null;
    shutdownSettings = _: { };
    defaultModelSettings = { };
    metricsPath = "/metrics";
    reservedSettings = [ ];
    offlineEnvironment = { };
    implicitConfig = {
      paths = [ ];
      environment = { };
    };
    environment = { };
  };

  # `hf download` of the environment of vLLM and SGLang.
  hfDownload =
    package:
    {
      repo,
      revision,
      include,
      ...
    }:
    [
      (lib.getExe' package "hf")
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
in
lib.mapAttrs (name: engine: defaults // engine // { inherit name; }) {
  llama-cpp = {
    displayName = "llama.cpp";
    negateBools = true;
    # Its list flags split their value at commas, while repeating some, such
    # as `--host` or `--tensor-split`, keeps only the last.
    listStyle = "csv";
    # llama-server binds a unix socket when the host ends in `.sock`.
    socketSettings = path: {
      host = path;
      port = null;
    };
    revisions = false;
    # A repository may end in `:<quantization tag>`.
    tags = true;
    dataParallel = false;
    command = {
      native = package: [ (lib.getExe' package "llama-server") ];
      container = [ "/app/llama-server" ];
    };
    positional = _model: [ ];
    # Every other source of the model besides the one that `model` sets.
    reservedSettings = [
      "model"
      "hf-repo"
      "model-url"
      "docker-repo"
    ];
    modelSettings =
      model:
      {
        alias = model.name;
      }
      // (if isRepository model.model then { hf-repo = model.model; } else { inherit (model) model; });
    modelDescription = ''
      Hugging Face repository with an optional quantization tag, passed as
      `--hf-repo`, or an absolute path to a GGUF file, passed as `--model`.
    '';
    modelExample = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
    imageExample = "ghcr.io/ggml-org/llama.cpp:server-cuda";
    # `llama download` resolves a quantization tag, split files and the
    # mmproj as the server would, but pins no revision.
    fetch =
      package:
      { repo, tag, ... }:
      [
        (lib.getExe' package "llama")
        "download"
        "-hf"
        (if tag == null then repo else "${repo}:${tag}")
      ];
    defaultModelSettings.metrics = true;
    offlineEnvironment.LLAMA_ARG_OFFLINE = "1";
    # It reads a `config.ini` below these and its `XDG_CONFIG_HOME` before
    # its arguments, with no way to opt out, so every unit hides them.
    implicitConfig = {
      paths = [ "/etc/llama.cpp" ];
      environment.XDG_CONFIG_HOME = "/var/empty";
    };
  };

  vllm = {
    displayName = "vLLM";
    negateBools = true;
    listStyle = "values";
    socketSettings = path: {
      uds = path;
      host = null;
      port = null;
    };
    revisions = true;
    dataParallel = true;
    # vLLM serves an adapter under its own name and resolves its repository
    # in the hub cache, as the model. The JSON form takes any name, unlike
    # `<name>=<path>`.
    loras = {
      settings = loras: {
        enable-lora = true;
        lora-modules = lib.mapAttrsToList (name: path: { inherit name path; }) loras;
      };
      alias = _model: _adapter: null;
    };
    # vLLM reads the key from `key_file` itself.
    watermark = {
      description = "vLLM's `WatermarkConfig` without `key` and `key_file`";
      example.algorithm = "dual_key_gumbel";
      keys = [
        "key"
        "key_file"
      ];
      secondaryKey = false;
      wrapped = false;
      settings = watermark: key: _: {
        watermark-config = watermark.settings // {
          key_file = key;
        };
      };
    };
    uv = true;
    command = {
      native = package: [
        (lib.getExe' package "vllm")
        "serve"
      ];
      container = [
        "vllm"
        "serve"
      ];
    };
    positional = model: [ model.model ];
    # `vllm serve` takes the positional model over `--model`.
    reservedSettings = [ "model" ];
    modelSettings = model: {
      served-model-name = model.name;
      inherit (model) revision;
    };
    modelDescription = "Hugging Face repository passed to `vllm serve`, or an absolute path.";
    modelExample = "Qwen/Qwen2.5-7B-Instruct";
    imageExample = "docker.io/vllm/vllm-openai:latest";
    fetch = hfDownload;
    offlineEnvironment.HF_HUB_OFFLINE = "1";
    # vLLM otherwise derives the address of its distributed workers from
    # the route to a public one, which an offline server lacks.
    environment.VLLM_HOST_IP = "127.0.0.1";
    # Drains in-flight requests on a stop for at most `seconds`, while 0
    # aborts them.
    shutdownSettings = seconds: { shutdown-timeout = seconds; };
  };

  sglang = {
    displayName = "SGLang";
    negateBools = false;
    listStyle = "values";
    socketSettings = null;
    revisions = true;
    dataParallel = true;
    # SGLang serves an adapter as `<served>:<adapter>`, while a bare adapter
    # name silently falls back to the base model, so the gateway rewrites it.
    loras = {
      settings = loras: {
        enable-lora = true;
        lora-paths = lib.mapAttrsToList (name: path: {
          lora_name = name;
          lora_path = path;
        }) loras;
      };
      alias = model: adapter: "${model.name}:${adapter}";
    };
    # SGLang reads its keys from its config file, which the script writes.
    watermark = {
      description = "SGLang's watermark config without `key` and `key_b`";
      keys = [
        "key"
        "key_b"
      ];
      example = {
        context_window = 4;
        enforce_all = true;
      };
      secondaryKey = true;
      wrapped = true;
      settings = watermark: key: secondaryKey: {
        enable-watermark = true;
        watermark-settings = watermark.settings;
        watermark-key-file = key;
        watermark-key-b-file = secondaryKey;
      };
    };
    uv = true;
    command = {
      native = package: [
        (lib.getExe' package "sglang")
        "serve"
      ];
      container = [
        "sglang"
        "serve"
      ];
    };
    positional = model: [ model.model ];
    # `sglang serve` turns the positional model into `--model-path`.
    reservedSettings = [
      "model-path"
      "model"
      "dp-size"
    ];
    # `sglang serve` otherwise probes the hub for a diffusion model.
    modelSettings = model: {
      served-model-name = model.name;
      inherit (model) revision;
      model-type = "llm";
    };
    modelDescription = "Hugging Face repository passed to `sglang serve`, or an absolute path.";
    modelExample = "Qwen/Qwen3-8B";
    imageExample = "docker.io/lmsysorg/sglang:latest";
    fetch = hfDownload;
    offlineEnvironment.HF_HUB_OFFLINE = "1";
    # FlashAttention 3 from the `sglang-kernel` wheel rather than the hub,
    # which an offline server cannot reach. It drains in-flight requests on
    # SIGTERM until its unit kills it.
    environment.SGLANG_USE_SGL_FA3_KERNEL = "1";
    defaultModelSettings.enable-metrics = true;
  };
}
