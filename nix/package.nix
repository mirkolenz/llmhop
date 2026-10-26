{ buildGoModule, lib }:
buildGoModule {
  pname = "llmhop";
  version = "dev";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../go.mod
      ../cmd
      ../internal
    ];
  };
  vendorHash = null;
  # The router tests bind loopback listeners.
  __darwinAllowLocalNetworking = true;
  meta = {
    description = "Tiny, stateless Go router that dispatches OpenAI-compatible requests to single-model vLLM and sglang backends with zero external dependencies";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ mirkolenz ];
    homepage = "https://github.com/mirkolenz/llmhop";
    mainProgram = "llmhop";
  };
}
