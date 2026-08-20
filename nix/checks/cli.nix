# Pure-eval regression test for the shared `settings` renderer: each backend's
# entry in `cliDialects` encodes how its parser reads negated booleans and
# multi-value flags, which is exactly what is easy to break unnoticed.
{
  lib,
  emptyFile,
}:
let
  inherit (import ../modules/lib.nix lib) renderCliArgs renderCliArgsShell;

  settings = {
    temperature = 0.6;
    max-model-len = 8192;
    enable-prefix-caching = false;
    lora-paths = [
      "x=/p/x"
      "y=/p/y"
    ];
    empty = [ ];
    dropped = null;
    speculative-config = {
      model = "d";
      num_speculative_tokens = 3;
    };
  };

  failures = lib.runTests {
    # Values-style parser: one flag for the whole list, `false` negated via
    # `--no-`, floats and attribute sets kept exact, `null` and `[ ]` dropped.
    testValuesDialect = {
      expr = renderCliArgs "vllm" settings;
      expected = [
        "--lora-paths"
        "x=/p/x"
        "y=/p/y"
        "--max-model-len"
        "8192"
        "--no-enable-prefix-caching"
        "--speculative-config"
        ''{"model":"d","num_speculative_tokens":3}''
        "--temperature"
        "0.6"
      ];
    };

    # Repeat-style parser: one flag per element, empty lists still dropped.
    testRepeatDialect = {
      expr = renderCliArgs "llama-cpp" {
        lora-paths = [
          "x=/p/x"
          "y=/p/y"
        ];
        empty = [ ];
      };
      expected = [
        "--lora-paths"
        "x=/p/x"
        "--lora-paths"
        "y=/p/y"
      ];
    };

    # SGLang pairs `--enable-X` with `--disable-X`, so `false` is dropped.
    testNoNegation = {
      expr = renderCliArgs "sglang" { enable-prefix-caching = false; };
      expected = [ ];
    };

    # Quadlet joins scalars onto the flag, but a list still needs one argv
    # entry per element.
    testQuadletSeparator = {
      expr = renderCliArgsShell "sglang-quadlet" {
        port = 30000;
        worker-urls = [
          "http://a"
          "http://b"
        ];
      };
      expected = "'--port=30000' --worker-urls http://a http://b";
    };
  };
in
builtins.seq (lib.debug.throwTestFailures {
  inherit failures;
  description = "CLI rendering tests";
}) emptyFile
