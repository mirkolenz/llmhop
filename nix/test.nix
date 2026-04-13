{ testers }:
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
          models = {
            "test-model".url = "http://127.0.0.1:9000";
          };
        };
      };

      services.caddy = {
        enable = true;
        virtualHosts."http://127.0.0.1:9000".extraConfig = ''
          respond "backend ok" 200
        '';
      };
    };

  testScript = ''
    import json
    import shlex

    def curl(body):
        payload = shlex.quote(json.dumps(body))
        return f"curl -fsS --json {payload} http://127.0.0.1:8080/"

    machine.wait_for_unit("llmhop.service")
    machine.wait_for_unit("caddy.service")
    machine.wait_for_open_port(8080)
    machine.wait_for_open_port(9000)

    with subtest("missing model field is rejected"):
        machine.fail(curl({}))

    with subtest("known model is proxied to backend"):
        body = machine.succeed(curl({"model": "test-model"}))
        assert "backend ok" in body, f"unexpected body: {body!r}"

    with subtest("unknown model is rejected"):
        machine.fail(curl({"model": "unknown"}))
  '';
}
