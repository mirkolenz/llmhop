{ pkgs, testers, ... }:
let
  clientToken = pkgs.writeText "client-token" "client-secret";
  upstreamKey = pkgs.writeText "upstream-key" "upstream-secret";
in
testers.nixosTest {
  name = "llmhop";

  nodes.machine =
    { ... }:
    {
      imports = [ ./module.nix ];

      services.llmhop = {
        enable = true;
        settings = {
          listen = "127.0.0.1:8080";
          authTokens = [ "\${file:client_token}" ];
          models."test-model" = {
            url = "http://127.0.0.1:9000";
            headers.Authorization = "Bearer \${file:upstream_key}";
          };
        };
      };

      systemd.services.llmhop.serviceConfig.LoadCredential = [
        "client_token:${clientToken}"
        "upstream_key:${upstreamKey}"
      ];

      services.caddy = {
        enable = true;
        virtualHosts."http://127.0.0.1:9000".extraConfig = ''
          respond "auth={http.request.header.authorization}" 200
        '';
      };
    };

  testScript = ''
    import json
    import shlex

    def curl(body, token=None):
        payload = shlex.quote(json.dumps(body))
        auth = f"-H {shlex.quote(f'Authorization: Bearer {token}')}" if token else ""
        return f"curl -fsS {auth} --json {payload} http://127.0.0.1:8080/"

    machine.wait_for_unit("llmhop.service")
    machine.wait_for_unit("caddy.service")
    machine.wait_for_open_port(8080)
    machine.wait_for_open_port(9000)

    with subtest("missing auth is rejected"):
        machine.fail(curl({"model": "test-model"}))

    with subtest("wrong token is rejected"):
        machine.fail(curl({"model": "test-model"}, token="nope"))

    with subtest("correct token is accepted and upstream header is injected"):
        body = machine.succeed(curl({"model": "test-model"}, token="client-secret"))
        assert "auth=Bearer upstream-secret" in body, f"unexpected body: {body!r}"

    with subtest("unknown model is rejected after auth"):
        machine.fail(curl({"model": "unknown"}, token="client-secret"))
  '';
}
