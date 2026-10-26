# Bifrost in front of every listed endpoint, as a native service under
# `services.llmhop.gateway.bifrost` and as a Quadlet container under
# `services.llmhop.gateway.bifrost-quadlet`.
lib:
{
  common,
  gateway,
  quadlet,
}:
let
  inherit (lib) mkOption types;
  inherit (common) credentialReferencePrefix mapStrings replaceCredentialRefs;

  unit = "bifrost";

  # Bifrost has no llama.cpp provider, but its vLLM one serves any
  # OpenAI-compatible server and, like SGLang's, takes a URL per key, so each
  # endpoint becomes one key of its engine's provider.
  provider = engine: if engine == "sglang" then "sgl" else "vllm";
  key =
    e:
    {
      inherit (e) name;
      value = "";
      models = [ e.name ];
      weight = 1;
    }
    // (
      if provider e.engine == "sgl" then
        { sgl_key_config.url = e.url; }
      else
        {
          vllm_key_config = {
            inherit (e) url;
            model_name = e.name;
          };
        }
    );

  # Bifrost reads secrets from the environment only, so each credential is
  # exported as a variable, which its `env.` reference names.
  variable = name: "CREDENTIAL_${lib.toUpper (lib.replaceStrings [ "." "-" ] [ "_" "_" ] name)}";

  # Shell commands exporting every credential below `directory`, a shell
  # expression.
  exports =
    directory: credentials:
    lib.concatMapStrings (name: ''
      ${variable name}=$(cat ${directory}/${name})
      export ${variable name}
    '') (lib.attrNames credentials);

  # `config.json` from `settings`, each `${cred:<name>}`, which must be a
  # whole value, as the `env.` reference of its variable.
  configFile =
    pkgs: cfg:
    (pkgs.formats.json { }).generate "bifrost-config.json" (
      mapStrings (
        value:
        if lib.hasInfix credentialReferencePrefix value && lib.match "\\$\\{cred:[^}]*}" value == null then
          throw "credential reference in `${value}` must be the whole value"
        else
          replaceCredentialRefs (name: "env.${variable name}") cfg.credentials value
      ) cfg.settings
    );

  # The module of the gateway `name`, whose `options` extend the shared ones
  # and whose `config` runs Bifrost with its `configFile`.
  mkModule =
    {
      name,
      options,
      config,
    }:
    gateway.mkModule {
      inherit name unit options;
      displayName = "Bifrost";
      secrets = ''
        In `settings`, a reference must be a whole value and becomes the `env.`
        reference of a variable Bifrost reads it from.
      '';
      settings =
        pkgs:
        mkOption {
          inherit (pkgs.formats.json { }) type;
          default = { };
          example = {
            encryption_key = "\${cred:bifrost.encryption-key}";
            governance.virtual_keys = [
              {
                id = "default";
                name = "default";
                value = "\${cred:bifrost.virtual-key}";
                is_active = true;
              }
            ];
          };
          description = ''
            Bifrost's `config.json`, with every listed model as a key of its
            `vllm` or `sgl` provider. Changes from its web UI or API persist
            until the matching section of this file changes, while
            `source_of_truth = "config.json"` prunes them and
            `config_store.enabled = false` disables them.
          '';
        };
      defaults =
        { endpoints, ... }:
        {
          "$schema" = lib.mkDefault "https://www.getbifrost.ai/schema";
          providers = lib.mapAttrs (_: endpoints: { keys = map key endpoints; }) (
            lib.groupBy (e: provider e.engine) endpoints
          );
        };
      config = context@{ pkgs, cfg, ... }: config (context // { configFile = configFile pkgs cfg; });
    };
in
{
  native = mkModule {
    name = "bifrost";
    options.package = mkOption {
      type = types.package;
      description = ''
        Package providing `bifrost-http` as its main program, taken from
        Bifrost's own flake, since nixpkgs lacks it.
      '';
    };
    config =
      context@{ cfg, configFile, ... }:
      gateway.nativeService (
        context
        // {
          description = "Bifrost model gateway";
          script = ''
            install -m 600 ${configFile} "$STATE_DIRECTORY/config.json"
            ${exports ''"$CREDENTIALS_DIRECTORY"'' cfg.credentials}
            exec ${
              lib.escapeShellArgs [
                (lib.getExe cfg.package)
                "-host"
                cfg.host
                "-port"
                cfg.port
              ]
            } -app-dir "$STATE_DIRECTORY"
          '';
          serviceConfig = {
            StateDirectory = unit;
            StateDirectoryMode = "0700";
          };
        }
      );
  };

  quadlet = mkModule {
    name = "bifrost-quadlet";
    options.image = quadlet.imageOption // {
      example = "docker.io/maximhq/bifrost:v2.3.2";
    };
    config =
      context@{ cfg, configFile, ... }:
      gateway.quadletContainer (
        context
        // {
          script = ''
            ${exports quadlet.credentialDirectory cfg.credentials}
            exec /app/docker-entrypoint.sh /app/main
          '';
          # `U` hands the app directory to whatever user the container runs as.
          volumes = [
            "/var/lib/${unit}:/app/data:U"
            "${configFile}:/app/data/config.json:ro"
          ];
          environment = {
            APP_DIR = "/app/data";
            APP_HOST = cfg.host;
            APP_PORT = toString cfg.port;
          };
          serviceConfig.StateDirectory = unit;
        }
      );
  };
}
