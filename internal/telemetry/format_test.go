package telemetry

import (
	"reflect"
	"strings"
	"testing"
)

// Labels may hold escaped quotes, braces and commas, and a timestamp may
// follow the value.
func TestParse(t *testing.T) {
	in := `# TYPE a counter
a_total 1
b{x="1",y="q \"}\", \\ \n"} 2.5 1700000000
c{ x = "" , } NaN
`

	got, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}

	if len(got) != 3 || got[2].Value == got[2].Value {
		t.Fatalf("got %+v", got)
	}

	want := []Sample{
		{Name: "a_total", Value: 1},
		{Name: "b", Labels: map[string]string{"x": "1", "y": "q \"}\", \\ \n"}, Value: 2.5},
	}

	if !reflect.DeepEqual(got[:2], want) {
		t.Errorf("got %+v, want %+v", got[:2], want)
	}

	if got := Labels("x", "1", "y", want[1].Labels["y"]); got != `{x="1",y="q \"}\", \\ \n"}` {
		t.Errorf("rendered %s", got)
	}

	if _, err := Parse(strings.NewReader(`d{x="1} 2`)); err == nil {
		t.Error("unterminated label parsed")
	}
}
