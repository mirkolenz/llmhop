package main

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"runtime/debug"

	"github.com/alecthomas/kong"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/router"
)

// version is set at build time through `-ldflags "-X main.version=..."`.
var version string

// Globals are the flags of every command.
type Globals struct {
	Config  string           `help:"Path of the config." default:"/etc/llmhop/config.json" env:"LLMHOP_CONFIG" type:"path"`
	Version kong.VersionFlag `help:"Print the version."`
}

// cli is the command line of llmhop.
type cli struct {
	Globals

	Serve    serveCmd    `cmd:"" help:"Serve the gateway, reloading the config on SIGHUP."`
	Check    checkCmd    `cmd:"" help:"Validate the config without serving or reading secrets."`
	Key      keyCmd      `cmd:"" help:"Manage the client keys of clientCredentials."`
	Top      topCmd      `cmd:"" help:"Show what the models and clients do right now."`
	Usage    usageCmd    `cmd:"" help:"Print the requests and errors of the log on stdin by group."`
	Internal internalCmd `cmd:"" hidden:"" help:"Commands of the NixOS module."`
}

func main() {
	// journald stamps every line itself. The standard logger, which
	// net/http writes to, forwards to this handler too.
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) == 0 && a.Key == slog.TimeKey {
				return slog.Attr{}
			}

			return a
		},
	})))

	var c cli

	ctx := kong.Parse(&c,
		kong.Name("llmhop"),
		kong.Description("The model gateway llmhop."),
		kong.Vars{"version": buildVersion()},
		kong.BindToProvider(rootConfig),
		kong.UsageOnError(),
	)
	ctx.FatalIfErrorf(ctx.Run(&c.Globals))
}

// buildVersion is the linked version, else the module version of the build.
func buildVersion() string {
	if version != "" {
		return version
	}

	if info, ok := debug.ReadBuildInfo(); ok && info.Main.Version != "" && info.Main.Version != "(devel)" {
		return info.Main.Version
	}

	return "dev"
}

type checkCmd struct{}

// Run builds the router of the config without expanding its secrets, the
// exact same router as serving, so every startup error short of binding
// surfaces.
func (checkCmd) Run(g *Globals) error {
	_, rt, err := load(g.Config, false, &router.Limits{}, nil)
	if err == nil {
		rt.Close()
	}

	return err
}

// load builds the router of the config at path with limits, expanding its
// secrets unless only checking. A config replacing prev must keep its
// listeners bound as they are, since their sockets stay open while their
// names select the client policies.
func load(path string, expand bool, limits *router.Limits, prev *config.Config) (*config.Config, *router.Router, error) {
	cfg, err := config.Load(path, expand)
	if err != nil {
		return nil, nil, fmt.Errorf("config: %w", err)
	}

	if prev != nil && !config.SameBindings(prev.Listen, cfg.Listen) {
		return nil, nil, errors.New("listen: rebinding listeners takes a restart")
	}

	rt, err := router.New(cfg, limits)
	if err != nil {
		return nil, nil, fmt.Errorf("router: %w", err)
	}

	return cfg, rt, nil
}
