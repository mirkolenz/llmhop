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
	"strconv"
	"time"

	"github.com/mirkolenz/llmhop/internal/systemd"
)

func main() {
	port := flag.Int("port", 0, "loopback port the supervised server listens on")
	flag.Parse()

	argv := flag.Args()

	if *port == 0 || len(argv) == 0 {
		log.Fatal("usage: llmhop-notify -port <port> -- <command> [args...]")
	}

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr

	if err := cmd.Start(); err != nil {
		log.Fatalf("start %s: %v", argv[0], err)
	}

	go func() {
		if err := systemd.ReadyWhenHealthy("http://127.0.0.1:"+strconv.Itoa(*port)+"/health", time.Second); err != nil {
			log.Fatalf("readiness: %v", err)
		}
	}()

	os.Exit(systemd.ExitCode(cmd.Wait()))
}
