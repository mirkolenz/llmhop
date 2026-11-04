{
  buildGoModule,
  lib,
  nukeReferences,
  version ? "dev",
}:
buildGoModule (finalAttrs: {
  pname = "llmhop";
  inherit version;
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../go.mod
      ../cmd
      ../internal
    ];
  };
  vendorHash = null;
  ldflags = [ "-X main.version=${finalAttrs.version}" ];
  # Static, so a bundle runs it on any host.
  env.CGO_ENABLED = 0;
  # Nixpkgs' Go embeds store paths of optional data files such as tzdata,
  # which llmhop never reads, so a static binary may reference nothing.
  nativeBuildInputs = [ nukeReferences ];
  postFixup = "nuke-refs $out/bin/llmhop";
  allowedReferences = [ ];
  # The router tests bind loopback listeners.
  __darwinAllowLocalNetworking = true;
  meta = {
    description = "Tiny, stateless Go router that dispatches OpenAI-compatible requests to single-model vLLM and sglang backends with zero external dependencies";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ mirkolenz ];
    homepage = "https://github.com/mirkolenz/llmhop";
    mainProgram = "llmhop";
  };
})
