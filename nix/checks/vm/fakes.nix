# Stand-ins for llama.cpp and the probes of the VM test.
{ lib, pkgs }:
rec {
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
    import subprocess
    import sys

    if sys.argv[sys.argv.index("--alias") + 1] == "dying":
        sys.exit(1)

    host = sys.argv[sys.argv.index("--host") + 1]
    repo = sys.argv[sys.argv.index("--hf-repo") + 1]
    # Reached through `%d`, so this fails unless systemd expanded it.
    if "--api-key-file" in sys.argv:
        open(sys.argv[sys.argv.index("--api-key-file") + 1]).read()

    # Served offline from what the fetcher downloaded, or else downloaded by
    # the server itself, as in a container.
    if os.environ.get("LLAMA_ARG_OFFLINE") != "1":
        llama = pathlib.Path(sys.argv[0]).parent / "llama"
        subprocess.run([str(llama), "download", "-hf", repo], check=True)

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
}
