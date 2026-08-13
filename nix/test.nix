{
  pkgs,
  lib,
  testers,
  self,
  ...
}:
let
  clientToken = pkgs.writeText "client-token" "client-secret";
  upstreamKey = pkgs.writeText "upstream-key" "upstream-secret";

  notify = lib.getExe' (pkgs.callPackage ./package.nix { }) "llmhop-notify";

  # Stands in for `llama-server`: binds the `--port` the module renders and
  # answers 503 while "loading", 200 afterwards. Driving it through the real
  # backend puts the readiness handshake under the generated unit's full
  # sandbox — DynamicUser, PrivateUsers, SystemCallFilter and all — which is
  # where a `Type = notify` wrapper actually breaks.
  fakeServer = pkgs.writeScriptBin "llama-server" ''
    #!${lib.getExe pkgs.python3Minimal}
    import http.server
    import sys
    import time

    port = int(sys.argv[sys.argv.index("--port") + 1])
    ready_at = time.monotonic() + 5


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            loaded = time.monotonic() >= ready_at
            self.send_response(200 if loaded else 503)
            self.end_headers()

        def log_message(self, *args):
            pass


    http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
  '';
in
testers.nixosTest {
  name = "llmhop";

  nodes.machine =
    { ... }:
    {
      imports = [ self.nixosModules.default ];

      services.llmhop.llama-cpp = {
        enable = true;
        package = fakeServer;
        models."fake-model".port = 9100;
      };

      # Started by hand so the `activating` window is observable rather than
      # racing the rest of the test script.
      systemd.services.llama-cpp-fake-model.wantedBy = lib.mkForce [ ];

      # Exit-status propagation is a property of the supervisor itself, so it
      # gets a synthetic unit rather than a second fake backend.
      systemd.services.dying-model = {
        serviceConfig = {
          Type = "notify";
          TimeoutStartSec = 60;
          ExecStart = "${notify} -port 9101 -- ${lib.getExe' pkgs.coreutils "false"}";
        };
      };

      services.llmhop = {
        enable = true;
        host = "127.0.0.1";
        port = 8080;
        credentials = {
          client_token = clientToken;
          upstream_key = upstreamKey;
        };
        settings = {
          authTokens = [ "\${file:client_token}" ];
          models."test-model" = {
            url = "http://127.0.0.1:9000";
            headers.Authorization = "Bearer \${file:upstream_key}";
          };
        };
      };

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
    machine.wait_for_open_port(9000)

    with subtest("the unit is only active once the listener is bound"):
        # Type=notify + sd_notify: no wait_for_open_port needed for llmhop.
        machine.succeed("curl -fsS http://127.0.0.1:8080/health >/dev/null")

    with subtest("health is served without a token"):
        # `test-model` plus the llama-cpp backend's own registration.
        body = machine.succeed("curl -fsS http://127.0.0.1:8080/health")
        assert json.loads(body) == {"status": "ok", "models": 2}, f"unexpected body: {body!r}"

    with subtest("missing auth is rejected"):
        machine.fail(curl({"model": "test-model"}))

    with subtest("wrong token is rejected"):
        machine.fail(curl({"model": "test-model"}, token="nope"))

    with subtest("correct token is accepted and upstream header is injected"):
        body = machine.succeed(curl({"model": "test-model"}, token="client-secret"))
        assert "auth=Bearer upstream-secret" in body, f"unexpected body: {body!r}"

    with subtest("unknown model is rejected after auth"):
        machine.fail(curl({"model": "unknown"}, token="client-secret"))

    with subtest("a loading model holds its unit in activating"):
        machine.succeed("systemctl start --no-block llama-cpp-fake-model")
        state = machine.get_unit_info("llama-cpp-fake-model")["ActiveState"]
        assert state == "activating", f"unexpected state: {state}"

    with subtest("the unit goes active once the model answers 200"):
        # Only reachable if READY=1 crossed the worker sandbox.
        machine.wait_for_unit("llama-cpp-fake-model.service")

    with subtest("a model that dies while loading fails its unit at once"):
        # Without the supervisor propagating the exit, this would poll a dead
        # port until TimeoutStartSec instead of failing.
        machine.fail("systemctl start dying-model")
        machine.succeed("systemctl is-failed dying-model")
  '';
}
