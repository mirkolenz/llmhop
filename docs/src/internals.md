# Module internals

Decisions behind the NixOS module in `nix/modules/` that are hard to re-derive from the code.

## CLI dialects

Each engine declares how its parser reads booleans (`negateBools`) and lists (`listStyle`).
nixpkgs cannot render both: `lib.cli.toCommandLine` always repeats list flags and never sees the value when naming a flag, and `lib.cli.toGNUCommandLine` is deprecated.
Non-string values go through JSON, which keeps `0.6` from becoming `0.600000`.

## Worker hardening

Native units share a `systemd-exec(5)` baseline, while containers rely on Podman's isolation.
The baseline denies binding IP sockets with `SocketBindDeny = "any"`, which a worker with a `port` lifts for that port.

### GPU relaxations

- `PrivateDevices = false` and the `render` and `video` groups give access to the CUDA, ROCm and Level Zero device nodes.
- `PrivateUsers = "identity"`, since `true` would map those groups to `nobody`.
- `MemoryDenyWriteExecute = false` for the JIT compilers of torch, triton, CUDA and SYCL.
- `LimitMEMLOCK = "infinity"`, since every stack pins host buffers and the default 8 MiB reports OOM.
- `ProcSubset = "all"` for `/proc/meminfo` and `/proc/cpuinfo`.

### NCCL relaxations

`getifaddrs()` needs `AF_NETLINK`, and NCCL binds ephemeral TCP ports, which the bind hook sees as port 0, so all TCP is allowed.
NCCL and Gloo are kept on loopback and NCCL off InfiniBand, which RCCL honors too.
Gloo would otherwise bind the address the hostname resolves to, such as `127.0.0.2` on NixOS, which the IP address filter of an offline server drops.

### Caches

Every accelerator stack caches compiled kernels below `$HOME`, which is read-only, so each cache variable points into the workload's cache directory, set unconditionally since an absent stack never reads it.

## Unix sockets

Each socket lives in a directory of its own below `socketDirectory`, so no worker can delete or squat another's socket.
The root is `root:root` with mode `0711` and each directory `0710`, since clients know the name, and servers run with umask `0007`, since they never `chmod` their socket.

A native worker's socket belongs to the backend's `group`, which every user of `socketClients` joins, since systemd drops ACLs when it chowns an exec directory.
A container user maps to an unpredictable host ID, so container sockets rely on a default ACL `user:<client>:-wx` on the root instead.
That is why llmhop runs as a named user rather than a `DynamicUser`.

Each directory is a `RuntimeDirectory=` of its unit, removed on every stop, so no stale socket causes `EADDRINUSE`, which is why `socketDirectory` must stay below `/run`.

## Python backends built from wheels

The wheel-based backends get a compiler, `ninja` and `bash` on `PATH`, since triton, torch and flashinfer compile at runtime and look them up the FHS way, and `HOME` points at the cache directory.
`LD_LIBRARY_PATH` covers driver libraries loaded by name, such as `libnvidia-ml.so.1`, and `TRITON_LIBCUDA_PATH` replaces triton's `ldconfig -p` lookup.
They cannot use `DynamicUser`, whose ID-mapped state and cache mounts are noexec, while these runtimes load the kernels they compile there.

## Lifecycle

Servers use `Restart = "always"`, since vLLM and SGLang exit 0 after an engine crash, with a start limit of 3 per hour against crash loops.
A native server is `Type=exec` with a `postStart` loop that polls `/health` and also watches `$MAINPID`, so a crashed server does not stay `activating` until the timeout.
Containers use Podman's `Notify=healthy`.
Startup is chained by `name`, since two workers profiling GPU memory on one device both see it free and run out of memory.

## Fetching

A fetcher is a oneshot with `RemainAfterExit=`, which its server `Wants=` and is ordered after, but does not `Requires=`, so a failed fetch leaves a running server alone.
It shares its server's identity, so both see the cache under one owner, and every workload has its own cache, so no fetch changes what another server loaded.
Fetchers keep systemd's default start limit, since they do not restart automatically and may need several manual retries.

Every start or restart of a fetcher also starts `<unit>-refresh`, which it `Wants=`.
The refresh unit `Requires=` and follows the fetcher, so it only acts on a complete download.
It prunes the cache to the workload's repositories and revisions, then restarts the server.
Telling a changed model from an unchanged one would need state, since a moved ref can leave its previous commit pinned by another revision, so every successful fetch restarts a running server, which the weekly default of `fetch.interval` keeps rare.
It resets the server's start limit first, so planned restarts do not use it up, and `try-restart` leaves a stopped or failed server down, so a server that hit its start limit waits for a manual start.
The server starts after it, so a first download finds the server still waiting rather than restarting it.

The fetcher controls everything in the cache, so no command touching it runs with more privileges than the cache owner, or a planted symlink could redirect a privileged write or deletion.
The refresh unit prunes as `user`, or `cache.user` for Quadlet, writing only the hub cache and opening no socket, since a root owner could otherwise reach systemd or Podman.
Only its `systemctl` step runs as root, and it reads no file.

`huggingface_hub` moves a ref before downloading its snapshot, so an interrupted download leaves the ref on an incomplete snapshot, which an offline server fails to load until the next complete download.

`<backend>-update` restarts every fetcher one at a time in startup order, so the server restarts keep to the startup chain.

## Claims

Ports, unit names and model names admit one owner each, but NixOS merges clashing units silently or fails opaquely, and port clashes only fail at boot.
So every owner adds its option path to the internal `services.llmhop.claims.<kind>.<key>`, and an assertion names all owners of a clash.
Endpoints are keyed by owner too, so a name clash reaches that assertion instead of failing the merge.

## Directory layout

Each workload's `cache.directory/<name>` is the `HF_HOME` of its fetcher and server, holding the hub cache in `hub/`, which the server can only read, beside the server's runtime caches.
It is no `CacheDirectory=`, which would have to stay below `/var/cache`, and containers mount it at the same path.

## Offline servers

Servers get `HF_HUB_OFFLINE`, llama.cpp `--offline`, and vLLM `VLLM_HOST_IP`, since it would otherwise derive its address from a route to a public host.
A socket server gets its own network namespace, keeping `lo` for NCCL.
A native server on a loopback port is limited to `127.0.0.1` and `::1` by the cgroup IP filter, not all of `127.0.0.0/8`, which holds the systemd-resolved stub, and cannot see `/run/nscd` and `/run/systemd/resolve`.

## Gateways

At most one gateway runs, since chained gateways duplicate routing and auth, and a model reachable beside the gateway bypasses its auth.
Backends publish their workloads to the internal `services.llmhop.endpoints`, which the selected gateway renders, so a new gateway needs no backend changes.
Each gateway module adds its name to the `gateway.type` enum.
Only llmhop routes detectors, which neither SMG's discovery nor Bifrost's providers can describe.
SMG gets a discovery file, since it gives up on `--worker-urls` after a startup timeout shorter than model loading.
External gateways run as dynamic users or on the host network in a container, reaching models on loopback.

## Watermarking

`mkVllmWatermark`'s `serve` merges the key into vLLM's watermark config in-process, and its `detect` replaces vLLM's example detector, which lacks unix sockets, health, file-based keys, several profiles and most algorithms.
Native builds check the script against the vLLM environment, while containers run it unchecked with the image's Python.

## Bundles

A bundle renders the same units as NixOS and only rewrites their paths: the store path of `systemctl` becomes the host's own, `hub-prune` runs with the `python3` on `PATH`, and every other store path they reference is copied below `bundle.assetDirectory` under its store name.
The build fails if a copied file still references the store, so only self-contained files such as scripts, configs and the llmhop image archive can be bundled.
The bundle adds the `[Install]` section that quadlet-nix leaves to NixOS, and renders the update and refresh units and their timers itself, since the NixOS ones set a store `PATH=`.
`install.sh` restarts every running unit whose file it changes, so a reinstalled bundle replaces the running deployment, and a changed image unit restarts the containers requiring it.

## Containers

The llmhop container loads an archive of the image built with the binary that validated its config, so the running version always matches, it needs no registry, and it updates with the system or bundle rather than through `podman auto-update`.

The container rootfs stays writable, since ML runtimes scatter caches across `HOME`, and `/tmp` is a tmpfs.
Every container of a backend runs the backend's image unit, which quadlet-nix starts only when a dependent starts.
