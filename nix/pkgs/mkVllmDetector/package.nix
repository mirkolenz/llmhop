# The watermark detector server for vLLM, checked against the environment it
# runs under: it must import and detect with every algorithm the release
# declares, so an update breaking either fails the build rather than the
# service. The output is the script itself, run by that environment's Python.
{
  lib,
  runCommandLocal,
}:
vllm:
runCommandLocal "vllm-detector.py" { } ''
  cp ${./detector.py} detector.py
  HOME="$TMPDIR" ${lib.getExe' vllm "python"} -c 'import detector; detector.check()'
  cp detector.py "$out"
''
