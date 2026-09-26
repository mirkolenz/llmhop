// Command llmhop-notify supervises a model server that speaks no readiness
// protocol of its own. It polls the server's health endpoint and reports
// READY=1 once it answers, so a `Type=notify` unit stays in `activating` until
// the model is servable and fails at once if the server dies while loading.
package main

import (
	"flag"
	"fmt"
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

	code, err := supervise(cmd, func() error {
		return systemd.ReadyWhenHealthy(up, *healthPath, time.Second)
	})
	if err != nil {
		log.Fatal(err)
	}

	os.Exit(code)
}

func supervise(cmd *exec.Cmd, ready func() error) (int, error) {
	if err := cmd.Start(); err != nil {
		return 1, fmt.Errorf("start %s: %w", cmd.Path, err)
	}

	failed := make(chan error, 1)
	go func() {
		if err := ready(); err != nil {
			failed <- err
			_ = cmd.Process.Kill()
		}
	}()

	code := systemd.ExitCode(cmd.Wait())

	select {
	case err := <-failed:
		return 1, fmt.Errorf("readiness: %w", err)
	default:
		return code, nil
	}
}
