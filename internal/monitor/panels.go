package monitor

import (
	"cmp"
	"math"
	"slices"
	"strings"
	"time"

	"charm.land/lipgloss/v2"

	"github.com/mirkolenz/llmhop/internal/telemetry"
)

// title names the source, and the time and how to quit at the right edge,
// followed by why the latest poll failed.
func (t *top) title(f frame) string {
	left := titleStyle.Render("llmhop") + mutedStyle.Render(" · ") + t.source
	right := mutedStyle.Render(f.now.at.Format(time.TimeOnly) + " · q quits")
	line := left + strings.Repeat(" ", max(2, t.width-lipgloss.Width(left)-lipgloss.Width(right))) + right

	if f.now.err != nil {
		line += "\n" + paint(red, "poll failed: "+f.now.err.Error())
	}

	return line
}

// trendColumn is the column of trends, which spark pads to their full
// length.
var trendColumn = column{title: "TREND", keep: 3, left: true}

// trend draws a trend, scaled to the whole of a share or to the peak of a
// rate.
func (t *top) trend(key trendKey) string {
	ceiling := 0.0

	if key.share() {
		ceiling = 1
	}

	return spark(t.trends[key], ceiling)
}

// gatewaySection shows the requests and tokens of all models, if there is a
// gateway, even while it fails to report.
func (t *top) gatewaySection(f frame) string {
	if !f.now.gateway {
		return ""
	}

	g := grid{title: "Gateway", cols: slices.Concat(
		requestColumns,
		latencyColumns,
		[]column{trendColumn},
		tokenColumns,
		[]column{trendColumn},
	)}

	g.rows = [][]string{slices.Concat(
		requestCells(f, all),
		latencyCells(f, all),
		[]string{t.trend(trendKey{gatewayTrend, "", telemetry.Requests})},
		tokenCells(f, all),
		[]string{t.trend(trendKey{gatewayTrend, "", telemetry.EngineGeneratedTokens})},
	)}

	return g.render(t.width)
}

// hostSection shows the CPUs, load, memory and swap of the host.
func (t *top) hostSection(f frame) string {
	g := grid{title: "Host", cols: []column{
		{keep: 10, left: true},
		{title: "USED", keep: 9, left: true},
		{title: "AMOUNT", keep: 5, left: true},
		trendColumn,
	}}

	for _, h := range f.hostRows() {
		g.rows = append(g.rows, []string{h.name, gauge(h.share), h.detail, t.trend(trendKey{hostTrend, h.name, ""})})
	}

	return g.render(t.width)
}

// gpuSection shows the GPUs.
func (t *top) gpuSection(f frame) string {
	g := grid{title: "GPUs", cols: []column{
		{title: "GPU", keep: 10, left: true},
		{title: "NAME", keep: 2, left: true},
		{title: "UTIL", keep: 9, left: true},
		trendColumn,
		{title: "MEMORY", keep: 9, left: true},
		{title: "TEMP", keep: 6},
		{title: "POWER", keep: 5, left: true},
		{title: "CLOCK", keep: 1},
		{title: "LIMIT", keep: 4, left: true},
		{title: "USED BY", keep: 4, left: true},
	}}

	for _, card := range f.now.gpus {
		var users []string

		for _, p := range card.Processes {
			users = append(users, p.Owner+" "+fmtBytes(p.Mem))
		}

		g.rows = append(g.rows, []string{
			card.ID,
			card.Name,
			gauge(card.Busy),
			t.trend(trendKey{gpuTrend, card.ID, ""}),
			gaugeUsage(card.MemUsed, card.MemTotal),
			fmtTemp(card.Temp),
			gauge(card.Power/card.PowerCap) + " " + fmtAmount(card.Power, card.PowerCap, 0, "W"),
			fmtClock(card.Clock),
			warn(strings.Join(card.Limits, ","), limitWidth),
			cmp.Or(strings.Join(users, ", "), dash),
		})
	}

	return g.render(t.width)
}

// diskSection shows the filesystems, their space and the traffic of their
// devices.
func (t *top) diskSection(f frame) string {
	g := grid{title: "Disks", cols: []column{
		{title: "MOUNT", keep: 10, left: true},
		{title: "SPACE", keep: 9, left: true},
		{title: "BUSY", keep: 6, left: true},
		trendColumn,
		{title: "READ/S", keep: 7},
		{title: "WRITE/S", keep: 7},
	}}

	for _, d := range f.disks() {
		g.rows = append(g.rows, []string{
			d.Mount,
			gaugeUsage(d.Size-d.Free, d.Size),
			gauge(d.busy),
			t.trend(trendKey{diskTrend, d.Mount, ""}),
			fmtByteRate(d.read),
			fmtByteRate(d.written),
		})
	}

	return g.render(t.width)
}

// networkSection shows the network interfaces and their traffic.
func (t *top) networkSection(f frame) string {
	g := grid{title: "Network", cols: []column{
		{title: "INTERFACE", keep: 10, left: true},
		{title: "IN/S", keep: 9},
		{title: "OUT/S", keep: 9},
		trendColumn,
	}}

	for _, i := range f.interfaces() {
		g.rows = append(g.rows, []string{
			i.name,
			fmtByteRate(i.received),
			fmtByteRate(i.sent),
			t.trend(trendKey{networkTrend, i.name, ""}),
		})
	}

	return g.render(t.width)
}

// modelSection shows the models, their requests and their tokens.
func (t *top) modelSection(f frame) string {
	g := grid{title: "Models", cols: slices.Concat(
		[]column{
			{title: "MODEL", keep: 10, left: true},
			{title: "UP", keep: 9, left: true},
			{title: "QUEUE", keep: 9},
			{title: "RUN", keep: 9},
			{title: "SLOTS", keep: 6, left: true},
		},
		requestColumns,
		latencyColumns,
		[]column{trendColumn},
		tokenColumns,
		[]column{trendColumn},
	)}

	for _, model := range f.models() {
		is := labeled(telemetry.Model, model)
		running := f.count(telemetry.RunningRequests, is)
		g.rows = append(g.rows, slices.Concat(
			[]string{
				model,
				dots(f.now.values(telemetry.ServerUp, is)),
				fmtCount(f.value(telemetry.QueuedRequests, is)),
				fmtCount(running),
				gauge(running / f.value(telemetry.MaxRunningRequests, is)),
			},
			requestCells(f, is),
			latencyCells(f, is),
			[]string{t.trend(trendKey{modelTrend, model, telemetry.Requests})},
			tokenCells(f, is),
			[]string{t.trend(trendKey{modelTrend, model, telemetry.EngineGeneratedTokens})},
		))
	}

	return g.render(t.width)
}

// clientSection shows the clients and their requests, whose tokens no
// engine reports.
func (t *top) clientSection(f frame) string {
	g := grid{title: "Clients", cols: slices.Concat(
		[]column{
			{title: "CLIENT", keep: 10, left: true},
			{title: "ACTIVE", keep: 9, left: true},
			{title: "RUN", keep: 9},
			{title: "SLOTS", keep: 6, left: true},
			{title: "RPM", keep: 7, left: true},
			{title: "SHARE", keep: 5, left: true},
		},
		requestColumns,
		[]column{trendColumn},
	)}

	total := f.value(telemetry.Requests, all)

	for _, client := range f.clients() {
		is := labeled(telemetry.Client, client)
		running := f.count(telemetry.RunningRequests, is)

		// A client is active while it runs requests or sent any since the
		// previous poll.
		active := 0.0

		if running > 0 || f.value(telemetry.Requests, is) > 0 {
			active = 1
		}

		g.rows = append(g.rows, slices.Concat(
			[]string{
				cmp.Or(client, dash),
				dots([]float64{active}),
				fmtCount(running),
				gauge(running / f.value(telemetry.ClientMaxRunningRequests, is)),
				gauge(1 - f.value(telemetry.ClientRemainingRequests, is)/f.value(telemetry.ClientMaxRequestsPerMinute, is)),
				gauge(f.value(telemetry.Requests, is) / total),
			},
			requestCells(f, is),
			[]string{t.trend(trendKey{clientTrend, client, telemetry.Requests})},
		))
	}

	return g.render(t.width)
}

// requestColumns are the columns of requestCells.
var requestColumns = []column{
	{title: "REQ/S", keep: 9},
	{title: "LIMITED", keep: 6},
	{title: "4XX", keep: 5},
	{title: "5XX", keep: 8},
}

// requestCells are the requests per second of a group, followed by the
// shares of them that its limits rejected with 429, that failed with
// another client error, and that failed with a server error.
func requestCells(f frame, is matcher) []string {
	total := f.value(telemetry.Requests, is)
	share := func(m matcher) float64 {
		// A group with requests but none of a status has none of them.
		failed := f.value(telemetry.Requests, both(is, m))

		if math.IsNaN(failed) && !math.IsNaN(total) {
			failed = 0
		}

		return failed / total
	}

	return []string{
		fmtRate(total),
		alert(share(status(429, 429)), yellow),
		alert(share(status(400, 499, 429)), yellow),
		alert(share(status(500, 599)), red),
	}
}

// latencyColumns are the columns of latencyCells.
var latencyColumns = []column{
	{title: "LAT", keep: 7},
	{title: "TTFT", keep: 7},
}

// latencyCells are the mean latency of the successful requests of a group
// and their mean time to the first token of a stream, which llmhop
// measures by model only.
func latencyCells(f frame, is matcher) []string {
	return []string{
		fmtSeconds(f.mean(telemetry.RequestDuration, is)),
		fmtSeconds(f.mean(telemetry.RequestFirstToken, is)),
	}
}

// tokenColumns are the columns of tokenCells.
var tokenColumns = []column{
	{title: "IN/S", keep: 5},
	{title: "OUT/S", keep: 8},
	{title: "KV", keep: 8, left: true},
	{title: "HIT", keep: 3, left: true},
}

// tokenCells are the prompt and generated tokens per second of a group,
// the use of the KV cache of its fullest server, and the share of the
// prompt tokens taken from the prefix cache.
func tokenCells(f frame, is matcher) []string {
	return []string{
		fmtRate(f.value(telemetry.EnginePromptTokens, is)),
		fmtRate(f.value(telemetry.EngineGeneratedTokens, is)),
		gauge(f.value(telemetry.EngineKVCache, is)),
		gauge(f.ratio(telemetry.EngineCachedTokens, telemetry.EnginePromptTokens, is)),
	}
}
