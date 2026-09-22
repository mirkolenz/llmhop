# Runs a `lib.runTests` suite at evaluation time and hands back something the
# `checks` output can build. The tests have already run by the time anything
# asks for that output, so it only has to exist.
{
  lib,
  emptyFile,
}:
{
  description,
  tests,
  output ? emptyFile,
}:
lib.seq (lib.debug.throwTestFailures {
  inherit description;
  failures = lib.runTests tests;
}) output
