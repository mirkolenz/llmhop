# The simplest deployment, a single vLLM container on the GPUs serving one
# model, which it downloads into a named volume when it first starts.
{
  services.llmhop.vllm = {
    enable = true;
    fetch.enable = false;
    cache.directory = null;
    container = {
      image = "docker.io/vllm/vllm-openai:latest";
      imageUnit = false;
      devices = [ "nvidia.com/gpu=all" ];
    };
    models."qwen3.8-27b" = {
      model = "Qwen/Qwen3.8-27B-FP8";
      port = 8000;
    };
  };
}
