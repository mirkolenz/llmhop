{
  pkgs,
  lib,
  testers,
  self,
  ...
}:
let
  # Root-only copies outside the Nix store, as credentials are deployed:
  # llmhop imports its own from the system credential store by name, the
  # worker loads its key from a path.
  secretFile = text: {
    inherit text;
    mode = "0400";
  };

  # Stands in for `llama download`: writes the commit in `upstream` to the
  # hub cache below the `HF_HOME` the module renders, as one snapshot of the repo.
  fakeDownload = pkgs.writeScriptBin "llama" ''
    #!${lib.getExe pkgs.python3Minimal}
    import os
    import pathlib
    import sys

    repo = sys.argv[sys.argv.index("-hf") + 1].split(":")[0]
    failure = pathlib.Path("/var/lib/fake-failure")

    if failure.exists() and failure.read_text().strip() == "offline":
        sys.exit(1)

    commit = pathlib.Path("${upstream}").read_text().strip()
    cache = pathlib.Path(os.environ["HF_HOME"], "hub", "models--" + repo.replace("/", "--"))
    snapshot = cache / "snapshots" / commit
    snapshot.mkdir(parents=True, exist_ok=True)
    (cache / "refs").mkdir(exist_ok=True)
    (cache / "refs" / "main").write_text(commit)

    if failure.exists():
        (snapshot / "config.json").write_text("{}")
        sys.exit(1)

    (snapshot / "model.gguf").write_text(commit)
  '';

  upstream = "/var/lib/fake-upstream";
  # The hub caches of `fake-model` and `shared`, which serve the same
  # repository from caches of their own.
  hubOf = name: "/var/cache/llama-cpp/${name}/hub";
  hub = hubOf "fake-model";
  repo = "${hub}/models--example--fake";
  sharedRepo = "${hubOf "shared"}/models--example--fake";

  # Stands in for `llama-server`: binds the unix socket the module renders as
  # `--host` and answers 503 while "loading", 200 afterwards, or exits at once
  # as the model `dying`. Driving it through the real backend puts the
  # readiness check and the socket permissions under the generated unit's full
  # sandbox (PrivateNetwork, PrivateUsers, SystemCallFilter and all), which is
  # where they actually break.
  fakeServer = pkgs.writeScriptBin "llama-server" ''
    #!${lib.getExe pkgs.python3Minimal}
    import http.server
    import os
    import pathlib
    import socketserver
    import sys

    if sys.argv[sys.argv.index("--alias") + 1] == "dying":
        sys.exit(1)

    socket = sys.argv[sys.argv.index("--host") + 1]
    # Reached through `%d`, so this fails unless systemd expanded it.
    open(sys.argv[sys.argv.index("--api-key-file") + 1]).read()
    repo = sys.argv[sys.argv.index("--hf-repo") + 1].split(":")[0]
    cache = pathlib.Path(os.environ["HF_HOME"], "hub", "models--" + repo.replace("/", "--"))
    commit = (cache / "refs" / "main").read_text().strip()
    assert (cache / "snapshots" / commit / "model.gguf").read_text() == commit


    class Handler(http.server.BaseHTTPRequestHandler):
        health_checks = 0

        def do_GET(self):
            if self.path == "/revision":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(commit.encode())
                return

            type(self).health_checks += 1
            # Long enough for the test to observe the loading state.
            self.send_response(200 if self.health_checks > 3 else 503)
            self.end_headers()

        def do_POST(self):
            # Closing with the body unread races the proxy still sending it.
            self.rfile.read(int(self.headers["Content-Length"]))
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

      environment.etc = {
        "credstore/llmhop.client-token" = secretFile "client-secret";
        "credstore/llmhop.upstream-key" = secretFile "upstream-secret";
        "llmhop/worker-key" = secretFile "worker-secret";
      };

      systemd.tmpfiles.settings.fake-upstream.${upstream}.f.argument = "a1";

      # Started by hand so the `activating` window is observable rather than
      # racing the rest of the test script.
      systemd.services = {
        llama-cpp-fake-model.wantedBy = lib.mkForce [ ];
        llama-cpp-shared = {
          wantedBy = lib.mkForce [ ];
          serviceConfig.Restart = lib.mkForce "no";
        };
        llama-cpp-dying = {
          wantedBy = lib.mkForce [ ];
          serviceConfig.Restart = lib.mkForce "no";
        };
      };

      services = {
        llmhop = {
          llama-cpp = {
            enable = true;
            package = pkgs.symlinkJoin {
              name = "fake-llama-cpp";
              paths = [
                fakeServer
                fakeDownload
              ];
            };
            models = {
              "fake-model" = {
                model = "example/fake:Q4_K_M";
                credentials.api-keys = "/etc/llmhop/worker-key";
                settings.api-key-file = "\${cred:api-keys}";
              };
              shared = {
                model = "example/fake:Q4_K_M";
                credentials.api-keys = "/etc/llmhop/worker-key";
                settings.api-key-file = "\${cred:api-keys}";
              };
              # A local file, so it has no fetcher.
              dying.model = "/var/empty/dying.gguf";
            };
          };

          gateway = {
            type = "builtin";
            builtin = {
              # Two sockets, so llmhop serves every descriptor systemd hands over.
              listen.local = { };
              credentials = {
                "llmhop.client-token" = null;
                "llmhop.upstream-key" = null;
              };
              settings = {
                authTokens = [ "\${cred:llmhop.client-token}" ];
                models."test-model" = {
                  url = "http://127.0.0.1:9000";
                  headers.Authorization = "Bearer \${cred:llmhop.upstream-key}";
                };
              };
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
        # `test-model` plus the llama.cpp models.
        body = machine.succeed("curl -fsS http://127.0.0.1:8080/health")
        assert json.loads(body) == {"status": "ok", "models": 4}, f"unexpected body: {body!r}"

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
        machine.wait_until_succeeds("systemctl show -P ActiveState llama-cpp-fake-model | grep -qx activating")

    with subtest("the fetcher downloads before the server starts"):
        assert machine.succeed("cat ${repo}/refs/main") == "a1"
        result = machine.get_unit_property("llama-cpp-fake-model-fetch", "Result")
        assert result == "success", f"unexpected result: {result}"

    with subtest("the unit goes active once the model answers 200"):
        # Only reachable if the health check passed the worker sandbox.
        machine.wait_for_unit("llama-cpp-fake-model.service")

    with subtest("llmhop reaches the worker through its socket"):
        body = machine.succeed(curl({"model": "fake-model"}, token="client-secret"))
        assert body == "socket ok", f"unexpected body: {body!r}"

    with subtest("readiness probes every worker, but not the remote model"):
        # `dying` never starts, so llmhop is not ready.
        body = machine.succeed("curl -sS http://127.0.0.1:8080/readiness")
        assert json.loads(body) == {"status": "unavailable", "ready": 1, "probed": 3}, f"unexpected body: {body!r}"

    workers = ["llama-cpp-fake-model", "llama-cpp-shared"]

    with subtest("an upstream change restarts every worker of the repository"):
        machine.succeed("systemctl start llama-cpp-shared")
        invocations = {worker: machine.get_unit_property(worker, "InvocationID") for worker in workers}
        machine.succeed("echo b2 > ${upstream}")
        machine.succeed("systemctl start llama-cpp-update")

        for worker, invocation in invocations.items():
            machine.wait_until_succeeds(f"[ $(systemctl show -P InvocationID {worker}) != {invocation} ]")
            machine.wait_for_unit(f"{worker}.service")
            assert machine.succeed(f"curl -fsS --unix-socket /run/llmhop/{worker}/http.sock http://localhost/revision") == "b2"

        machine.succeed("test -e ${sharedRepo}/snapshots/b2/model.gguf")
        body = machine.succeed(curl({"model": "fake-model"}, token="client-secret"))
        assert body == "socket ok", f"unexpected body: {body!r}"

    with subtest("unchanged downloads leave every worker running"):
        invocations = {worker: machine.get_unit_property(worker, "InvocationID") for worker in workers}
        machine.succeed("systemctl start llama-cpp-update")
        assert all(machine.get_unit_property(worker, "InvocationID") == invocation for worker, invocation in invocations.items())

    with subtest("an interrupted download leaves workers on the last complete one"):
        machine.succeed("echo broken > ${upstream}", "echo partial > /var/lib/fake-failure")
        # A failed fetcher leaves the others to run.
        machine.succeed("systemctl start llama-cpp-update")
        machine.succeed("systemctl is-failed llama-cpp-fake-model-fetch llama-cpp-shared-fetch")
        assert all(machine.get_unit_property(worker, "InvocationID") == invocation for worker, invocation in invocations.items())
        # The refs point back to the complete download, while the partial one
        # stays for the next fetch to resume.
        assert machine.succeed("cat ${sharedRepo}/refs/main") == "b2"
        machine.succeed("test -e ${sharedRepo}/snapshots/broken/config.json")
        machine.succeed("systemctl restart llama-cpp-shared")
        assert machine.succeed("curl -fsS --unix-socket /run/llmhop/llama-cpp-shared/http.sock http://localhost/revision") == "b2"

    with subtest("a worker never starts from an incomplete snapshot"):
        machine.succeed("rm ${sharedRepo}/snapshots/b2/model.gguf")
        machine.fail("systemctl restart llama-cpp-shared")
        machine.succeed("journalctl -u llama-cpp-shared | grep -q 'cache does not match a completed download'")
        machine.succeed("rm /var/lib/fake-failure", "echo b2 > ${upstream}")
        machine.succeed("systemctl reset-failed llama-cpp-fake-model-fetch llama-cpp-shared-fetch", "systemctl start llama-cpp-update")
        machine.wait_for_unit("llama-cpp-shared.service")
        machine.fail("test -e ${sharedRepo}/snapshots/broken")

    with subtest("an offline start can use a previously completed download"):
        machine.succeed("echo offline > /var/lib/fake-failure")
        machine.succeed("systemctl start llama-cpp-update")
        machine.succeed("systemctl restart llama-cpp-fake-model")
        machine.wait_for_unit("llama-cpp-fake-model.service")
        machine.succeed("rm /var/lib/fake-failure", "systemctl reset-failed llama-cpp-fake-model-fetch llama-cpp-shared-fetch")

    with subtest("pruning keeps only what the configuration references"):
        machine.succeed("runuser -u llama-cpp -- mkdir -p ${hub}/models--example--stale/snapshots/c3 ${repo}/snapshots/c3")
        # llama.cpp pins no revision and names the default branch after it,
        # so every ref it records stays.
        machine.succeed("runuser -u llama-cpp -- sh -c 'echo c3 > ${repo}/refs/trunk'")
        machine.succeed("runuser -u llama-cpp -- sh -c 'echo c3 > ${repo}/snapshots/c3/model.gguf'")
        machine.succeed("systemctl start llama-cpp-update")
        machine.succeed("test -e ${repo}/snapshots/b2/model.gguf")
        machine.fail("test -e ${repo}/snapshots/a1")
        machine.succeed("test -e ${repo}/refs/trunk")
        machine.succeed("test -e ${repo}/snapshots/c3")
        machine.fail("test -e ${hub}/models--example--stale")
        machine.succeed("test -e ${sharedRepo}/snapshots/b2/model.gguf")

    with subtest("the worker restarts over its stale socket"):
        machine.succeed("systemctl kill --signal=SIGKILL llama-cpp-fake-model.service")
        machine.succeed("systemctl restart llama-cpp-fake-model.service")

    with subtest("the worker stops cleanly"):
        machine.succeed("systemctl stop llama-cpp-fake-model.service")
        state = machine.get_unit_info("llama-cpp-fake-model.service")["ActiveState"]
        assert state == "inactive", f"unexpected state: {state}"

    with subtest("a model that dies while loading fails its unit at once"):
        # Without the health check watching the server, this would poll a dead
        # socket until TimeoutStartSec instead of failing.
        machine.fail("timeout 60 systemctl start llama-cpp-dying")
        machine.succeed("systemctl is-failed llama-cpp-dying")
        machine.succeed("journalctl -u llama-cpp-dying | grep -q 'exited before it answered'")
  '';
}
