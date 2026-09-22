# Merged CUDA prefix for the JIT compilers a model server shells out to at
# runtime. They look for `nvcc` on `PATH` or below `/usr/local/cuda` unless
# `CUDA_HOME` points somewhere else, and the CUDA wheels cannot serve as that
# prefix: they ship a runtime toolkit, without the `libcudart.so` namelink and
# without a driver stub to link against.
{
  lib,
  pkgs,
}:
{
  # The CUDA packages to merge. No default: which ones a server's JIT path needs
  # follows from that server and from the CUDA line its wheels were built for,
  # so the caller states both at once by naming them out of one `cudaPackages_*`
  # set.
  packages,
  name ? "cuda-home",
}:
pkgs.symlinkJoin {
  inherit name;
  # `symlinkJoin` links outputs and drops propagation, so every output a package
  # splits its headers and libraries across has to be named rather than reached
  # through the one that propagates it. `static` is the only one nothing loads
  # at runtime. `cudaPackages.cudatoolkit` flattens the same way.
  paths = lib.concatMap (package: lib.filter (out: out.outputName != "static") package.all) packages;
  # Some of them link against `lib64` and `lib64/stubs`, a layout that only the
  # retired runfile installer ever produced.
  postBuild = "ln -s lib $out/lib64";
}
