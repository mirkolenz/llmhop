package monitor

import (
	"cmp"
	"slices"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// render draws the title and the sections below each other, spaced by
// blank lines while they fit the height, else without them and without the
// last sections that do not fit, which the renderer clips to the screen.
// The disks and the network, of the least weight beside the gateway, trail.
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

	return screen
}

// column is a column of a grid, as wide as its widest cell, whose keep
// ranks it among the columns kept while the screen is too narrow, the
// lowest dropped first. A column of free text, such as names, may shrink
// to shrinkWidth instead, truncating its cells, before any column drops.
// The formatters of values give every value of a column the same width.
type column struct {
	title  string
	keep   int
	left   bool
	shrink bool
}

// shrinkWidth is the least width that a column of free text shrinks to.
const shrinkWidth = 16

// grid is a titled table whose columns shrink and drop out to fit a width.
type grid struct {
	title string
	cols  []column
	rows  [][]string
}

// padding separates the columns of a grid.
const padding = 2

// render draws g below a rule of its title across width, unless it is
// zero, dropping the last of the least kept columns while they are too
// wide at their least widths, then shrinking the least kept to fit, or
// nothing without rows.
func (g grid) render(width int) string {
	if len(g.rows) == 0 {
		return ""
	}

	titles := make([]string, len(g.cols))
	widths := make([]int, len(g.cols))
	floors := make([]int, len(g.cols))
	shown := make([]int, len(g.cols))

	for i, c := range g.cols {
		titles[i] = headerStyle.Render(c.title)
		widths[i] = ansi.StringWidth(c.title)
		shown[i] = i
	}

	for _, r := range g.rows {
		for i, cell := range r {
			widths[i] = max(widths[i], ansi.StringWidth(cell))
		}
	}

	for i, c := range g.cols {
		floors[i] = widths[i]

		if c.shrink {
			floors[i] = min(widths[i], max(shrinkWidth, ansi.StringWidth(c.title)))
		}
	}

	total := func(ws []int) int {
		sum := -padding

		for _, c := range shown {
			sum += ws[c] + padding
		}

		return sum
	}

	for width > 0 && total(floors) > width && len(shown) > 1 {
		drop := 0

		for i, c := range shown {
			if g.cols[c].keep <= g.cols[shown[drop]].keep {
				drop = i
			}
		}

		shown = slices.Delete(shown, drop, drop+1)
	}

	if width > 0 {
		excess := total(widths) - width

		for _, c := range slices.SortedStableFunc(slices.Values(shown), func(a, b int) int {
			return cmp.Compare(g.cols[a].keep, g.cols[b].keep)
		}) {
			if excess <= 0 {
				break
			}

			cut := min(excess, widths[c]-floors[c])
			widths[c] -= cut
			excess -= cut
		}
	}

	line := func(cells []string) string {
		out := make([]string, len(shown))

		for i, c := range shown {
			align := lipgloss.Right

			if g.cols[c].left {
				align = lipgloss.Left
			}

			out[i] = lipgloss.PlaceHorizontal(widths[c], align, ansi.Truncate(cells[c], widths[c], ellipsis))
		}

		return strings.TrimRight(strings.Join(out, strings.Repeat(" ", padding)), " ")
	}

	if width <= 0 {
		width = total(widths)
	}

	lines := []string{titleStyle.Render(g.title) + " " + mutedStyle.Render(strings.Repeat("─", max(0, width-ansi.StringWidth(g.title)-1)))}

	lines = append(lines, line(titles))

	for _, r := range g.rows {
		lines = append(lines, line(r))
	}

	return strings.Join(lines, "\n")
}
