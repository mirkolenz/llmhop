# End-to-end test of the module wiring that only a booted system shows: socket
# activation, credentials, the worker sandbox, readiness and fetching. The
# router and the hub cache pruning have faster tests of their own.
{
  pkgs,
  lib,
  testers,
  self,
  ...
}:
let
  shared = import ../modules/backends/shared.nix lib;

  # Exits 0 only if it can write `/srv/writable`, but neither `/etc` nor the
  # private socket of systemd, through which root could escape.
  jailProbe = pkgs.writeScript "jail-probe" ''
    #!${lib.getExe pkgs.python3Minimal}
    import pathlib
    import socket

    pathlib.Path("/srv/writable/probe").write_text("ok")

    try:
        pathlib.Path("/etc/probe").write_text("escaped")
        raise SystemExit("wrote /etc")
    except OSError:
        pass

    try:
        socket.socket(socket.AF_UNIX).connect("/run/systemd/private")
        raise SystemExit("reached systemd")
    except OSError:
        pass
  '';

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
    request = pathlib.Path(os.environ["HF_HOME"], "request")
    commit = request.read_text().strip() if request.exists() else "a1"
    (cache / "snapshots" / commit).mkdir(parents=True, exist_ok=True)
    (cache / "refs").mkdir(exist_ok=True)
    # Rewritten on every fetch, as by llama.cpp.
    (cache / "refs" / "main").write_text(commit)

    if pathlib.Path(os.environ["HF_HOME"], "fail-download").exists():
        sys.exit(1)

    (cache / "snapshots" / commit / "model.gguf").write_text(commit)
  '';

  # Stands in for `llama-server`: binds the unix socket the module renders as
  # `--host` and answers 503 until the test marks it loaded, or exits at once
  # as the model `dying`. Driving it through the real unit puts the readiness
  # check, the credential and the socket permissions under the full sandbox.
  fakeServer = pkgs.writeScriptBin "llama-server" ''
    #!${lib.getExe pkgs.python3Minimal}
    from contextlib import suppress
    import http.server
    import os
    import pathlib
    import socketserver
    import sys

    if sys.argv[sys.argv.index("--alias") + 1] == "dying":
        sys.exit(1)

    host = sys.argv[sys.argv.index("--host") + 1]
    # Reached through `%d`, so this fails unless systemd expanded it.
    if "--api-key-file" in sys.argv:
        open(sys.argv[sys.argv.index("--api-key-file") + 1]).read()

    # Served offline from what the fetcher downloaded.
    hub = pathlib.Path(os.environ["HF_HOME"], "hub", "models--example--fake")
    commit = (hub / "refs" / "main").read_text().strip()
    assert (hub / "snapshots" / commit / "model.gguf").read_text() == commit


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            loaded = os.environ.get("FAKE_LOADED") == "1" or pathlib.Path("/var/lib/fake-loaded").exists()
            self.send_response(200 if loaded else 503)
            self.end_headers()

        def do_POST(self):
            # Closing with the body unread races the proxy still sending it.
            self.rfile.read(int(self.headers["Content-Length"]))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"socket ok")

        def log_message(self, *args):
            pass


    if host.endswith(".sock"):
        server = socketserver.UnixStreamServer(host, Handler)
    else:
        server = http.server.HTTPServer((host, int(sys.argv[sys.argv.index("--port") + 1])), Handler)

    with server, suppress(KeyboardInterrupt):
        server.serve_forever()
  '';

  fakeImage = pkgs.dockerTools.buildLayeredImage {
    name = "fake-llama";
    tag = "test";
    maxLayers = 2;
    contents = [
      pkgs.bash
      pkgs.curl
      (pkgs.runCommand "fake-llama-app" { } ''
        mkdir -p $out/app
        ln -s ${lib.getExe fakeDownload} $out/app/llama
        ln -s ${lib.getExe fakeServer} $out/app/llama-server
      '')
    ];
    config = {
      Env = [ "PATH=/bin" ];
      StopSignal = "SIGINT";
    };
  };
in
testers.nixosTest {
  name = "llmhop";

  nodes.machine = {
    imports = [ self.nixosModules.default ];

    environment.etc = {
      "credstore/llmhop.client-token" = secretFile "client-secret";
      "llmhop/worker-key" = secretFile "worker-secret";
    };

    systemd.tmpfiles.rules = [ "d /srv/writable 0700 root root" ];

    # Started by hand, so the test controls when they load.
    systemd.services = {
      jail-probe.serviceConfig =
        shared.hubSandbox {
          user = "root";
          group = "root";
        } "/srv/writable"
        // {
          Type = "oneshot";
          ExecStart = jailProbe;
        };
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

  nodes.containers = {
    imports = [ self.nixosModules.quadlet ];
    virtualisation = {
      diskSize = 4096;
      quadlet = {
        enable = true;
        images.llama-cpp.imageConfig.ImageTag = "localhost/fake-llama:test";
      };
    };
    services.llmhop = {
      llama-cpp-quadlet = {
        enable = true;
        image = "docker-archive:${fakeImage}";
        containerConfig.AutoUpdate = "disabled";
        environment.FAKE_LOADED = "1";
        models.fake-model = {
          model = "example/fake:Q4_K_M";
          port = 18081;
        };
      };
      gateway.type = "llmhop-quadlet";
    };
  };

  testScript = ''
    import json

    def curl(token=None):
        auth = f"-H 'Authorization: Bearer {token}'" if token else ""
        return f"""curl -fsS {auth} --json '{{"model": "fake-model"}}' http://127.0.0.1:8080/"""

    def wait_restarted(node, unit, pid):
        node.wait_until_succeeds(f"systemctl is-active --quiet {unit} && test $(systemctl show -P MainPID {unit}) != {pid}")

    # Type=notify, so the listener is bound once the unit is active.
    start_all()
    machine.wait_for_unit("llmhop.service")

    with subtest("both listeners serve health without a token"):
        assert json.loads(machine.succeed("curl -fsS http://127.0.0.1:8080/health")) == {"status": "ok", "models": 2}
        machine.succeed("curl -fsS --unix-socket /run/llmhop/local.sock http://localhost/health")

    with subtest("the imported client token is required"):
        machine.fail(curl())
        machine.fail(curl("nope"))

    with subtest("restarting a listener reconnects the gateway to its sockets"):
        machine.succeed("systemctl restart llmhop-default.socket")
        machine.succeed("curl --max-time 5 -fsS http://127.0.0.1:8080/health")
        machine.succeed("curl --max-time 5 -fsS --unix-socket /run/llmhop/local.sock http://localhost/health")

    with subtest("a loading model holds its unit in activating after its fetch"):
        machine.succeed("systemctl start --no-block llama-cpp-fake-model")
        machine.wait_until_succeeds("systemctl show -P ActiveState llama-cpp-fake-model | grep -qx activating")
        assert machine.get_unit_property("llama-cpp-fake-model-fetch", "Result") == "success"

    with subtest("a successful fetch refreshes before the model starts"):
        # Ordered before the model, which it found waiting rather than running.
        assert machine.get_unit_property("llama-cpp-fake-model-refresh", "Result") == "success"

    with subtest("the unit goes active once the model answers 200"):
        machine.succeed("touch /var/lib/fake-loaded")
        machine.wait_for_unit("llama-cpp-fake-model.service")

    with subtest("llmhop reaches the worker through its socket"):
        assert machine.succeed(curl("client-secret")) == "socket ok"

    containers.wait_for_unit("llmhop.service")
    containers.wait_for_unit("llama-cpp-fake-model.service")

    for node, request, backend in [
        (machine, curl("client-secret"), "llama-cpp"),
        (containers, curl(), "llama-cpp-quadlet"),
    ]:
        worker = "llama-cpp-fake-model"
        cache = "/var/cache/llama-cpp/fake-model"
        snapshots = f"{cache}/hub/models--example--fake/snapshots"

        with subtest(f"{node.name}: only a successful resumed download prunes and restarts"):
            pid = node.get_unit_property(worker, "MainPID")
            node.succeed(f"echo b2 > {cache}/request; touch {cache}/fail-download")
            node.fail(f"systemctl restart {worker}-fetch")
            assert node.get_unit_property(worker, "MainPID") == pid
            node.succeed(f"test -d {snapshots}/b2; test -f {snapshots}/a1/model.gguf")
            node.fail(f"test -e {snapshots}/b2/model.gguf")

            node.succeed(f"rm {cache}/fail-download; systemctl restart {worker}-fetch")
            wait_restarted(node, worker, pid)
            node.succeed(f"test -f {snapshots}/b2/model.gguf")
            node.fail(f"test -e {snapshots}/a1")
            assert node.succeed(request) == "socket ok"

        # Starting the refresh waits for the one the fetch pulled in.
        with subtest(f"{node.name}: a successful fetch leaves an explicitly stopped worker stopped"):
            node.succeed(f"systemctl stop {worker}")
            node.succeed(f"systemctl start {backend}-update; systemctl start {worker}-refresh")
            assert node.get_unit_property(worker, "ActiveState") == "inactive"

    containers.succeed("systemctl start llama-cpp-fake-model")

    for unit, image in [("llama-cpp-fake-model", "llama-cpp-image"), ("llmhop", "llmhop-image")]:
        with subtest(f"restarting {image} restarts the running {unit}"):
            pid = containers.get_unit_property(unit, "MainPID")
            containers.succeed(f"systemctl restart {image}")
            wait_restarted(containers, unit, pid)
            assert containers.succeed(curl()) == "socket ok"

    with subtest("restarting images leaves explicitly stopped workers and gateways stopped"):
        containers.succeed("systemctl stop llama-cpp-fake-model llmhop")
        containers.succeed("systemctl restart llama-cpp-image llmhop-image")
        containers.succeed("systemctl start llama-cpp-fake-model-refresh")
        assert containers.get_unit_property("llama-cpp-fake-model", "ActiveState") == "inactive"
        assert containers.get_unit_property("llmhop", "ActiveState") == "inactive"

    with subtest("readiness probes every worker"):
        machine.fail("curl -fsS http://127.0.0.1:8080/readiness")

    with subtest("the hub sandbox lets even root write only the hub and reach no socket"):
        machine.succeed("systemctl start jail-probe")
        machine.succeed("test -f /srv/writable/probe")
        machine.fail("test -e /etc/probe")

    with subtest("a model that dies while loading fails its unit at once"):
        machine.fail("timeout 60 systemctl start llama-cpp-dying")
        machine.succeed("journalctl -u llama-cpp-dying | grep -q 'exited before it answered'")
  '';
}
