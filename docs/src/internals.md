# Module internals

Decisions behind the NixOS and system-manager modules in `nix/modules/` that are hard to re-derive from the code.
Both import the matching module of quadlet-nix, so they share all of llmhop's modules.
The global `services.llmhop.runtime` runs every backend and the gateway either `native` or as `container`, since mixing them doubled every feature and left the gateway unable to reach some workloads, and `mkQuadletBundle` sets `container`.

## Layout

`backends/engine.nix` instantiates one backend per entry of `engines.nix`, whose fields hold everything an engine does differently, from its CLI dialect to how it renders LoRA adapters and watermarks.
`backends/workload` holds the submodules of models and detectors and derives one record per enabled workload, its settings, command, credentials, repositories, aliases and assertions among them.
The records are the default of the internal, read-only `services.llmhop.<engine>.workloads`, typed by `workload/record.nix`, so the module system checks and evaluates them once, unlike the old `endpoints`, which several modules wrote into.
Capabilities such as `gpu`, `chained` and `unlisted` tell every consumer what a workload needs, rather than what kind it is.
`native.nix` with `fetch.nix`, or `container.nix`, renders the units of a backend from its records, and `gateway` those of the gateway.

## CLI dialects

Each engine declares how its parser reads booleans (`negateBools`) and lists (`listStyle`), as separate values or joined by commas.
nixpkgs cannot render both: `lib.cli.toCommandLine` always repeats list flags and never sees the value when naming a flag, and `lib.cli.toGNUCommandLine` is deprecated.
Non-string values go through JSON, which keeps `0.6` from becoming `0.600000`.

## Worker hardening

Native units share a `systemd-exec(5)` baseline, while containers rely on Podman's isolation.
The baseline denies binding IP sockets with `SocketBindDeny = "any"`, which a worker with a `port` lifts for that port.

### GPU relaxations

- `PrivateDevices = false` and the `render` and `video` groups give access to the CUDA, ROCm and Level Zero device nodes.
  A model's `native.devices` narrows it with `DevicePolicy = "closed"` and `DeviceAllow`.
  With the NVIDIA driver enabled, it defaults to the device groups `char-nvidia`, `char-nvidiactl` and `char-nvidia-uvm` of `/proc/devices`, which CUDA needs.
  Groups cover every GPU, since the minor of `/dev/nvidia<N>` follows probe order and may change between boots, so `CUDA_VISIBLE_DEVICES` places a model instead.
  It takes GPU UUIDs, or indices, which `CUDA_DEVICE_ORDER = "PCI_BUS_ID"` on every server ties to the slots.
  Level Zero's indices follow the slots through `ZE_ENABLE_PCI_ID_DEVICE_ORDER = "1"`, while ROCm offers no such switch, so `ROCR_VISIBLE_DEVICES` should take GPU UUIDs.
  ROCm needs `/dev/kfd` beside `char-drm`, and Level Zero only the latter.
- `PrivateUsers = "identity"`, since `true` would map those groups to `nobody`.
- `MemoryDenyWriteExecute = false` for the JIT compilers of torch, triton, CUDA and SYCL.
- `LimitMEMLOCK = "infinity"`, since every stack pins host buffers and the default 8 MiB reports OOM.
- `ProcSubset = "all"` for `/proc/meminfo` and `/proc/cpuinfo`.

### NCCL relaxations

`getifaddrs()` needs `AF_NETLINK`, and NCCL binds ephemeral TCP ports, which the bind hook sees as port 0, so all TCP is allowed.
NCCL and Gloo are kept on loopback and NCCL off InfiniBand, which RCCL honors too.
Gloo would otherwise bind the address the hostname resolves to, such as `127.0.0.2` on NixOS, which the IP address filter of an offline server drops.

### Implicit configuration

llama.cpp reads `/etc/llama.cpp/config.ini` and one below `XDG_CONFIG_HOME` before its arguments, with no way to opt out.
Natively, the first would apply an undeclared host file to every server and fetcher, and the second sits in the writable `HOME` of the server, which could plant one for its next start.
So every unit hides the former and points `XDG_CONFIG_HOME` at the empty `/var/empty`.

### Caches

Every accelerator stack caches compiled kernels below `$HOME`, which is read-only, so each cache variable points into the workload's cache directory, set unconditionally since an absent stack never reads it.

## Unix sockets

Only native workloads bind unix sockets, since a container's user maps to an unpredictable host ID.
Each socket lives in a directory of its own below `socketDirectory`, so no worker can delete or squat another's socket.
The root is `root:root` with mode `0711` and each directory `0710`, since clients know the name, and servers run with umask `0007`, since they never `chmod` their socket.

A worker's socket belongs to the backend's `group`, which every user of `socketClients` joins, since systemd drops ACLs when it chowns an exec directory.
That is why the gateway runs as a named user rather than a `DynamicUser`.

Each directory is a `RuntimeDirectory=` of its unit, removed on every stop, so no stale socket causes `EADDRINUSE`, which is why `socketDirectory` must stay below `/run`.

## Python backends built from wheels

The wheel-based backends get a compiler, `ninja` and `bash` on `PATH`, since triton, torch and flashinfer compile at runtime and look them up the FHS way, and `HOME` points at the cache directory.
`LD_LIBRARY_PATH` covers driver libraries loaded by name, such as `libnvidia-ml.so.1`, and `TRITON_LIBCUDA_PATH` replaces triton's `ldconfig -p` lookup.
They cannot use `DynamicUser`, whose ID-mapped state and cache mounts are noexec, while these runtimes load the kernels they compile there.

## Lifecycle

Servers use `Restart = "always"`, since vLLM exits 0 after an engine crash, with a start limit of 3 per hour against crash loops.
They stop with SIGTERM, which every engine handles as a graceful stop, and SGLang as its only draining one.
vLLM drains for `shutdownTimeoutSeconds` and aborts the rest, SGLang drains until its unit kills it, ten seconds later, so every engine bounds a stop by the same time.
A container gets that time as Podman's `StopTimeout=`, and its unit ten seconds more, so Podman rather than systemd kills it.
A native server is `Type=exec` with an `ExecStartPost=` of `llmhop internal wait-healthy` that polls `/health` and also watches `$MAINPID`, so a crashed server does not stay `activating` until the timeout.
Containers use Podman's `Notify=healthy`.
Startup is chained by `name`, since two workers profiling GPU memory on one device both see it free and run out of memory.
Each server `Wants=` its predecessor besides starting after it, since `After=` only orders jobs queued together, and `switch-to-configuration` queues its starts one at a time in no particular order.
Starting a server thus also queues its predecessors, which are no-ops while they run.
The gateway is `PartOf=` its listeners, so restarting a socket also restarts the gateway that holds it.
Listener configuration changes also trigger a native gateway restart on NixOS.
Its config lives at the stable path `/etc/llmhop/config.json` with `reloadTriggers`, so a changed config reloads it in place, since a restart would hold new connections in its sockets until every streaming response drained.

## Fetching

Only native servers have fetchers, since a fetcher and its refresh unit share the cache with the server, which a container would have to own across a user namespace on the host.
A fetcher is a oneshot with `RemainAfterExit=`, which its server `Wants=` and is ordered after, but does not `Requires=`, so a failed fetch leaves a running server alone.
It shares its server's identity, so both see the cache under one owner, and every workload has its own cache, so no fetch changes what another server loaded.
Fetchers keep systemd's default start limit, since they do not restart automatically and may need several manual retries.

Every start or restart of a fetcher also starts `<unit>-refresh`, which it `Wants=`.
The refresh unit `Requires=` and follows the fetcher, so it only acts on a complete download.
It prunes the cache to the workload's repositories and revisions, then restarts the server.
Telling a changed model from an unchanged one would need state, since a moved ref can leave its previous commit pinned by another revision, so every successful fetch restarts a running server, which the weekly default of `fetch.schedule` keeps rare.
It resets the server's start limit first, so planned restarts do not use it up, and `try-restart` leaves a stopped or failed server down, so a server that hit its start limit waits for a manual start.
The server starts after it, so a first download finds the server still waiting rather than restarting it.

The fetcher controls everything in the cache, so no command touching it runs with more privileges than the cache owner, or a planted symlink could redirect a privileged write or deletion.
The refresh unit prunes as the workload's `user`, writing only the hub cache and opening no socket, since a root owner could otherwise reach systemd or Podman.
Only its `systemctl` step runs as root, and it reads no file.

`huggingface_hub` moves a ref before downloading its snapshot, so an interrupted download leaves the ref on an incomplete snapshot, which an offline server fails to load until the next complete download.

`<backend>-update` restarts every fetcher one at a time in startup order, so the server restarts keep to the startup chain.

## Claims

Ports, unit names and model names admit one owner each, but NixOS merges clashing units silently or fails opaquely, and port clashes only fail at boot.
So every owner adds its option path to the internal `services.llmhop.claims.<kind>.<key>`, and an assertion names all owners of a clash.
The gateway builds its models keyed by name, so a name clash reaches that assertion instead of silently dropping a model.

## Directory layout

Each native workload's `cache.directory/<name>` is the `HF_HOME` of its fetcher and server, holding the hub cache in `hub/`, which the server can only read, beside the server's runtime caches.
It is no `CacheDirectory=`, which would have to stay below `/var/cache`.
A container keeps everything in the named volume of its unit at `/var/cache/llmhop`, which Podman creates on first use, so a bundle needs no tmpfiles rule.

## Offline servers

Native servers get `HF_HUB_OFFLINE` and `LLAMA_ARG_OFFLINE` only with `fetch.enable`, since otherwise they download their repositories themselves, and vLLM always gets `VLLM_HOST_IP`, since it would otherwise derive its address from a route to a public host.
A socket server gets its own network namespace, keeping `lo` for NCCL.
A native server on a loopback port is limited to `127.0.0.1` and `::1` by the cgroup IP filter, not all of `127.0.0.0/8`, which holds the systemd-resolved stub, and cannot see `/run/nscd` and `/run/systemd/resolve`.
The filter applies to both directions, so it cannot isolate a server that accepts clients beyond loopback, and a container's published port needs a network.
The function `isolable` of `backends/workload` captures this, deriving the default of `offline` and the one assertion rejecting `offline = true` where it would not hold, so no container silently runs an `offline` server with network access.

## Gateway

The gateway is llmhop alone, since chained gateways duplicate routing and auth, and other gateways could neither reach unix sockets, route detectors nor describe LoRA adapters.
A workload reachable beside it bypasses its auth, hence the loopback assertion.
SGLang serves an adapter as `<served>:<adapter>` and falls back to the base model for any other name, so the gateway rewrites the `model` of a JSON body sent to an adapter's alias.
Both runtimes share the `listen` options, socket units, claims and firewall rules, and never bind themselves, since their config must not set `listen`.
Podman passes the sockets of the units listed in the container's `Sockets=` into the container, which stays on the host network to reach the published ports of the workloads.

## Watermarking

vLLM reads its key file through `key_file` of its `WatermarkConfig`, so its servers need no wrapper.
SGLang only reads keys from its config, so `serve` of the watermark script merges the keys into it in-process and writes it to the server's private `/tmp` before running `sglang serve`, keeping them off the command line.
Its `detect` replaces the example detectors of both engines, which lack unix sockets, health, file-based keys, several profiles and most algorithms, dispatching to the detector of the engine whose environment runs it.
Native builds check the script against that environment, while containers run it unchecked with the image's Python.

## Bundles

Bundles come from quadlet-nix, which renders every rootful Quadlet unit of the system, its auto-update units, and the sockets named by `bundle.sockets`, and copies the store paths they reference below `bundle.assetDirectory`.
The container gateway names its `llmhop-<name>` listeners there, so the bundle carries their socket units.
The build fails if a copied file still references the store, so only self-contained files such as configs, the watermark script and the gateway's image archive can be bundled, which is why bundles hold no native units.

## Containers

The gateway container loads an archive of the image built with the binary that validated its config, so the running version always matches, it needs no registry, and it updates with the system or bundle rather than through `podman auto-update`.
Its image unit restarts it when restarted.
A backend references its image directly with Podman's default `Pull=missing`, so a start needs no registry once pulled, and a changed image changes and thereby restarts every container.

The container rootfs stays writable, since ML runtimes scatter caches across `HOME`, and `/tmp` is a tmpfs.
Every container runs in a user namespace of its own from the `containers` range, so a breakout lands on an unprivileged host ID that no other container shares.
Podman may allocate another range whenever Quadlet recreates the container, so every volume and the credentials are mounted with `idmap`, which maps their files onto whatever range the container gets, rather than chowning a whole model cache on every start.
The credentials belong to host root, so idmap is what lets a namespaced root read them at all.

