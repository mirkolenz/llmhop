# How each engine is driven, keyed by its service name.
#
# `negateBools` and `listStyle` describe how its parser reads booleans and
# lists, see `renderCliArgs`. `socketSettings` renders the flags binding a unix
# socket, or is null for a server that only listens on TCP. `fetch` renders the
# argv downloading one repository with the given `fetcher` into the hub cache
# below `HF_HOME`. `modelSettings` are the flags derived from a model and
# `environment` is set on every server. `native` and `quadlet` hold what only
# one kind of backend needs.
lib:
let
  inherit (import ./lib.nix lib) isRepository;

  # `hf download`, shared by vLLM and SGLang.
  hfDownload =
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
in
{
  llama-cpp = {
    name = "llama-cpp";
    displayName = "llama.cpp";
    negateBools = true;
    listStyle = "repeat";
    # llama-server binds a unix socket when the host ends in `.sock`.
    socketSettings = path: {
      host = path;
      port = null;
    };
    revisions = false;
    environment = { };
    modelSettings =
      model:
      {
        alias = model.name;
        offline = true;
      }
      // (if isRepository model.model then { hf-repo = model.model; } else { inherit (model) model; });
    modelDescription = ''
      Hugging Face repository with an optional quantization tag, passed as
      `--hf-repo`, or an absolute path to a GGUF file, passed as `--model`.
    '';
    modelExample = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
    # `llama download` resolves a quantization tag, split files and the
    # mmproj as the server would, but pins no revision.
    fetch = llama: { repo, ... }: [
      llama
      "download"
      "-hf"
      repo
    ];
    native = {
      uv = false;
      fetcher = package: lib.getExe' package "llama";
      command = model: [ (lib.getExe' model.package "llama-server") ];
      repositories = [ ];
    };
    quadlet = {
      imageExample = "ghcr.io/ggml-org/llama.cpp:server-cuda";
      entrypoint = [ "/app/llama-server" ];
      arguments = _model: [ ];
      port = 8080;
      fetcher = "/app/llama";
      environment = { };
    };
  };

  vllm = {
    name = "vllm";
    displayName = "vLLM";
    negateBools = true;
    listStyle = "values";
    socketSettings = path: {
      uds = path;
      host = null;
      port = null;
    };
    revisions = true;
    # vLLM otherwise derives the address of its distributed workers from
    # the route to a public one, which an offline server lacks.
    environment.VLLM_HOST_IP = "127.0.0.1";
    modelSettings = model: {
      served-model-name = model.name;
      inherit (model) revision;
    };
    modelDescription = "Hugging Face repository passed to `vllm serve`, or an absolute path.";
    modelExample = "Qwen/Qwen2.5-7B-Instruct";
    fetch = hfDownload;
    native = {
      uv = true;
      packageEntry = "the `vllm` CLI at `bin/vllm`";
      fetcher = package: lib.getExe' package "hf";
      command = model: [
        (lib.getExe' model.package "vllm")
        "serve"
        model.model
      ];
      repositories = [ ];
    };
    quadlet = {
      imageExample = "docker.io/vllm/vllm-openai:latest";
      entrypoint = [
        "vllm"
        "serve"
      ];
      # `vllm serve` takes the model as its positional argument.
      arguments = model: [ model.model ];
      port = 8000;
      fetcher = "hf";
      environment = { };
    };
  };

  sglang = {
    name = "sglang";
    displayName = "SGLang";
    negateBools = false;
    listStyle = "values";
    socketSettings = null;
    revisions = true;
    environment = { };
    modelSettings = model: {
      served-model-name = model.name;
      inherit (model) revision;
      model-path = model.model;
    };
    modelDescription = "Hugging Face repository passed as `--model-path`, or an absolute path.";
    modelExample = "Qwen/Qwen3-8B";
    fetch = hfDownload;
    native = {
      uv = true;
      packageEntry = "the SGLang Python environment, launched as `bin/python -m sglang.launch_server`";
      fetcher = package: lib.getExe' package "hf";
      # `python -m sglang.launch_server` is the entry point present in
      # every SGLang wheel, a top-level `sglang` console script is not.
      command = model: [
        (lib.getExe' model.package "python")
        "-m"
        "sglang.launch_server"
      ];
      # Without the lockfile of its images, SGLang loads these kernels
      # from the hub at this revision.
      repositories = [
        {
          repo = "kernels-community/sgl-flash-attn3";
          revision = "v1";
        }
      ];
    };
    quadlet = {
      imageExample = "docker.io/lmsysorg/sglang:latest";
      entrypoint = [
        "sglang"
        "serve"
      ];
      arguments = _model: [ ];
      port = 30000;
      fetcher = "hf";
      # The images ship their flash-attention kernels in their own hub
      # cache, which the mounted `HF_HOME` replaces.
      environment.KERNELS_CACHE = "/root/.cache/huggingface/hub";
    };
  };
}
