# Module internals

Why the NixOS module in `nix/modules/` works the way the README describes, recording decisions that are hard to re-derive from the code.

## CLI dialects

Two `settings` shapes have no portable rendering, so each backend declares how its parser reads them, keyed by the unsuffixed service name so a native backend and its Quadlet twin share one entry.

`negateBools` marks parsers that register a `--no-<key>` twin for every boolean, as argparse's `BooleanOptionalAction` and llama.cpp's paired flags do.
SGLang instead pairs `--enable-X` with `--disable-X` and rejects `--no-X`.

`listStyle` picks between one flag for all elements (`--key a b`), as argparse `nargs` and clap multi-value options take, and one flag per element (`--key a --key b`), all that llama.cpp's hand-rolled parser understands.
llama.cpp also takes only `--key value`, never `--key=value`.
Both argparse backends register a few options in the other style, so this is the dominant form rather than a guarantee for every flag.

Neither axis can be delegated to nixpkgs.
`lib.cli.toCommandLine` renders neither, since its `optionFormat` never sees the value and its list handling always repeats.
The `mkBool` and `mkList` hooks of `lib.cli.toGNUCommandLine` could, but it is deprecated as of nixpkgs 25.11 and warns on every evaluation.

Non-string values go through JSON, which keeps `0.6` from becoming `0.600000` as `toString` would make it.

## Worker hardening

Native workers start from a `systemd-exec(5)` baseline shared with the llmhop reverse proxy.
Quadlet workers skip it, because Podman isolates at the container level.
`SocketBind*` is not part of the baseline, since only workers with a `port` declare a matching `SocketBindAllow`, and it only governs IP sockets, so a worker on a unix socket keeps `SocketBindDeny = "any"`.

### GPU relaxations

- `PrivateDevices = false`: GPUs need raw device access, `/dev/nvidia*` for CUDA and `/dev/kfd` plus `/dev/dri/renderD*` for ROCm and Level Zero.
  The upstream NVIDIA NixOS modules do the same.
- `SupplementaryGroups = [ "render" "video" ]`: `/dev/nvidia*` is world-readable, but systemd's default udev rules leave the AMD and Intel nodes group-owned.
- `PrivateUsers = "identity"`: the baseline's `PrivateUsers = true` maps everything but the unit's own identity to `nobody`, which would void those groups.
  `identity` maps the first 65536 IDs one-to-one.
- `MemoryDenyWriteExecute = false`: torch-inductor, triton, the CUDA driver's PTX to SASS pass and the SPIR-V JIT behind SYCL and Level Zero all map `PROT_WRITE|PROT_EXEC` pages.
- `LimitMEMLOCK = "infinity"`: every stack pins the host side of its device buffers, and llama.cpp's `--mlock` pins the weights, so systemd's 8 MiB default reports OOM despite free VRAM.
- `ProcSubset = "all"`: psutil, torch and NUMA discovery read `/proc/meminfo` and `/proc/cpuinfo`, which the baseline's `pid` hides.
  `ProtectProc` still hides other users' processes.

### NCCL relaxations

`getifaddrs()` opens an `AF_NETLINK` socket during its interface scan, so that family is re-added to `RestrictAddressFamilies`.
The bootstrap, proxy and RAS listeners bind ephemeral TCP sockets, and the bind hook only ever sees port 0, so allowing all TCP is the tightest workable rule, which also covers the worker's own listener.
UDP stays denied.
NCCL is kept on loopback and off InfiniBand, since a single node has no fabric.
RCCL reads the same variables, while oneCCL uses `CCL_*` and ignores them.

### Caches

Every accelerator stack caches compiled kernels below `$HOME`, which `ProtectSystem = "strict"` makes read-only, so each is redirected into the unit's own cache directory, the one place `systemctl clean` reaches.
The variables are set unconditionally, since one of an absent stack is never read.
MIOpen needs two of them, or its kernel database and compiled-kernel cache land under separate roots.
SYCL and the Intel compute runtime cache their SPIR-V to ISA compilation only when asked to, which turns a multi-minute JIT into a one-time cost.

## Unix sockets

Each workload without a `port` gets a directory of its own below `socketDirectory` rather than a `<unit>.sock` in one flat directory, which every worker would have to write, letting one delete or squat another's socket.
`connect()` needs search permission on each directory and write permission on the socket.
The root is `root:root` with mode `0711`, so anyone may pass but not list it, and each directory has mode `0710`, since llmhop knows the name.
vLLM and llama.cpp bind with the umask and never `chmod`, so workers run with `UMask = "0007"` and containers with `--umask=0007`, as Quadlet's own `Umask=` is newer than podman 6.1.
llmhop's own socket listeners share the root, with ownership and mode from their listener options.

A native worker's directory and socket belong to the backend's `group`, which llmhop joins, the usual systemd pattern for a socket client.
An ACL cannot work there, because systemd drops every ACL of an exec directory when it chowns it to a non-root unit.
Workers of one backend can therefore reach each other's sockets, but not those of another backend.

A container user maps to an unpredictable host ID under `UserNS=`, so Quadlet sockets rely on a default ACL `user:<services.llmhop.user>:-wx` on the root, inherited below it.
That is why llmhop runs as a named user, since no ACL could name a `DynamicUser` in advance.
The ACL survives, because systemd never chowns these directories, as rootful units run as root and rootless ones use tmpfiles.
The kernel masks a new socket's mode with the umask even below a default ACL, and the ACL mask follows the group bits, so `--umask=0007` keeps the ACL's write.
The owning group's own entry comes from the root's `0711` and grants no write.

Each directory is a `RuntimeDirectory=` of its unit, removed on stop and crash alike, so no stale socket makes a restarted server fail with `EADDRINUSE`, although neither server removes one itself.
That is also why `socketDirectory` must stay below `/run`.
A rootful container mounts its directory with `U`, so Podman hands it to the mapped container user, and ACLs survive the `chown`.
The mode is a default, so `serviceConfig.RuntimeDirectoryMode` can override it.
A user manager keeps `RuntimeDirectory=` below its `$XDG_RUNTIME_DIR`, which llmhop cannot enter, so rootless containers use a tmpfiles directory owned by the Podman account, cleared by an `ExecStartPre=` through `podman unshare`, since after the `U` chown only that user namespace may delete there.

## Python backends built from wheels

The wheel-based vLLM and SGLang backends need more than the hardening baseline.

They get a toolchain on `PATH`, because they compile at runtime and look it up the FHS way.
Triton builds its CUDA driver shim on the first kernel launch from `$CC`, `gcc` or `clang`.
torch's `cpp_extension` and flashinfer's JIT drive `ninja`, which nixpkgs patches to `posix_spawnp("sh")`, so it needs a shell on `PATH`.
ctypes falls back to `gcc` and `ld` once nixpkgs' patched `ldconfig` lookup returns nothing.
`HOME` points at the cache directory, because the service user has none, and libraries reaching for `~`, such as flashinfer's JIT workspace, would hit the read-only root.

`mkUvEnv` bakes the driver runpath into the wheels, so `libcuda.so.1` and its ROCm and Level Zero counterparts resolve as for a nixpkgs build with `autoAddDriverRunpath`.
`LD_LIBRARY_PATH` covers the driver libraries the framework `dlopen`s by name from Python during GPU-memory profiling, such as `libnvidia-ml.so.1`.
Triton locates `libcuda.so.1` through `/sbin/ldconfig -p`, which NixOS lacks, so `TRITON_LIBCUDA_PATH` short-circuits that lookup.

These backends cannot run under `DynamicUser`, whose `/var/lib/private` layout hands `StateDirectory` and `CacheDirectory` over as ID-mapped mounts.
Those are unconditionally noexec and beyond `ExecPaths=`, while these runtimes `dlopen` the kernels they compile into the cache.

`mkUvEnv` checks unresolved libraries only on the assembled environment, since a wheel in isolation cannot see the siblings it shares a venv with, and half of what it misses at that point is another wheel.
It counts a soname that any file in the environment carries as resolved, since wheels rarely link siblings through the runpath, as torch preloads the CUDA wheels and torchcodec expects torch to be loaded.

## Lifecycle

Servers restart with `Restart = "always"`, because vLLM and SGLang catch an EngineCore death, shut down gracefully and exit 0, which `on-failure` would leave dead.
A shared `StartLimitBurst` of 3 per hour still breaks crash loops, so journald surfaces the underlying error.
`TimeoutStartSec` allows an hour for loading and GPU memory profiling, since downloads happen in the fetcher beforehand.
Startup is chained by ascending `name`, because two workers profiling GPU memory on the same device each see it as free and race into an OOM.
The chain only works because a worker stays `activating` until its server is ready.

`llmhop-notify` comes from this flake rather than `services.llmhop.package`, since it is a module implementation detail and a deployer's llmhop build need not ship it, which `getExe'` would not catch, leaving every worker `activating` until `TimeoutStartSec`.

## Fetching

A fetcher mirrors a Quadlet image unit, a oneshot with `RemainAfterExit=`.
The server `Wants=` its fetcher and is ordered after it, but does not `Requires=` it as a container does its image, since that would propagate every restart by `<backend>-update` to the server, changed model or not.
The fetcher shares its server's identity, a named user natively and the same `quadlet` identity overrides in a container, so both see the cache under one owner.
That is why llama.cpp does not use `DynamicUser` either.

The fetcher records the refs and snapshot files of its repositories before downloading and compares them afterwards.
A change runs `try-restart`, which leaves a stopped server alone, and a failed server is reset and started again.
Both run with full privileges, since a native fetcher's user may not manage units, and with `--no-block`, since the server is ordered after the fetcher.

`<backend>-update` restarts every fetcher with full privileges, waits for them, and then prunes, deleting repositories no enabled workload references and snapshots that neither a ref nor a pinned `revision` names, then every blob no remaining snapshot resolves to, including the shared blob store of recent `huggingface_hub` releases.
It only deletes extensionless blobs, so a concurrent download keeps its `.incomplete` files.
A rootless user's files belong to its subordinate IDs once a container wrote them, so its pruning runs through `podman unshare`.
Every workload defines the image unit of its image, which the module system merges into one per distinct image, referenced through quadlet-nix's `ref`.

## Directory layout

The layout follows systemd, Hugging Face and the engines' own defaults, and every engine reads the standard hub cache below `HF_HOME`, llama.cpp included.
The shared directory is no `CacheDirectory=`, since systemd ties those to one unit, so `systemctl clean` on any fetcher would wipe every model of the backend, and systemd would chown it recursively whenever an owner differs.
Fetchers and the update unit write it through `ReadWritePaths=`, while servers only read it, natively through `ProtectSystem=strict`.
Xet keeps its chunk cache in `xet/` beside `hub/`.
A rootless container finds its per-unit cache below `~/.cache` through `%C`, as a user unit's `CacheDirectory=` does.
Each per-unit directory carries its unit's name, which the units registry keeps unique, so `systemctl clean <unit>` removes exactly what that server regenerates.

## Offline servers

`HF_HUB_OFFLINE` makes vLLM and SGLang resolve a repository from the cache without any request.
`DO_NOT_TRACK` disables vLLM's usage statistics, and `VLLM_HOST_IP` keeps vLLM from deriving its address from a route to a public host, which an offline server lacks.
A socket server's own network namespace keeps `lo` for NCCL, while the socket stays reachable through the filesystem.
A native server on a port is limited through the cgroup IP filter to `127.0.0.1` and `::1` rather than all of `localhost`, since `127.0.0.53` is the resolver stub of systemd-resolved.
It can still reach other loopback services, llmhop's own listener included.
Native servers also cannot see `/run/nscd` and `/run/systemd/resolve`, through which glibc would resolve names outside the unit's network namespace.

## Containers

The container rootfs stays writable, since ML runtimes scatter JIT and compile caches across version-dependent `HOME` paths that an immutable rootfs would need an ever-growing tmpfs allow-list for.
`/tmp` is a tmpfs for fast scratch, where torch inductor puts `/tmp/torchinductor_root`.
