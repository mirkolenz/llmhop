package monitor

import (
	"fmt"
	"image/color"
	"math"
	"strings"

	"charm.land/lipgloss/v2"
)

// The palette of the terminal, so that its theme picks the shades.
var (
	green  = lipgloss.Color("2")
	yellow = lipgloss.Color("3")
	red    = lipgloss.Color("1")
	accent = lipgloss.Color("6")
	muted  = lipgloss.Color("8")

	titleStyle  = lipgloss.NewStyle().Bold(true).Foreground(accent)
	headerStyle = lipgloss.NewStyle().Bold(true).Foreground(muted)
	mutedStyle  = lipgloss.NewStyle().Foreground(muted)
)

// meterWidth is the width of every meter in cells.
const meterWidth = 8

// meter draws a share as a bar in halves of cells, colored by its level.
func meter(share float64) string {
	if math.IsNaN(share) || math.IsInf(share, 0) {
		return mutedStyle.Render(strings.Repeat("╌", meterWidth))
	}

	halves := int(math.Round(min(max(share, 0), 1) * 2 * meterWidth))
	bar := strings.Repeat("━", halves/2) + strings.Repeat("╸", halves%2)

	return paint(levelColor(share), bar) +
		mutedStyle.Render(strings.Repeat("━", meterWidth-halves/2-halves%2))
}

// gauge shows a share as a meter and its percentage.
func gauge(share float64) string {
	return meter(share) + " " + fmtPercent(share)
}

// dots shows each of a set of servers or clients as a dot, green if it is
// up or active.
func dots(ups []float64) string {
	if len(ups) == 0 {
		return dash
	}

	var b strings.Builder

	for _, up := range ups {
		c := red

		if up == 1 {
			c = green
		}

		b.WriteString(paint(c, "●"))
	}

	return b.String()
}

// dash shows a value that nothing reports.
var dash = mutedStyle.Render("-")

// zero shows a zero muted.
var zero = mutedStyle.Render("0")

// paint colors s.
func paint(c color.Color, s string) string {
	return lipgloss.NewStyle().Foreground(c).Render(s)
}

// The widths of the values of the formatters, which pad every value to
// theirs, so that a column derives its width from them and keeps it while
// the values change.
const (
	countWidth   = 4
	rateWidth    = 6
	secondsWidth = 5
	percentWidth = 4
	tempWidth    = 5
	clockWidth   = 8
	// Such as `1023 KiB/s`.
	byteRateWidth = 10
)

// fixed pads s on the left to width cells.
func fixed(width int, s string) string {
	return strings.Repeat(" ", max(0, width-lipgloss.Width(s))) + s
}

// known shows v by show in width cells, or a dash for NaN.
func known(v float64, width int, show func(float64) string) string {
	if math.IsNaN(v) {
		return fixed(width, dash)
	}

	return fixed(width, show(v))
}

// orDash shows v in format in width cells, or a dash for NaN.
func orDash(v float64, width int, format string) string {
	return known(v, width, func(v float64) string { return fmt.Sprintf(format, v) })
}

func levelColor(share float64) color.Color {
	switch {
	case share >= 0.9:
		return red
	case share >= 0.7:
		return yellow
	}

	return green
}

// sparkTicks are the heights of a sparkline.
var sparkTicks = []rune("▁▂▃▄▅▆▇█")

// spark draws values as a sparkline of the length of a full trend, scaled
// to ceiling, or for zero to their maximum.
func spark(values []float64, ceiling float64) string {
	peak := ceiling

	for _, v := range values {
		if v > peak && !math.IsInf(v, 1) {
			peak = v
		}
	}

	var b strings.Builder

	b.WriteString(strings.Repeat(" ", max(0, trendLength-len(values))))

	for _, v := range values {
		switch {
		case math.IsNaN(v) || math.IsInf(v, 0):
			b.WriteRune(' ')
		case peak == 0:
			b.WriteRune(sparkTicks[0])
		default:
			// The metrics of a remote gateway may hold any value.
			b.WriteRune(sparkTicks[int(min(max(v/peak, 0), 1)*float64(len(sparkTicks)-1))])
		}
	}

	return paint(accent, b.String())
}

// alert shows a share of failures, colored if there are any.
func alert(share float64, c color.Color) string {
	if share > 0 {
		return paint(c, fmtPercent(share))
	}

	return fmtPercent(share)
}

// limitWidth is that of the longest reason that slows a GPU down.
const limitWidth = len("slowdown")

// warn colors a non-empty text, padded on the right to width cells.
func warn(s string, width int) string {
	if s == "" {
		s = dash
	} else {
		s = paint(yellow, s)
	}

	return s + strings.Repeat(" ", max(0, width-lipgloss.Width(s)))
}

func fmtCount(v float64) string {
	if v == 0 {
		return fixed(countWidth, zero)
	}

	return orDash(v, countWidth, "%.0f")
}

func fmtRate(v float64) string {
	return known(v, rateWidth, func(v float64) string {
		switch {
		case v == 0:
			return zero
		// The bounds are those of the rounded values, so that 9.96 shows as 10.
		case v >= 999.5:
			return fmt.Sprintf("%.1fk", v/1000)
		case v >= 9.95:
			return fmt.Sprintf("%.0f", v)
		case v >= 0.995:
			return fmt.Sprintf("%.1f", v)
		}

		return fmt.Sprintf("%.2f", v)
	})
}

func fmtSeconds(v float64) string {
	return known(v, secondsWidth, func(v float64) string {
		switch {
		case v < 0.9995:
			return fmt.Sprintf("%.0fms", v*1000)
		case v < 59.95:
			return fmt.Sprintf("%.1fs", v)
		}

		return fmt.Sprintf("%.0fm", v/60)
	})
}

// fmtPercent shows a share as a percentage, muted if zero, with a decimal
// below 10 %, so that a small share of failures never shows as zero.
func fmtPercent(share float64) string {
	return known(share*100, percentWidth, func(p float64) string {
		switch {
		case p == 0:
			return mutedStyle.Render("0%")
		case p < 0.05:
			return "<.1%"
		// The bound is that of the rounded value, so that 9.96 shows as 10%.
		case p < 9.95:
			return fmt.Sprintf("%.1f%%", p)
		}

		return fmt.Sprintf("%.0f%%", p)
	})
}

// byteUnits are the binary units of bytes.
var byteUnits = []string{"B", "KiB", "MiB", "GiB", "TiB"}

// fmtBytes shows bytes in binary units, with a decimal below ten of a unit
// beyond bytes, where the bounds are those of the rounded values.
func fmtBytes(v float64) string {
	return known(v, 0, func(v float64) string {
		unit := 0

		for ; unit < len(byteUnits)-1 && v >= 1023.5; unit++ {
			v /= 1024
		}

		if unit > 0 && v < 9.95 {
			return fmt.Sprintf("%.1f %s", v, byteUnits[unit])
		}

		return fmt.Sprintf("%.0f %s", v, byteUnits[unit])
	})
}

// fmtByteRate shows bytes per second in binary units.
func fmtByteRate(v float64) string {
	return known(v, byteRateWidth, func(v float64) string {
		if v == 0 {
			return zero
		}

		return fmtBytes(v) + "/s"
	})
}

// fmtAmount shows the used of a total amount in a unit, with decimals, the
// used one in a fixed width, so that the slashes of a column align.
func fmtAmount(used, total float64, decimals int, unit string) string {
	if math.IsNaN(used) || math.IsNaN(total) {
		return dash
	}

	// Four digits, and the point and the decimals if any.
	width := 4 + decimals + min(decimals, 1)

	return fmt.Sprintf("%*.*f/%.0f %s", width, decimals, used, total, unit)
}

// fmtUsage shows the used of the total bytes in GiB.
func fmtUsage(used, total float64) string {
	return fmtAmount(used/(1<<30), total/(1<<30), 1, "GiB")
}

// gaugeUsage shows the used share of bytes as a gauge and their amount.
func gaugeUsage(used, total float64) string {
	return gauge(used/total) + " " + fmtUsage(used, total)
}

// fmtTemp shows a temperature colored by its level toward 95 °C.
func fmtTemp(v float64) string {
	return known(v, tempWidth, func(v float64) string { return paint(levelColor(v/95), fmt.Sprintf("%.0f°C", v)) })
}

// fmtClock shows a clock in MHz.
func fmtClock(v float64) string {
	return orDash(v, clockWidth, "%.0f MHz")
}
