// Command llmhop-notify supervises a model server that speaks no readiness
// protocol of its own. It polls the server's health endpoint and reports
// READY=1 once it answers, so a `Type=notify` unit stays in `activating` until
// the model is servable and fails at once if the server dies while loading.
package main

import (
	"flag"
	"log"
	"os"
	"os/exec"
	"time"

	"github.com/mirkolenz/llmhop/internal/systemd"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

func main() {
	rawURL := flag.String("url", "", "address the supervised server listens on, http://127.0.0.1:<port> or unix:///<socket path>")
	healthPath := flag.String("health-path", "/health", "HTTP path used for readiness checks")
	flag.Parse()

	argv := flag.Args()

	if *rawURL == "" || len(argv) == 0 {
		log.Fatal("usage: llmhop-notify -url <url> [-health-path <path>] -- <command> [args...]")
	}

	up, err := upstream.Parse(*rawURL)
	if err != nil {
		log.Fatal(err)
	}

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr

	if err := cmd.Start(); err != nil {
		log.Fatalf("start %s: %v", argv[0], err)
	}

	go func() {
		if err := systemd.ReadyWhenHealthy(up, *healthPath, time.Second); err != nil {
			log.Fatalf("readiness: %v", err)
		}
	}()

	os.Exit(systemd.ExitCode(cmd.Wait()))
}
