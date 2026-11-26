package main

import (
	"fmt"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"
	"unicode"

	"github.com/xhit/go-str2duration/v2"
)

// moment is a time given as a date, an RFC 3339 time or a duration
// relative to now such as 30d, 2w or 12h.
type moment struct {
	at     time.Time
	offset time.Duration
}

func (m *moment) UnmarshalText(text []byte) error {
	s := string(text)

	if d, err := str2duration.ParseDuration(s); err == nil && d > 0 {
		*m = moment{offset: d}

		return nil
	}

	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t, err = time.ParseInLocation(time.DateOnly, s, time.Local)
	}

	// The zero time means no expiry.
	if err != nil || t.IsZero() {
		return fmt.Errorf("%q is no date, RFC 3339 time or positive duration such as 30d", s)
	}

	*m = moment{at: t}

	return nil
}

// resolve returns the time of m in whole seconds, whose duration counts
// from now on.
func (m moment) resolve() time.Time {
	if m.offset == 0 {
		return m.at
	}

	return time.Now().Add(m.offset).Truncate(time.Second)
}

// tabulate renders rows as aligned columns, quoting a cell with control
// characters, such as a model name a client sent, which would break them.
func tabulate(rows [][]string) string {
	var b strings.Builder

	// Writing to a strings.Builder cannot fail.
	tw := tabwriter.NewWriter(&b, 0, 0, 2, ' ', 0)

	for _, row := range rows {
		cells := make([]string, len(row))

		for i, cell := range row {
			cells[i] = cell

			if strings.ContainsFunc(cell, unicode.IsControl) {
				cells[i] = strconv.Quote(cell)
			}
		}

		_, _ = fmt.Fprintln(tw, strings.Join(cells, "\t"))
	}

	_ = tw.Flush()

	return b.String()
}
