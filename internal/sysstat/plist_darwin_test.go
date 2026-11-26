package sysstat

import (
	"reflect"
	"testing"
)

// The I/O registry prints a list of dicts holding numbers, text and flags.
func TestDecodePlist(t *testing.T) {
	got, err := decodePlist([]byte(`<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><array><dict>
	<key>model</key><string>Apple M4 Max</string>
	<key>PerformanceStatistics</key><dict><key>Device Utilization %</key><integer>33</integer></dict>
	<key>stats</key><array><real>0.5</real><true/></array>
</dict></array></plist>`))
	if err != nil {
		t.Fatal(err)
	}

	want := []any{map[string]any{
		"model":                 "Apple M4 Max",
		"PerformanceStatistics": map[string]any{"Device Utilization %": 33.0},
		"stats":                 []any{0.5, true},
	}}

	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %#v", got)
	}
}
