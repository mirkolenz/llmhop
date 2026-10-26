# Module internals

Why the NixOS module in `nix/modules/` works the way the README describes, recording decisions that are hard to re-derive from the code.

## CLI dialects

Each engine declares how its parser reads booleans (`negateBools`) and lists (`listStyle`), with the rules the README's settings rendering lists.
Neither axis can be delegated to nixpkgs.
`lib.cli.toCommandLine` renders neither, since its `optionFormat` never sees the value and its list handling always repeats.
The `mkBool` and `mkList` hooks of `lib.cli.toGNUCommandLine` could, but it is deprecated as of nixpkgs 25.11 and warns on every evaluation.
Non-string values go through JSON, which keeps `0.6` from becoming `0.600000` as `toString` would make it.

## Worker hardening

Native workers start from a `systemd-exec(5)` baseline shared with the llmhop reverse proxy.
Quadlet workers skip it, because Podman isolates at the container level.
The baseline denies binding any IP socket with `SocketBindDeny = "any"`, which only a worker with a `port` lifts for that port, and which leaves unix sockets alone.

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
transformers keeps the remote code of `trust_remote_code` models in `$HF_HOME/modules`, so `HF_MODULES_CACHE` moves it out of the read-only hub cache.
SYCL and the Intel compute runtime cache their SPIR-V to ISA compilation only when asked to, which turns a multi-minute JIT into a one-time cost.

## Unix sockets

Each workload without a `port` gets a directory of its own below `socketDirectory` rather than a `<unit>.sock` in one flat directory, which every worker would have to write, letting one delete or squat another's socket.
`connect()` needs search permission on each directory and write permission on the socket.
The root is `root:root` with mode `0711`, so anyone may pass but not list it, and each directory has mode `0710`, since every client knows the name.
vLLM and llama.cpp bind with the umask and never `chmod`, so workers run with `UMask = "0007"` and containers with `--umask=0007`, as Quadlet's own `Umask=` is newer than podman 6.1.
llmhop's own socket listeners share the root, with ownership and mode from their listener options.

A native worker's directory and socket belong to the backend's `group`, which every user of `socketClients` joins, the usual pattern for a socket client.
An ACL cannot work there, because systemd drops every ACL of an exec directory when it chowns it to a non-root unit.
Workers of one backend can therefore reach each other's sockets, but not those of another backend, and a client gets every socket of a backend or none, which is why `socketClients` is not per model.

A container user maps to an unpredictable host ID under `UserNS=`, so Quadlet sockets rely on a default ACL `user:<client>:-wx` for each of `socketClients` on the root, inherited below it.
That is why llmhop runs as a named user, which its gateway adds to `socketClients`, since no ACL could name a `DynamicUser` in advance.
The ACL survives, because systemd never chowns these directories, as the units run as root.
The kernel masks a new socket's mode with the umask even below a default ACL, and the ACL mask follows the group bits, so `--umask=0007` keeps the ACL's write.
The owning group's own entry comes from the root's `0711` and grants no write.

Each directory is a `RuntimeDirectory=` of its unit, removed on stop and crash alike, so no stale socket makes a restarted server fail with `EADDRINUSE`, although neither server removes one itself.
That is also why `socketDirectory` must stay below `/run`.
A rootful container mounts its directory with `U`, so Podman hands it to the mapped container user, and ACLs survive the `chown`.

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

`mkUvEnv` checks unresolved libraries only on the assembled environment and counts a soname that any file in it carries as resolved, since wheels rarely link siblings through the runpath, as torch preloads the CUDA wheels and torchcodec expects torch to be loaded.

## Lifecycle

Servers restart with `Restart = "always"`, because vLLM and SGLang catch an EngineCore death, shut down gracefully and exit 0, which `on-failure` would leave dead.
A shared `StartLimitBurst` of 3 per hour still breaks crash loops, so journald surfaces the underlying error.
`TimeoutStartSec` allows an hour for loading and GPU memory profiling, since downloads happen in the fetcher beforehand.
Startup is chained by ascending `name`, because two workers profiling GPU memory on the same device each see it as free and race into an OOM.
The chain only works because a worker stays `activating` until its server is ready.

A native worker is `Type=exec` with a `postStart` loop that polls `/health` until it answers 200, the readiness idiom of nixpkgs.
The loop also watches `$MAINPID`, since systemd waits for `ExecStartPost=` to finish even after the main process died, which would otherwise hold a crashed server in `activating` until `TimeoutStartSec`.

## Fetching

A fetcher mirrors a Quadlet image unit, a oneshot with `RemainAfterExit=`.
The server `Wants=` its fetcher and is ordered after it, but does not `Requires=` it as a container does its image, since that would propagate every restart by `<backend>-update` to the server, changed model or not.
The fetcher shares its server's identity, a named user natively and, in a container, whatever `User=` and `UserNS=` the deployer gives both, so both see the cache under one owner.
That is why llama.cpp does not use `DynamicUser` either.

A failed download keeps the cache only while it holds the requested revision, a ref of that name or a snapshot of that commit, with `main` standing for the default branch, as huggingface_hub records it.
llama.cpp names the default branch's ref after the branch, but pins no revision, so any of its refs will do.

The fetcher records the refs and snapshot files of its repositories before downloading and compares them afterwards.
A change runs `try-restart`, which leaves a stopped server alone, and a failed server is reset and started again.
Both run with full privileges, since a native fetcher's user may not manage units, and with `--no-block`, since the server is ordered after the fetcher.

`<backend>-update` restarts every fetcher with full privileges, one at a time in startup order, so each server restart is queued after that of its predecessor and the startup chain holds.
Pruning keeps every ref of llama.cpp, since all of them name a default branch, and removes the blobs no remaining snapshot resolves to, including the shared blob store of recent `huggingface_hub` releases, but only extensionless ones, so a concurrent download keeps its `.incomplete` files.

## Claims

Ports, unit names, routing keys and cache directories each admit only one owner, but nothing in NixOS would reject a second one at evaluation.
A port clash fails at boot, a unit or routing key clash merges silently or fails with an opaque conflict, and a shared cache directory lets one backend prune the other's models.
So every owner adds its option path to the internal `services.llmhop.claims.<kind>.<key>`, and one assertion per key names all owners of a clash.
This also keeps a native backend and its Quadlet twin apart, which share unit names and the default cache directory.

## Directory layout

The layout follows systemd, Hugging Face and the engines' own defaults, and every engine reads the standard hub cache below `HF_HOME`, llama.cpp included.
`cache.directory` holds it in `hub/`, each server keeps its compile and runtime caches in `/var/cache/<unit>` and, natively, its state in `/var/lib/<unit>`, and containers mount each directory at its host path.
The shared directory is no `CacheDirectory=`, since systemd ties those to one unit, so `systemctl clean` on any fetcher would wipe every model of the backend, and systemd would chown it recursively whenever an owner differs.
Fetchers and the update unit write it through `ReadWritePaths=`, while servers only read it, natively through `ProtectSystem=strict`.
Xet keeps its chunk cache in `xet/` beside `hub/`.
Each per-unit directory carries its unit's name, so `systemctl clean <unit>` removes exactly what that server regenerates.

## Offline servers

`HF_HUB_OFFLINE` makes vLLM and SGLang resolve a repository from the cache without any request, and llama.cpp gets `--offline`.
Both apply even with `offline = false`, since only the fetcher writes the hub cache.
`DO_NOT_TRACK` disables vLLM's usage statistics, and `VLLM_HOST_IP` keeps vLLM from deriving its address from a route to a public host, which an offline server lacks.
A socket server's own network namespace keeps `lo` for NCCL, while the socket stays reachable through the filesystem.
A native server on a port is limited through the cgroup IP filter to `127.0.0.1` and `::1` rather than all of `localhost`, since `127.0.0.53` is the resolver stub of systemd-resolved.
It can still reach other loopback services, a gateway's listener included.
The filter applies to both directions, so a server on another `host` goes without it, since it could not tell the clients from the destinations it must not reach.
Native servers also cannot see `/run/nscd` and `/run/systemd/resolve`, through which glibc would resolve names outside the unit's network namespace.

## Gateways

A gateway in front of another gateway only duplicates routing, auth and limits, and a model reachable beside it voids its auth, so the module runs at most one and keeps every model it routes on loopback.
Routed models leave authentication to the gateway.
Backends never configure a gateway, but publish their workloads to the internal `services.llmhop.endpoints`, which the selected gateway renders into its own configuration, so a new gateway is one more module and no backend changes.
Each gateway module adds its name to `gateway.type`, an enum whose declarations merge, and lists the endpoints it routes in the internal `gateway.routes`, which the shared assertions check.

Only llmhop routes the detectors, which neither SMG's discovery nor Bifrost's providers can describe.
The external gateways run on the host network in a container, so they reach the models on loopback like their native variants, and as dynamic users natively, since no socket ACL has to name them.
SMG gives up on the workers of `--worker-urls` after its startup timeout, while loading a model may take an hour, so it gets a discovery file instead, and it forwards the client's `Authorization` to the worker, the other reason routed models carry no key.
Bifrost reconciles its `config.json` into a SQLite store in its app directory, by default in `split` mode, so the file seeds and updates each section while changes made through its UI survive until that section of the file changes.
It has no llama.cpp provider, but its vLLM one serves any OpenAI-compatible server with a URL per key, as its SGLang one does.
llmhop resolves its own secret references at startup.
SMG receives credential file paths through upstream flags such as `--api-key-file` and `--tenant-api-keys-file`, requiring a build that supports them.
Bifrost receives its native `env.` references unchanged, with secrets loaded from `environmentFile` by systemd or Podman.
External gateways run directly, without shell wrappers for secrets.

## API keys

Without a gateway, configure each model's authentication through its server's file-based settings.
llama.cpp reads keys through `settings.api-key-file`.
vLLM and SGLang read a private YAML credential containing `api-key` through `settings.config`, with a `.yaml` credential name for vLLM.
Credential references resolve to file paths for both native services and containers, so the server reads its secrets directly without a shell wrapper or a generated temporary config.

## Watermarking

`mkVllmWatermark`'s `serve` command merges the key into the `--watermark-config` of `vllm serve` in-process, and its `detect` command replaces vLLM's example detector, which lacks unix sockets, a health endpoint, a file-based key and every algorithm but `gumbel`.
The detector picks its class by vLLM's naming conventions, so a new upstream algorithm that follows them works unchanged, and one that does not fails loudly.
Native builds check the script against the vLLM environment, so a `uv lock` that breaks it fails the build, while containers run it unchecked with the image's interpreter and fail at startup instead.

## Containers

The container rootfs stays writable, since ML runtimes scatter JIT and compile caches across version-dependent `HOME` paths that an immutable rootfs would need an ever-growing tmpfs allow-list for.
`/tmp` is a tmpfs for fast scratch, where torch inductor puts `/tmp/torchinductor_root`.
Every workload defines the image unit of its image, which the module system merges into one per distinct image, referenced through quadlet-nix's `ref`.
Image unit names hash the complete reference, so repositories using the same tag remain distinct.
Quadlet Nix starts image units and oneshot fetchers only when a dependent starts, while servers start at boot.
