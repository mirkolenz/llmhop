# Pure-eval regression test for the shared `settings` renderer: each backend's
# entry in `engines` encodes how its parser reads negated booleans and
# multi-value flags, which is exactly what is easy to break unnoticed.
{
  lib,
  mkEvalCheck,
}:
let
  inherit (import ../modules/lib lib) engines renderCliArgs;

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

in
mkEvalCheck {
  description = "CLI rendering tests";
  tests = {
    # Values-style parser: one flag for the whole list, `false` negated via
    # `--no-`, floats and attribute sets kept exact, `null` and `[ ]` dropped.
    testValuesDialect = {
      expr = renderCliArgs engines.vllm settings;
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
      expr = renderCliArgs engines.llama-cpp {
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
      expr = renderCliArgs engines.sglang { enable-prefix-caching = false; };
      expected = [ ];
    };
  };
}
