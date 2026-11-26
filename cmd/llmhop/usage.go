package main

import (
	"bufio"
	"cmp"
	"encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"slices"
	"strconv"
	"strings"
)

type usageCmd struct {
	By string `enum:"client,model,policy" default:"client" help:"Group by client, model or policy."`
}

// logEntry is a line of llmhop's log, a request with msg "request".
type logEntry struct {
	Msg    string `json:"msg"`
	Client string `json:"client"`
	Model  string `json:"model"`
	Policy string `json:"policy"`
	Status int    `json:"status"`
}

// Run sums the request lines of the log on stdin by group, skipping every
// other line, so that any log tool can select the source and period.
func (c usageCmd) Run() error {
	type usage struct{ requests, errors int }

	groups := make(map[string]usage)
	log := bufio.NewReader(os.Stdin)

	for {
		line, err := log.ReadBytes('\n')
		if errors.Is(err, io.EOF) && len(line) == 0 {
			break
		} else if err != nil && !errors.Is(err, io.EOF) {
			return fmt.Errorf("read log: %w", err)
		}

		var e logEntry

		if json.Unmarshal(line, &e) != nil || e.Msg != "request" {
			continue
		}

		group := e.Client

		switch c.By {
		case "model":
			group = e.Model
		case "policy":
			group = e.Policy
		}

		group = cmp.Or(group, "-")
		u := groups[group]
		u.requests++

		if e.Status >= 400 {
			u.errors++
		}

		groups[group] = u
	}

	rows := [][]string{{strings.ToUpper(c.By), "REQUESTS", "ERRORS"}}

	for _, group := range slices.Sorted(maps.Keys(groups)) {
		u := groups[group]
		rows = append(rows, []string{group, strconv.Itoa(u.requests), strconv.Itoa(u.errors)})
	}

	fmt.Print(tabulate(rows))

	return nil
}
