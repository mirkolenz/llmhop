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
  util = import ../../modules/lib lib;
  fakes = import ./fakes.nix { inherit lib pkgs; };
  inherit (fakes)
    jailProbe
    fakeDownload
    fakeServer
    fakeImage
    ;

  # Root-only copies outside the Nix store, as credentials are deployed:
  # llmhop imports its own from the system credential store by name, the
  # worker loads its key from a path.
  secretFile = text: {
    inherit text;
    mode = "0400";
  };
in
testers.nixosTest {
  name = "llmhop";

  nodes.machine = {
    imports = [ self.nixosModules.default ];

    environment.etc = {
      "credstore/llmhop.api-key.client" = secretFile "client-secret";
      # A JSON credential, whose policy allows only another model.
      "credstore/llmhop.api-key.guest" = secretFile (
        lib.toJSON {
          key = "guest-secret";
          policy = "guest";
        }
      );
      "llmhop/worker-key" = secretFile "worker-secret";
    };

    systemd.tmpfiles.rules = [ "d /srv/writable 0700 root root" ];

    # Started by hand, so the test controls when they load.
    systemd.services = {
      jail-probe.serviceConfig =
        util.hubSandbox {
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
        enable = true;
        # A further socket, so llmhop serves every descriptor systemd hands
        # over by its name.
        listen.local = { };
        settings = {
          clients.local.listener = "local";
          policies.guest.models = [ "dying" ];
          clientCredentials = true;
        };
      };
    };
  };

  nodes.containers = {
    imports = [ self.nixosModules.default ];
    environment.etc."credstore/llmhop.api-key.client" = secretFile "client-secret";
    virtualisation.diskSize = 4096;
    # Every container, the gateway reading its imported credentials among
    # them, runs in a user namespace of its own, by default.
    services.llmhop = {
      runtime = "container";
      llama-cpp = {
        enable = true;
        container.image = "docker-archive:${fakeImage}";
        environment.FAKE_LOADED = "1";
        models.fake-model = {
          model = "example/fake:Q4_K_M";
          port = 18081;
        };
      };
      gateway = {
        enable = true;
        settings.clientCredentials = true;
      };
    };
  };

  testScript =
    { nodes, ... }:
    let
      worker = nodes.containers.virtualisation.quadlet.containers.llama-cpp-fake-model;
    in
    ''
      import json

      def curl(key=None, flags="-fsS"):
          auth = f"-H 'Authorization: Bearer {key}'" if key else ""
          return f"""curl {flags} {auth} --json '{{"model": "fake-model"}}' http://127.0.0.1:8080/"""

      def status(key):
          return machine.succeed(curl(key, "-sS -o /dev/null -w '%{http_code}'"))

      # Both read at once, since a restarting unit has no `MainPID` between
      # its processes.
      def wait_restarted(node, unit, pid):
          def restarted(_):
              properties = dict(
                  line.split("=", 1)
                  for line in node.succeed(f"systemctl show -p ActiveState -p MainPID {unit}").splitlines()
              )
              return properties["ActiveState"] == "active" and properties["MainPID"] not in (pid, "0")

          retry(restarted)

      # Type=notify, so the listener is bound once the unit is active.
      start_all()
      machine.wait_for_unit("llmhop.service")

          assert json.loads(machine.succeed("curl -fsS http://127.0.0.1:8080/health")) == {"status": "ok", "models": 2}
          machine.succeed("curl -fsS --unix-socket /run/llmhop/local.sock http://localhost/health")
      with subtest("both listeners serve health without a key"):

      with subtest("the imported client key is required"):
          machine.fail(curl())
          machine.fail(curl("nope"))

      with subtest("a JSON credential's policy allows only its models"):
          assert status("guest-secret") == "403"
          models = json.loads(machine.succeed("curl -fsS -H 'Authorization: Bearer guest-secret' http://127.0.0.1:8080/v1/models"))
          assert [model["id"] for model in models["data"]] == ["dying"]

      with subtest("restarting a listener reconnects the gateway to its sockets"):
          machine.succeed("systemctl restart llmhop-default.socket")
          # The restart of the service it is part of runs after the socket's returns.
          machine.wait_for_unit("llmhop.service")
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

      with subtest("the listener of a client needs no key"):
          assert machine.succeed("""curl -fsS --json '{"model": "fake-model"}' --unix-socket /run/llmhop/local.sock http://localhost/""") == "socket ok"

      with subtest("llmhopctl creates, rotates, updates and revokes keys by reloading llmhop"):
          pid = machine.get_unit_property("llmhop", "MainPID")
          added = machine.succeed("llmhopctl key create added").strip()
          assert machine.succeed(curl(added)) == "socket ok"
          rotated = machine.succeed("llmhopctl key rotate added").strip()
          machine.fail(curl(added))
          assert machine.succeed(curl(rotated)) == "socket ok"
          machine.succeed("llmhopctl key create --policy guest --expires 30d limited")
          # Rotating keeps the policy.
          assert status(machine.succeed("llmhopctl key rotate limited").strip()) == "403"
          listed = {
              name: json.loads(fields)
              for name, fields in (line.split("\t") for line in machine.succeed("llmhopctl key list").splitlines())
          }
          assert list(listed) == ["added", "client", "guest", "limited"], listed
          assert listed["added"] == {} and listed["guest"] == {"policy": "guest"}
          assert listed["limited"]["policy"] == "guest" and listed["limited"]["expiresAt"].startswith("20")
          # Updating keeps the key, and llmhopctl refuses an unknown policy.
          machine.succeed("llmhopctl key update --policy guest added")
          assert status(rotated) == "403"
          machine.fail("llmhopctl key update --policy missing added")
          machine.succeed("llmhopctl key update --policy= --no-expires limited")
          assert status(machine.succeed("llmhopctl key rotate limited").strip()) == "200"
          machine.succeed("llmhopctl key revoke added")
          machine.fail(curl(rotated))
          machine.fail("llmhopctl key rotate added")
          machine.fail("llmhopctl key create client")
          machine.fail("llmhopctl key create local")
          assert machine.get_unit_property("llmhop", "MainPID") == pid
          assert machine.succeed(curl("client-secret")) == "socket ok"

      containers.wait_for_unit("llmhop.service")
      containers.wait_for_unit("llama-cpp-fake-model.service")

      with subtest("containers: llmhopctl restarts llmhop to import a key"):
          key = containers.succeed("llmhopctl key create added").strip()
          assert containers.succeed(curl(key)) == "socket ok"

      with subtest("containers: the worker downloads into its volume in its own user namespace"):
          huser = containers.succeed("podman top ${worker.podmanName} huser").split()[1]
          assert int(huser) >= 2147483647, f"not in the range of the containers user: {huser}"
          volume = containers.succeed("podman volume inspect --format '{{.Mountpoint}}' llama-cpp-fake-model").strip()
          containers.succeed(f"test -f {volume}/hub/models--example--fake/snapshots/a1/model.gguf")

      worker = "llama-cpp-fake-model"
      cache = "/var/cache/llama-cpp/fake-model"
      snapshots = f"{cache}/hub/models--example--fake/snapshots"

      with subtest("only a successful resumed download prunes and restarts"):
          pid = machine.get_unit_property(worker, "MainPID")
          machine.succeed(f"echo b2 > {cache}/request; touch {cache}/fail-download")
          machine.fail(f"systemctl restart {worker}-fetch")
          assert machine.get_unit_property(worker, "MainPID") == pid
          machine.succeed(f"test -d {snapshots}/b2; test -f {snapshots}/a1/model.gguf")
          machine.fail(f"test -e {snapshots}/b2/model.gguf")

          machine.succeed(f"rm {cache}/fail-download; systemctl restart {worker}-fetch")
          wait_restarted(machine, worker, pid)
          machine.succeed(f"test -f {snapshots}/b2/model.gguf")
          machine.fail(f"test -e {snapshots}/a1")
          assert machine.succeed(curl("client-secret")) == "socket ok"

      # Starting the refresh waits for the one the fetch pulled in.
      with subtest("a successful fetch leaves an explicitly stopped worker stopped"):
          machine.succeed(f"systemctl stop {worker}")
          machine.succeed(f"systemctl start llama-cpp-update; systemctl start {worker}-refresh")
          assert machine.get_unit_property(worker, "ActiveState") == "inactive"

      with subtest("restarting llmhop-image restarts the running gateway"):
          pid = containers.get_unit_property("llmhop", "MainPID")
          containers.succeed("systemctl restart llmhop-image")
          wait_restarted(containers, "llmhop", pid)
          assert containers.succeed(curl("client-secret")) == "socket ok"

      with subtest("restarting its image leaves an explicitly stopped gateway stopped"):
          containers.succeed("systemctl stop llmhop")
          containers.succeed("systemctl restart llmhop-image")
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
