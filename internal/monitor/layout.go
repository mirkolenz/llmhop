package monitor

import (
	"slices"
	"strings"

	"charm.land/lipgloss/v2"
)

// render draws the title and the sections below each other, spaced by
// blank lines while they fit the height, else without them and without the
// last sections that do not fit, and clipped to the height. The disks and
// the network, of the least weight beside the gateway, trail.
func (t *top) render() string {
	if t.now == nil {
		return "Polling " + t.source + " ..."
	}

	f := t.frame()
	sections := slices.DeleteFunc([]string{
		t.title(f),
		t.gatewaySection(f),
		t.hostSection(f),
		t.gpuSection(f),
		t.modelSection(f),
		t.clientSection(f),
		t.diskSection(f),
		t.networkSection(f),
	}, func(s string) bool { return s == "" })
	screen := strings.Join(sections, "\n\n")

	for shown := len(sections); shown > 1 && t.height > 0 && lipgloss.Height(screen) > t.height; shown-- {
		screen = strings.Join(sections[:shown], "\n")
	}

	if lines := strings.Split(screen, "\n"); t.height > 0 && len(lines) > t.height {
		screen = strings.Join(lines[:t.height], "\n")
	}

	return screen
}

// column is a column of a grid, as wide as its widest cell, whose keep
// ranks it among the columns kept while the screen is too narrow, the
// lowest dropped first. The formatters of values give every value of a
// column the same width.
type column struct {
	title string
	keep  int
	left  bool
}

// grid is a titled table whose columns drop out to fit a width.
type grid struct {
	title string
	cols  []column
	rows  [][]string
}

// padding separates the columns of a grid.
const padding = 2

// render draws g below a rule of its title across width, unless it is
// zero, dropping the last of the least kept columns while they are too
// wide, or nothing without rows.
func (g grid) render(width int) string {
	if len(g.rows) == 0 {
		return ""
	}

	titles := make([]string, len(g.cols))
	widths := make([]int, len(g.cols))

	for i, c := range g.cols {
		titles[i] = headerStyle.Render(c.title)
		widths[i] = lipgloss.Width(c.title)
	}

	for _, r := range g.rows {
		for i, cell := range r {
			widths[i] = max(widths[i], lipgloss.Width(cell))
		}
	}

	shown, total := make([]int, len(g.cols)), -padding

	for i, w := range widths {
		shown[i] = i
		total += w + padding
	}

	for width > 0 && total > width && len(shown) > 1 {
		drop := 0

		for i, c := range shown {
			if g.cols[c].keep <= g.cols[shown[drop]].keep {
				drop = i
			}
		}

		total -= widths[shown[drop]] + padding
		shown = slices.Delete(shown, drop, drop+1)
	}

	line := func(cells []string) string {
		out := make([]string, len(shown))

		for i, c := range shown {
			fill := strings.Repeat(" ", widths[c]-lipgloss.Width(cells[c]))

			if g.cols[c].left {
				out[i] = cells[c] + fill
			} else {
				out[i] = fill + cells[c]
			}
		}

		return strings.TrimRight(strings.Join(out, strings.Repeat(" ", padding)), " ")
	}

	if width <= 0 {
		width = total
	}

	lines := []string{titleStyle.Render(g.title) + " " + mutedStyle.Render(strings.Repeat("─", max(0, width-lipgloss.Width(g.title)-1)))}

	lines = append(lines, line(titles))

	for _, r := range g.rows {
		lines = append(lines, line(r))
	}

	return strings.Join(lines, "\n")
}
