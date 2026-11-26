package sysstat

import (
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// readNumber returns the number in the first readable file of names in dir
// times scale, or NaN.
func readNumber(scale float64, dir string, names ...string) float64 {
	for _, name := range names {
		if v, err := strconv.ParseFloat(readText(filepath.Join(dir, name)), 64); err == nil {
			return v * scale
		}
	}

	return math.NaN()
}

// readText returns the trimmed content of a file, empty if unreadable.
func readText(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}

	return strings.TrimSpace(string(data))
}

// firstEntry returns the name of the first entry of dir, empty if none.
func firstEntry(dir string) string {
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) == 0 {
		return ""
	}

	return entries[0].Name()
}

// number parses a number, NaN for what nvidia-smi reports as unknown.
func number(s string) float64 {
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return math.NaN()
	}

	return v
}

// firstNumber returns the first of values that is a number, or NaN.
func firstNumber(values ...float64) float64 {
	for _, v := range values {
		if !math.IsNaN(v) {
			return v
		}
	}

	return math.NaN()
}
