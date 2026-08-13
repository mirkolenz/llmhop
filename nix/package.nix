{ buildGoModule, lib }:
buildGoModule (finalAttrs: {
  pname = "llmhop";
  version = "dev";
  src = ../.;
  vendorHash = null;
  subPackages = [
    "cmd/llmhop"
    "cmd/llmhop-notify"
  ];
  meta = {
    description = "Tiny, stateless Go router that dispatches OpenAI-compatible requests to single-model vLLM and sglang backends with zero external dependencies";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ mirkolenz ];
    homepage = "https://github.com/mirkolenz/llmhop";
    mainProgram = "llmhop";
  };
})
