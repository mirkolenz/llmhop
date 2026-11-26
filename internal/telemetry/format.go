package telemetry

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// Sample is a sample of a metric with its labels.
type Sample struct {
	Name   string
	Labels map[string]string
	Value  float64
}

// Parse reads the samples from r, skipping comments and timestamps.
func Parse(r io.Reader) ([]Sample, error) {
	var out []Sample

	err := scan(r, nil, func(s Sample) { out = append(out, s) })

	return out, err
}

// scan calls yield with each sample of r whose name keep accepts, or with
// every sample without keep. It parses only those, since the metrics of an
// engine hold thousands of histogram buckets.
func scan(r io.Reader, keep func(name []byte) bool, yield func(Sample)) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(nil, 1<<20)

	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())

		if len(line) == 0 || line[0] == '#' {
			continue
		}

		if end := bytes.IndexAny(line, "{ \t"); keep != nil && end > 0 && !keep(line[:end]) {
			continue
		}

		s, err := parseLine(string(line))
		if err != nil {
			return err
		}

		yield(s)
	}

	return sc.Err()
}

func parseLine(line string) (Sample, error) {
	end := strings.IndexAny(line, "{ \t")
	if end <= 0 {
		return Sample{}, fmt.Errorf("sample %q has no metric name", line)
	}

	s := Sample{Name: line[:end]}
	rest := line[end:]

	if rest[0] == '{' {
		var err error

		if s.Labels, rest, err = parseLabels(rest[1:]); err != nil {
			return Sample{}, fmt.Errorf("sample %s: %w", s.Name, err)
		}
	}

	// The value may be followed by a timestamp.
	fields := strings.Fields(rest)
	if len(fields) == 0 {
		return Sample{}, fmt.Errorf("sample %s has no value", s.Name)
	}

	v, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return Sample{}, fmt.Errorf("sample %s: %w", s.Name, err)
	}

	s.Value = v

	return s, nil
}

// parseLabels reads the labels after the opening brace up to the closing
// one, and returns what follows it.
func parseLabels(s string) (map[string]string, string, error) {
	labels := make(map[string]string)

	for {
		s = strings.TrimLeft(s, " \t")

		if strings.HasPrefix(s, "}") {
			return labels, s[1:], nil
		}

		name, value, ok := strings.Cut(s, "=")
		value = strings.TrimLeft(value, " \t")

		if !ok || !strings.HasPrefix(value, `"`) {
			return nil, "", fmt.Errorf("malformed labels %q", s)
		}

		var b strings.Builder
		i := 1

		for ; i < len(value) && value[i] != '"'; i++ {
			c := value[i]

			if c == '\\' && i+1 < len(value) {
				i++
				c = value[i]

				if c == 'n' {
					c = '\n'
				}
			}

			b.WriteByte(c)
		}

		if i == len(value) {
			return nil, "", fmt.Errorf("unterminated label %s", name)
		}

		labels[strings.TrimSpace(name)] = b.String()
		s = strings.TrimLeft(value[i+1:], " \t")
		s = strings.TrimPrefix(s, ",")
	}
}

// Labels renders the label pairs kv of a series, such as
// `{model="m",status="200"}`.
func Labels(kv ...string) string {
	var b strings.Builder

	b.WriteByte('{')

	for i := 0; i+1 < len(kv); i += 2 {
		if i > 0 {
			b.WriteByte(',')
		}

		b.WriteString(kv[i] + `="` + escaper.Replace(kv[i+1]) + `"`)
	}

	b.WriteByte('}')

	return b.String()
}

// escaper escapes a label value as the text format quotes it.
var escaper = strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`)

// Pairs returns the label pairs kv as a map.
func Pairs(kv ...string) map[string]string {
	labels := make(map[string]string, len(kv)/2)

	for i := 0; i+1 < len(kv); i += 2 {
		labels[kv[i]] = kv[i+1]
	}

	return labels
}
