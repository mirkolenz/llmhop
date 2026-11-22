# The submodule of a watermark detector of a backend and its profiles.
lib:
let
  inherit (lib) mkOption types;
  inherit (import ./options.nix lib) workloadOptions watermarkType watermarkScriptFor;
in
rec {
  # A generation configuration a detector of `engine` tests.
  profileModule = engine: {
    options = {
      tokenizer = mkOption {
        type = types.str;
        example = "Qwen/Qwen3-8B";
        description = ''
          Tokenizer used to encode candidate text, a Hugging Face repository or
          an absolute path. It must exactly match the tokenizer used for
          watermarked generation. The fetcher downloads only the files of a
          repository that a tokenizer may need, not its weights.
        '';
      };
      revision = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "main";
        description = ''
          Branch, tag or commit of `tokenizer`, which must match the
          `revision` of the generating model. `null` follows the default
          branch.
        '';
      };
      watermark = mkOption {
        type = watermarkType engine;
        default = { };
        description = "The `watermark` of the generating model.";
      };
    };
  };

  # Submodule of a detector of the backend `cfg` of `engine`, serving
  # `POST /detect` with the watermark script, which binds a unix socket too.
  detectorModule =
    {
      engine,
      llmhop,
      cfg,
      pkgs,
    }:
    {
      name,
      config,
      ...
    }:
    {
      options =
        workloadOptions {
          inherit
            engine
            llmhop
            cfg
            name
            config
            ;
          noun = "watermark detector";
          socketCapable = true;
        }
        // {
          profiles = mkOption {
            type = types.attrsOf (types.submodule (profileModule engine));
            example = lib.literalExpression ''
              {
                qwen = {
                  tokenizer = "Qwen/Qwen3-8B";
                  inherit (config.services.llmhop.${engine.name}.models.qwen) revision watermark;
                };
              }
            '';
            description = ''
              Generation configurations to test, keyed by the name a response
              reports as `profile`. Profiles sharing a tokenizer and revision
              share its encoding of the text, and the reported p-value is that
              of the most significant profile multiplied by their number.
            '';
          };
          settings = mkOption {
            type = with types; attrsOf json;
            default = { };
            example.p-value-threshold = 0.01;
            description = ''
              CLI flags of the detector script, of which `p-value-threshold`
              is the only one not derived from the other options.
            '';
          };
          script = mkOption {
            type = types.path;
            default = watermarkScriptFor pkgs llmhop engine config.package;
            defaultText = lib.literalMD "the watermark script, checked against `package` natively";
            description = ''
              Detector server run by the Python of the detector's environment or
              image. It receives `detect`, the `engine` and `settings`, the
              `profiles` among them as JSON, and must serve `GET /health` and
              `POST /detect`.
            '';
          };
        };
    };
}
