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
	"os/signal"
	"strconv"
	"syscall"
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

	// Caught, not ignored: SIG_IGN survives exec, so the server would inherit it
	// and never see the SIGINT it drains on. Dying of the cgroup-wide stop signal
	// would read to systemd as the service being gone, earning the server a
	// SIGKILL mid-drain.
	signal.Notify(make(chan os.Signal, 1), syscall.SIGINT, syscall.SIGTERM)

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr

	if err := cmd.Start(); err != nil {
		log.Fatalf("start %s: %v", argv[0], err)
	}

	go systemd.ReadyWhenHealthy("http://127.0.0.1:"+strconv.Itoa(*port)+"/health", time.Second)

	os.Exit(systemd.ExitCode(cmd.Wait()))
}
