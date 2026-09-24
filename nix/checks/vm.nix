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
  workerKey = pkgs.writeText "worker-key" "worker-secret";

  notify = lib.getExe' (pkgs.callPackage ../package.nix { }) "llmhop-notify";

  # Stands in for `llama-server`: binds the unix socket the module renders as
  # `--host` and answers 503 while "loading", 200 afterwards. Driving it
  # through the real backend puts the readiness handshake and the socket
  # permissions under the generated unit's full sandbox (DynamicUser,
  # PrivateUsers, SystemCallFilter and all), which is where they actually break.
  fakeServer = pkgs.writeScriptBin "llama-server" ''
    #!${lib.getExe pkgs.python3Minimal}
    import http.server
    import socketserver
    import sys

    socket = sys.argv[sys.argv.index("--host") + 1]


    class Handler(http.server.BaseHTTPRequestHandler):
        health_checks = 0

        def do_GET(self):
            type(self).health_checks += 1
            self.send_response(200 if self.health_checks > 1 else 503)
            self.end_headers()

        def do_POST(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"socket ok")

        def log_message(self, *args):
            pass


    socketserver.UnixStreamServer(socket, Handler).serve_forever()
  '';
in
testers.nixosTest {
  name = "llmhop";

  nodes.machine =
    { ... }:
    {
      imports = [ self.nixosModules.default ];

      # Started by hand so the `activating` window is observable rather than
      # racing the rest of the test script.
      systemd.services.llama-cpp-fake-model.wantedBy = lib.mkForce [ ];

      # Exit-status propagation is a property of the supervisor itself, so it
      # gets a synthetic unit rather than a second fake backend.
      systemd.services.dying-model = {
        serviceConfig = {
          Type = "notify";
          TimeoutStartSec = 60;
          ExecStart = "${notify} -url http://127.0.0.1:9101 -- ${lib.getExe' pkgs.coreutils "false"}";
        };
      };

      services = {
        llmhop = {
          llama-cpp = {
            enable = true;
            package = fakeServer;
            models."fake-model" = {
              credentials.apiKeys = workerKey;
              settings.api-key-file = "\${cred:apiKeys}";
            };
          };

          enable = true;
          # Two sockets, so llmhop serves every descriptor systemd hands over.
          host = "127.0.0.1";
          listen.local = { };
          credentials = {
            client_token = clientToken;
            upstream_key = upstreamKey;
          };
          settings = {
            authTokens = [ "\${cred:client_token}" ];
            models."test-model" = {
              url = "http://127.0.0.1:9000";
              headers.Authorization = "Bearer \${cred:upstream_key}";
            };
          };
        };

        caddy = {
          enable = true;
          virtualHosts."http://127.0.0.1:9000".extraConfig = ''
            respond "auth={http.request.header.authorization}" 200
          '';
        };
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

    with subtest("the unix socket listener serves too"):
        machine.succeed("curl -fsS --unix-socket /run/llmhop/local.sock http://localhost/health >/dev/null")

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

    # Credential wiring is an evaluation-time property, asserted in `eval`.
    with subtest("a loading model holds its unit in activating"):
        machine.succeed("systemctl start --no-block llama-cpp-fake-model")
        state = machine.get_unit_info("llama-cpp-fake-model")["ActiveState"]
        assert state == "activating", f"unexpected state: {state}"

    with subtest("the unit goes active once the model answers 200"):
        # Only reachable if READY=1 crossed the worker sandbox.
        machine.wait_for_unit("llama-cpp-fake-model.service")

    with subtest("llmhop reaches the worker through its socket"):
        body = machine.succeed(curl({"model": "fake-model"}, token="client-secret"))
        assert body == "socket ok", f"unexpected body: {body!r}"

    with subtest("the worker restarts over its stale socket"):
        machine.succeed("systemctl kill --signal=SIGKILL llama-cpp-fake-model.service")
        machine.succeed("systemctl restart llama-cpp-fake-model.service")

    with subtest("the worker stops cleanly"):
        machine.succeed("systemctl stop llama-cpp-fake-model.service")
        state = machine.get_unit_info("llama-cpp-fake-model.service")["ActiveState"]
        assert state == "inactive", f"unexpected state: {state}"

    with subtest("a model that dies while loading fails its unit at once"):
        # Without the supervisor propagating the exit, this would poll a dead
        # port until TimeoutStartSec instead of failing.
        machine.fail("systemctl start dying-model")
        machine.succeed("systemctl is-failed dying-model")
  '';
}
