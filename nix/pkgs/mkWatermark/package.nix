# The watermark script of vLLM and SGLang: `serve` runs a server reading its
# keys from files and `detect` the detection server. `checked` builds it for
# an engine's environment, which must import it and detect with every
# algorithm the release declares, so an update breaking either fails the
# build rather than the service. Its output is the script itself, run by
# that environment's Python, while a container runs the unchecked `source`.
{
  lib,
  runCommandLocal,
}:
{
  source = ./watermark.py;
  checked =
    engine: environment:
    runCommandLocal "${engine}-watermark.py" { } ''
      cp ${./watermark.py} watermark.py
      HOME="$TMPDIR" ${lib.getExe' environment "python"} -c 'import watermark; watermark.check("${engine}")'
      cp watermark.py "$out"
    '';
}
