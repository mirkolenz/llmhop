{
  buildGoLatestModule,
  go-licenses,
  lib,
  nukeReferences,
  version ? "dev",
}:
# The latest Go, since the default of a stable nixpkgs may predate go.mod.
buildGoLatestModule (finalAttrs: {
  pname = "llmhop";
  inherit version;
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../go.mod
      ../go.sum
      ../cmd
      ../internal
    ];
  };
  vendorHash = "sha256-v1tQfSUpKCEE7o5DqNJ86ZxomXMRhP6IR89ZNkpl6EA=";
  # Renames the module derivation per go.sum, so a stale vendorHash fails
  # instead of silently reusing the cached modules of the old go.sum.
  goSum = ../go.sum;
  ldflags = [ "-X main.version=${finalAttrs.version}" ];
  env = {
    # Static, so a bundle runs it on any host.
    CGO_ENABLED = 0;
    # encoding/json/v2 is still behind an experiment.
    GOEXPERIMENT = "jsonv2";
  };
  # Nixpkgs' Go embeds store paths of optional data files such as tzdata,
  # which llmhop never reads, so a static binary may reference nothing.
  nativeBuildInputs = [
    go-licenses
    nukeReferences
  ];
  postFixup = "nuke-refs $out/bin/llmhop";
  # Saves what the licenses of the linked dependencies require alongside the
  # binary, failing on a forbidden or unknown license, like .goreleaser.yaml.
  # go-licenses skips the standard library, whose license is in the Go source.
  # It also ships the Grafana dashboard for `services.grafana.provision`.
  postInstall = ''
    install -Dm444 ${../share/grafana/dashboards/llmhop.json} $out/share/grafana/dashboards/llmhop.json
    licenses=$out/share/licenses/llmhop
    go-licenses save ./cmd/llmhop --save_path $licenses --ignore github.com/mirkolenz/llmhop
    mkdir $licenses/go
    tar -xzf ${finalAttrs.passthru.go.src} -C $licenses/go --strip-components=1 go/LICENSE go/PATENTS
  '';
  allowedReferences = [ ];
  # The router tests bind loopback listeners.
  __darwinAllowLocalNetworking = true;
  meta = {
    description = "Tiny, stateless Go router that dispatches OpenAI-compatible requests to single-model vLLM and sglang backends";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ mirkolenz ];
    homepage = "https://github.com/mirkolenz/llmhop";
    mainProgram = "llmhop";
  };
})
