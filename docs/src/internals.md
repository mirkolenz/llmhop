# Module internals

Background for the NixOS module implementation in `nix/modules/`.
None of it is needed to use the module, but it records decisions that are hard to re-derive from the code alone.

## CLI dialects

Two `settings` shapes have no portable rendering, so each backend declares how its parser reads them.
The table is keyed by the unsuffixed service name, so a native backend and its Quadlet twin share one entry.

`negateBools` says the parser registers a `--no-<key>` twin for every boolean, which argparse's `BooleanOptionalAction` and llama.cpp's paired flags both do.
SGLang instead pairs `--enable-X` with `--disable-X` and rejects `--no-X`.

`listStyle` picks between handing every element to one flag (`--key a b`), what argparse `nargs` and clap multi-value options take, and emitting the flag once per element (`--key a --key b`), all that llama.cpp's hand-rolled parser understands.
llama.cpp also takes only `--key value`, never `--key=value`.
Both argparse backends register a few options in the other style, so this is the dominant form for a backend rather than a guarantee for every flag.

Neither axis can be delegated to nixpkgs.
`lib.cli.toCommandLine` renders neither: its `optionFormat` never sees the value, and list handling is hardcoded to repeat-style.
The `mkBool` and `mkList` hooks of `lib.cli.toGNUCommandLine` could, but it is deprecated as of nixpkgs 25.11 and warns on every evaluation.

Values are rendered by Nix type: strings, paths and derivations verbatim, everything else through JSON.
That keeps `0.6` from becoming `0.600000` (what `toString` makes of a float) and turns an attribute set into the JSON object that options like vLLM's `--speculative-config` parse.

## Worker hardening

Native workers start from a universal `systemd-exec(5)` baseline shared with the llmhop reverse proxy.
Quadlet workers skip it, because Podman handles isolation at the container level.
`SocketBind*` is not part of the baseline: it pairs with a per-unit `SocketBindAllow` that only worker units declare.

### GPU relaxations

- `PrivateDevices = false`: GPU acceleration needs raw device access, `/dev/nvidia*` for CUDA and `/dev/kfd` plus `/dev/dri/renderD*` for ROCm and Level Zero. The upstream NVIDIA NixOS modules disable it for the same reason.
- `SupplementaryGroups = [ "render" "video" ]`: `/dev/nvidia*` is world-readable, but systemd's default udev rules leave the AMD and Intel nodes group-owned, so a worker running as a real user cannot open them without joining those groups.
- `PrivateUsers = "identity"`: those groups only mean anything if their GIDs survive into the worker's user namespace, and the baseline's `PrivateUsers = true` maps everything but the unit's own identity to `nobody`. `identity` keeps the namespace but maps the first 65536 IDs one-to-one.
- `MemoryDenyWriteExecute = false`: runtime kernel compilation mmaps `PROT_WRITE|PROT_EXEC` pages. torch-inductor and triton, the CUDA driver's PTX to SASS pass, and the SPIR-V JIT behind SYCL and Level Zero all do it.
- `LimitMEMLOCK = "infinity"`: page-locked memory draws from `RLIMIT_MEMLOCK`, which systemd otherwise caps at its 8 MiB default. Every stack pins the host side of its device buffers, and llama.cpp's `--mlock` pins the weights outright. Too low a limit reports OOM despite free VRAM.
- `ProcSubset = "all"`: the baseline's `pid` hides everything in `/proc` that is not a process directory, but psutil, torch and NUMA discovery all read `/proc/meminfo` and `/proc/cpuinfo`, so the engine dies before it reaches the GPU. `ProtectProc` still keeps other users' process directories invisible.

### NCCL relaxations

`getifaddrs()` opens an `AF_NETLINK` socket during its interface scan, so that family is re-added to `RestrictAddressFamilies`.
The bootstrap, proxy and RAS listeners bind ephemeral (port 0) TCP sockets, which `SocketBindDeny = "any"` refuses.
The bind hook only ever sees port 0, never the assigned port, so allow-all-TCP is the tightest workable rule, and it already covers the worker's own listener.
UDP stays denied.

NCCL is additionally kept on loopback and off any InfiniBand fabric, since there is none on a single node.
RCCL is an API clone of NCCL and reads the same variables, so this covers AMD as well; oneCCL (Intel) uses `CCL_*` and ignores them.

### Caches

Every accelerator stack compiles kernels on first use and caches them next to `$HOME`, which `ProtectSystem = "strict"` makes read-only, so each one is redirected into the unit's own cache root, the single place `systemctl clean` can reach.
All of the variables are set unconditionally: one belonging to a stack that is not installed is never read, which is cheaper than tracking which host has which vendor.
MIOpen (ROCm) needs two of them, or its kernel database and its compiled-kernel cache land under separate `$HOME` roots.
SYCL and the Intel compute runtime only cache their SPIR-V to ISA compilation when asked to, which is what turns a multi-minute JIT into a one-time cost across restarts.

## Python backends built from wheels

The vLLM and SGLang backends run from prebuilt wheels and need more than the hardening baseline.

They get a toolchain on `PATH`, because these runtimes compile at runtime and look one up the FHS way.
Triton builds its CUDA driver shim on the first kernel launch and searches `$CC`, then `gcc`/`clang` on `PATH`.
torch's `cpp_extension` and flashinfer's JIT drive their builds through `ninja`, which nixpkgs patches to `posix_spawnp("sh")`, so it needs a shell on `PATH` rather than at `/bin/sh`.
ctypes falls back to invoking `gcc` and `ld` once nixpkgs' patched `ldconfig` lookup returns nothing.
A unit otherwise has none of them.

`HOME` is pointed at the cache root because the service user has none, so `$HOME` would be `/` and every library that reaches for `~` (flashinfer's JIT workspace, among others) would hit the read-only root.

`LD_LIBRARY_PATH` and `TRITON_LIBCUDA_PATH` are about prebuilt wheels finding host driver libraries rather than about GPUs: a nixpkgs-built worker resolves the same libraries from the runpath `autoAddDriverRunpath` gave it at build time.
`mkUvEnv` bakes that runpath into the wheels too, so `libcuda.so.1` and its ROCm and Level Zero counterparts resolve via RPATH.
`LD_LIBRARY_PATH` additionally covers the host driver libraries the framework `dlopen`s by name from Python during GPU-memory profiling, such as `libnvidia-ml.so.1`, which RPATH does not reach.
Triton locates `libcuda.so.1` by shelling out to `/sbin/ldconfig -p`, which does not exist on NixOS, so its JIT backend dies with a `FileNotFoundError` the moment a kernel is compiled; `TRITON_LIBCUDA_PATH` is the upstream escape hatch and short-circuits the lookup entirely.

These backends run as a real system user rather than under `DynamicUser`.
The `/var/lib/private` layout `DynamicUser` implies makes systemd hand `StateDirectory` and `CacheDirectory` over as ID-mapped mounts, which are unconditionally noexec and beyond the reach of `ExecPaths=`, and these runtimes compile kernels into that cache and `dlopen` them back.
llama.cpp compiles nothing at runtime and keeps `DynamicUser`.

## Lifecycle

Model workers restart with `Restart = "always"` rather than `on-failure`.
vLLM and SGLang catch an EngineCore death, shut the API server down gracefully, and exit 0, so `on-failure` would leave a crashed worker dead.
A shared `StartLimitBurst` of 3 errors per hour still breaks crash loops, so journald surfaces the underlying error instead of an endless restart.
`TimeoutStartSec` allows an hour, which covers cold-start model downloads plus GPU memory profiling.

Workers are chained by ascending `port` during startup.
GPU-memory profiling races otherwise: two workers booting on the same device each see it as fully free and race to claim their share, leading to OOM.
The chain is only meaningful because a worker is held in `activating` until its server reports itself ready, which `llmhop-notify` does for native units and `Notify=healthy` for containers.

`llmhop-notify` is resolved from this flake rather than from `services.llmhop.package`: it is a module implementation detail, and a deployer-supplied llmhop build need not ship it at all, in which case `getExe'` would not catch that and every worker would sit in `activating` until `TimeoutStartSec`.

## Containers

The container rootfs stays writable.
ML runtimes scatter JIT and compile caches across version-dependent `HOME` paths, so an immutable rootfs would need an ever-growing tmpfs allow-list.
`/tmp` is a tmpfs for fast scratch, which is where torch inductor puts `/tmp/torchinductor_root`.
