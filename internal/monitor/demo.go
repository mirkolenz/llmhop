package monitor

import (
	"context"
	"math"
	"strconv"
	"time"

	"github.com/mirkolenz/llmhop/internal/sysstat"
	"github.com/mirkolenz/llmhop/internal/telemetry"
)

// Demo monitors synthetic metrics of two models, each on its own CUDA GPU,
// two clients, two disks and two network interfaces, whose load rises and
// falls, to show the monitor without a gateway.
func Demo(interval time.Duration) error {
	if err := requireTerminal(); err != nil {
		return err
	}

	d := &demo{start: time.Now(), counters: make(map[string]float64)}

	return run("demo", interval, d.collect)
}

// demo is the state of the synthetic metrics, whose counters count up.
type demo struct {
	start, last time.Time
	counters    map[string]float64
}

// demoModel is a model of the demo, with its server and the unit of the
// server, which holds memory of a GPU of its own.
type demoModel struct {
	name, server, unit string
	memory, slots      float64
	// rate is its peak of requests per second, and latency and firstToken
	// the mean seconds of a request.
	rate, latency, firstToken float64
	// period is how many seconds its load takes to rise and fall.
	period float64
}

// demoPrompt and demoCompletion are the tokens of a request.
const (
	demoPrompt     = 900
	demoCompletion = 260
)

var demoModels = []demoModel{
	{"qwen3-8b", "unix:///run/llmhop/vllm-qwen3-8b/http.sock", "llmhop-vllm-qwen3-8b", 22 * gib, 64, 24, 2.1, 0.18, 40},
	{"llama-3.3-70b", "unix:///run/llmhop/sglang-llama-3.3-70b/http.sock", "llmhop-sglang-llama-3.3-70b", 74 * gib, 48, 6, 7.5, 0.45, 70},
}

// demoClients are the clients of the demo by their share of the requests,
// with their slots, and their requests, tokens and slot seconds per minute.
var demoClients = []struct {
	name                                                  string
	share, slots, perMinute, tokensPerMinute, slotSeconds float64
}{{"alice", 0.7, 96, 3000, 3_000_000, 4800}, {"bob", 0.3, 32, 600, 600_000, 1200}}

const (
	mib = 1 << 20
	gib = 1 << 30
	tib = 1 << 40
)

func (d *demo) collect(context.Context) *snapshot {
	now := time.Now()
	seconds := now.Sub(d.last).Seconds()

	if d.last.IsZero() {
		seconds = 0
	}

	d.last = now
	elapsed := now.Sub(d.start).Seconds()

	// wave rises and falls between 0 and 1 over period seconds.
	wave := func(period, phase float64) float64 {
		return 0.5 + 0.5*math.Sin(2*math.Pi*elapsed/period+phase)
	}

	var samples []telemetry.Sample

	gauge := func(name string, v float64, kv ...string) {
		samples = append(samples, telemetry.Sample{Name: name, Labels: telemetry.Pairs(kv...), Value: v})
	}
	// grow counts up a counter at a rate.
	grow := func(key string, rate float64) float64 {
		d.counters[key] += rate * seconds

		return d.counters[key]
	}
	count := func(name string, rate float64, kv ...string) {
		gauge(name, grow(name+telemetry.Labels(kv...), rate), kv...)
	}

	var gpus []sysstat.GPU

	// perMinute and slotSeconds sum the requests and slot seconds per minute
	// of each client, whose tokens follow from its requests.
	perMinute, slotSeconds := make(map[string]float64), make(map[string]float64)

	for i, m := range demoModels {
		load := 0.2 + 0.8*wave(m.period, float64(i))
		rate := m.rate * load

		for _, c := range demoClients {
			perMinute[c.name] += 60 * rate * c.share
			count(telemetry.Requests, rate*c.share*0.96, telemetry.Client, c.name, telemetry.Model, m.name, telemetry.Status, "200")
			count(telemetry.Tokens, rate*c.share*demoPrompt, telemetry.Client, c.name, telemetry.Model, m.name, telemetry.Kind, telemetry.Prompt)
			count(telemetry.Tokens, rate*c.share*demoCompletion, telemetry.Client, c.name, telemetry.Model, m.name, telemetry.Kind, telemetry.Completion)
			gauge(telemetry.RunningRequests, math.Round(rate*c.share*m.latency), telemetry.Model, m.name, telemetry.Client, c.name)
			slotSeconds[c.name] += 60 * rate * c.share * m.latency

			// The limits reject bob at the peaks, and the engines fail rarely.
			if c.name == "bob" {
				count(telemetry.Requests, rate*c.share*0.1*max(0, load-0.7), telemetry.Client, c.name, telemetry.Model, m.name, telemetry.Status, "429")
			}

			count(telemetry.Requests, rate*c.share*0.005, telemetry.Client, c.name, telemetry.Model, m.name, telemetry.Status, "500")
		}

		count(telemetry.RequestDuration+"_sum", rate*m.latency*(0.8+0.4*load), telemetry.Model, m.name)
		count(telemetry.RequestDuration+"_count", rate, telemetry.Model, m.name)
		count(telemetry.RequestFirstToken+"_sum", rate*m.firstToken*(0.7+0.6*load), telemetry.Model, m.name)
		count(telemetry.RequestFirstToken+"_count", rate, telemetry.Model, m.name)
		gauge(telemetry.QueuedRequests, math.Round(4*max(0, load-0.75)/0.25), telemetry.Model, m.name)
		gauge(telemetry.MaxRunningRequests, m.slots, telemetry.Model, m.name)

		kv := []string{telemetry.Model, m.name, telemetry.Server, m.server}
		gauge(telemetry.ServerUp, 1, kv...)
		gauge(telemetry.EngineUp, 1, kv...)
		gauge(telemetry.EngineKVCache, 0.25+0.7*load, kv...)
		count(telemetry.EnginePromptTokens, rate*demoPrompt, kv...)
		count(telemetry.EngineCachedTokens, rate*demoPrompt*(0.4+0.3*wave(30, 1)), kv...)
		count(telemetry.EngineGeneratedTokens, rate*demoCompletion, kv...)
		gpus = append(gpus, demoGPU(i, load, m.memory, m.unit))
	}

	for _, c := range demoClients {
		gauge(telemetry.ClientMaxRunningRequests, c.slots, telemetry.Client, c.name)
		gauge(telemetry.ClientMaxRequestsPerMinute, c.perMinute, telemetry.Client, c.name)
		gauge(telemetry.ClientRemainingRequests, max(0, c.perMinute-perMinute[c.name]), telemetry.Client, c.name)
		gauge(telemetry.ClientMaxTokensPerMinute, c.tokensPerMinute, telemetry.Client, c.name)
		gauge(telemetry.ClientRemainingTokens, max(0, c.tokensPerMinute-perMinute[c.name]*(demoPrompt+demoCompletion)), telemetry.Client, c.name)
		gauge(telemetry.ClientMaxSlotSeconds, c.slotSeconds, telemetry.Client, c.name)
		gauge(telemetry.ClientRemainingSlotSeconds, max(0, c.slotSeconds-slotSeconds[c.name]), telemetry.Client, c.name)
		count(telemetry.SlotSeconds, slotSeconds[c.name]/60, telemetry.Client, c.name)
	}

	return &snapshot{
		at:      now,
		gateway: true,
		samples: samples,
		gpus:    gpus,
		host: &sysstat.Host{
			CPUs:         64,
			Busy:         grow("cpu busy", 64*(0.15+0.2*wave(20, 0))),
			Total:        grow("cpu total", 64),
			Load:         [3]float64{9 + 6*wave(20, 0), 10.4, 9.7},
			MemTotal:     512 * gib,
			MemAvailable: (300 - 40*wave(60, 0)) * gib,
			SwapTotal:    8 * gib,
			SwapFree:     7.6 * gib,
			Disks: []sysstat.Disk{
				{
					Mount:   "/",
					Size:    3.5 * tib,
					Free:    2.1 * tib,
					Read:    grow("disk read", 40*mib*wave(25, 0)),
					Written: grow("disk written", 6*mib),
					Busy:    grow("disk busy", 0.05+0.3*wave(25, 0)),
				},
				{Mount: "/boot", Size: gib, Free: 0.8 * gib},
			},
			Interfaces: []sysstat.Interface{
				{Name: "enp65s0f0", Received: grow("received", 2*mib*wave(20, 0)), Sent: grow("sent", 9*mib*wave(20, 0))},
				{Name: "tailscale0", Received: grow("vpn received", 30*1024), Sent: grow("vpn sent", 120*1024)},
			},
		},
	}
}

// demoGPU is an H100 at a load, whose server holds memory.
func demoGPU(index int, load, memory float64, owner string) sysstat.GPU {
	g := sysstat.GPU{
		ID:        strconv.Itoa(index),
		Name:      "NVIDIA H100 80GB HBM3",
		Busy:      load,
		MemUsed:   memory + 2*gib*load,
		MemTotal:  80 * gib,
		Temp:      38 + 45*load,
		Power:     90 + 610*load,
		PowerCap:  700,
		Clock:     1980 - 300*max(0, load-0.8)/0.2,
		Processes: []sysstat.Process{{Owner: owner, Mem: memory}},
	}

	if load > 0.92 {
		g.Limits = []string{"power"}
	}

	return g
}
