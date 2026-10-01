# vLLM watermarking with a file-based key: `serve` runs `vllm serve` and
# `detect` the detection server. Checked against the environment it runs
# under, it must import and detect with every algorithm the release declares,
# so an update breaking either fails the build rather than the service. The
# output is the script itself, run by that environment's Python.
{
  lib,
  runCommandLocal,
}:
vllm:
runCommandLocal "vllm-watermark.py" { } ''
  cp ${./watermark.py} watermark.py
  HOME="$TMPDIR" ${lib.getExe' vllm "python"} -c 'import watermark; watermark.check()'
  cp watermark.py "$out"
''
