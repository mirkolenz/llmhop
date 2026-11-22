# The mounts, user namespaces and images of Quadlet containers.
lib:
let
  inherit (import ./credentials.nix lib) resolveCredentialRefs;
in
rec {
  # Root of everything llmhop mounts into a container.
  containerRuntimeDirectory = "/run/llmhop";
  containerCredentialDirectory = "${containerRuntimeDirectory}/credentials";

  # The `idmap` option of every writable or root-owned mount of a container
  # in its own user namespace, which maps the files onto whatever range
  # `UserNS=auto` allocates on each start.
  idmap = llmhop: lib.optional (llmhop.container.userNS != null) "idmap";

  # The `:<options>` suffix of a Quadlet `Volume=`.
  mountSuffix = options: lib.optionalString (options != [ ]) ":${lib.concatStringsSep "," options}";

  # How a container reads `credentials`, which systemd grants its unit:
  # their read-only mount, idmapped since they belong to host root, the
  # variable naming it, which systemd sets natively, and `resolve`, which
  # rewrites the references in a settings tree to their paths.
  containerCredentials = llmhop: credentials: {
    volumes =
      lib.optional (credentials != { })
        "%d:${containerCredentialDirectory}${mountSuffix ([ "ro" ] ++ idmap llmhop)}";
    environment = lib.optionalAttrs (credentials != { }) {
      CREDENTIALS_DIRECTORY = containerCredentialDirectory;
    };
    resolve = resolveCredentialRefs containerCredentialDirectory credentials;
  };

  # The `[Container]` keys every container starts from, with the global
  # `services.llmhop.container.config` merged last by each. Podman isolates
  # the rest. The rootfs stays writable, since ML runtimes scatter caches
  # across `HOME`, and `/tmp` is a tmpfs.
  baseContainerConfig =
    llmhop:
    {
      NoNewPrivileges = true;
      DropCapability = "all";
      Tmpfs = [ "/tmp" ];
    }
    // lib.optionalAttrs (llmhop.container.userNS != null) { UserNS = llmhop.container.userNS; };

  # `podman auto-update` follows a registry `image` without a digest, but no
  # other transport such as `docker-archive:`.
  autoUpdate =
    image:
    lib.optionalAttrs (
      lib.match "(containers-storage|dir|docker-archive|oci|oci-archive|sif):.*|.*@.*" image == null
    ) { AutoUpdate = "registry"; };
}
