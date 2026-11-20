# Merged CUDA prefix for the JIT compilers a model server shells out to at
# runtime. They look for `nvcc` on `PATH` or below `/usr/local/cuda` unless
# `CUDA_HOME` points somewhere else, and the CUDA wheels cannot serve as that
# prefix: they ship a runtime toolkit, without the `libcudart.so` namelink and
# without a driver stub to link against.
{
  lib,
  symlinkJoin,
  makeBinaryWrapper,
}:
{
  # The CUDA packages to merge. No default: which ones a server's JIT path needs
  # follows from that server and from the CUDA line its wheels were built for,
  # so the caller states both at once by naming them out of one `cudaPackages_*`
  # set.
  packages,
  name ? "cuda-home",
}:
symlinkJoin {
  inherit name;
  # `symlinkJoin` links outputs and drops propagation, so every output a package
  # splits its headers and libraries across has to be named rather than reached
  # through the one that propagates it. `static` is the only one nothing loads
  # at runtime. `cudaPackages.cudatoolkit` flattens the same way.
  paths = lib.concatMap (package: lib.filter (out: out.outputName != "static") package.all) packages;
  nativeBuildInputs = [ makeBinaryWrapper ];
  # Some of them link against `lib64` and `lib64/stubs`, a layout that only the
  # retired runfile installer ever produced.
  #
  # The `nvcc.profile` of nixpkgs only points nvcc at the headers and libraries
  # it ships with, and build environments add the rest through setup hooks.
  # Compilers that rely on nvcc's defaults, such as DeepGEMM's, would thus miss
  # `cuda_runtime.h`, so nvcc falls back to the merged prefix. The symlink is
  # replaced rather than wrapped in place, since `cuda_nvcc` already ships a
  # `.nvcc-wrapped`.
  postBuild = ''
    ln -s lib $out/lib64

    if [[ -e $out/bin/nvcc ]]; then
      nvcc=$(readlink -f $out/bin/nvcc)
      rm $out/bin/nvcc
      makeBinaryWrapper $nvcc $out/bin/nvcc \
        --suffix NVCC_APPEND_FLAGS " " "-I$out/include -L$out/lib/stubs -L$out/lib"
    fi
  '';
}
