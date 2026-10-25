# The helpers shared by llmhop's modules. Every file contributes to one fixed
# point, `self`, through which the files reference each other's bindings.
lib:
let
  self = lib.fix (
    self:
    lib.mergeAttrsList (
      map (file: import file lib self) [
        ./common.nix
        ./engines.nix
        ./options.nix
        ./fetch.nix
        ./units.nix
        ./quadlet-options.nix
        ./quadlet.nix
        ./systemd-options.nix
        ./systemd.nix
      ]
    )
  );
in
{
  inherit (self)
    baseWorkloadOptions
    containerRuntimeDirectory
    credentialDirectory
    credentialSources
    credentialsOption
    enabled
    hostPort
    identityConfig
    identityOptions
    isRepository
    mergeCredentialServiceConfig
    mkRegistryAssertion
    modelSettings
    nativeWorkloadArgs
    quadlet
    quadletServiceName
    renderCliArgs
    renderCliArgsShell
    repositoriesOption
    resolveCredentialRefs
    resolveSettings
    serviceConfigOption
    settingsRendering
    sortedModels
    systemd
    unitConfigOption
    workerUrl
    workloadUnit
    ;
}
