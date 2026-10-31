# End-to-end test of the module wiring that only a booted system shows: socket
# activation, credentials, the worker sandbox, readiness and fetching. The
# router and the hub-cache tool have faster tests of their own.
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

  # Stands in for `llama download`: writes one snapshot of the repo to the
  # hub cache below the `HF_HOME` the module renders.
  fakeDownload = pkgs.writeScriptBin "llama" ''
    #!${lib.getExe pkgs.python3Minimal}
    import os
    import pathlib
    import sys

    repo = sys.argv[sys.argv.index("-hf") + 1].split(":")[0]
    cache = pathlib.Path(os.environ["HF_HOME"], "hub", "models--" + repo.replace("/", "--"))
    (cache / "snapshots" / "a1").mkdir(parents=True)
    (cache / "snapshots" / "a1" / "model.gguf").write_text("a1")
    (cache / "refs").mkdir()
    (cache / "refs" / "main").write_text("a1")
  '';

  # Stands in for `llama-server`: binds the unix socket the module renders as
  # `--host` and answers 503 until the test marks it loaded, or exits at once
  # as the model `dying`. Driving it through the real unit puts the readiness
  # check, the credential and the socket permissions under the full sandbox.
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
    # Served offline from what the fetcher downloaded.
    hub = pathlib.Path(os.environ["HF_HOME"], "hub", "models--example--fake")
    assert (hub / "snapshots" / "a1" / "model.gguf").read_text() == "a1"


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200 if pathlib.Path("/var/lib/fake-loaded").exists() else 503)
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

  nodes.machine = {
    imports = [ self.nixosModules.default ];

    environment.etc = {
      "credstore/llmhop.client-token" = secretFile "client-secret";
      "llmhop/worker-key" = secretFile "worker-secret";
    };

    # Started by hand, so the test controls when they load.
    systemd.services = {
      llama-cpp-fake-model.wantedBy = lib.mkForce [ ];
      llama-cpp-dying = {
        wantedBy = lib.mkForce [ ];
        serviceConfig.Restart = lib.mkForce "no";
      };
    };

    services.llmhop = {
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
          # A local file, so it has no fetcher.
          dying.model = "/var/empty/dying.gguf";
        };
      };

      gateway = {
        type = "llmhop";
        llmhop = {
          # Two sockets, so llmhop serves every descriptor systemd hands over.
          listen.local = { };
          credentials."llmhop.client-token" = null;
          settings.authTokens = [ "\${cred:llmhop.client-token}" ];
        };
      };
    };
  };

  testScript = ''
    import json

    def curl(token=None):
        auth = f"-H 'Authorization: Bearer {token}'" if token else ""
        return f"""curl -fsS {auth} --json '{{"model": "fake-model"}}' http://127.0.0.1:8080/"""

    # Type=notify, so the listener is bound once the unit is active.
    machine.wait_for_unit("llmhop.service")

    with subtest("both listeners serve health without a token"):
        assert json.loads(machine.succeed("curl -fsS http://127.0.0.1:8080/health")) == {"status": "ok", "models": 2}
        machine.succeed("curl -fsS --unix-socket /run/llmhop/local.sock http://localhost/health")

    with subtest("the imported client token is required"):
        machine.fail(curl())
        machine.fail(curl("nope"))

    with subtest("a loading model holds its unit in activating after its fetch"):
        machine.succeed("systemctl start --no-block llama-cpp-fake-model")
        machine.wait_until_succeeds("systemctl show -P ActiveState llama-cpp-fake-model | grep -qx activating")
        assert machine.get_unit_property("llama-cpp-fake-model-fetch", "Result") == "success"

    with subtest("the unit goes active once the model answers 200"):
        machine.succeed("touch /var/lib/fake-loaded")
        machine.wait_for_unit("llama-cpp-fake-model.service")

    with subtest("llmhop reaches the worker through its socket"):
        assert machine.succeed(curl("client-secret")) == "socket ok"

    with subtest("readiness probes every worker"):
        machine.fail("curl -fsS http://127.0.0.1:8080/readiness")

    with subtest("a model that dies while loading fails its unit at once"):
        machine.fail("timeout 60 systemctl start llama-cpp-dying")
        machine.succeed("journalctl -u llama-cpp-dying | grep -q 'exited before it answered'")
  '';
}
