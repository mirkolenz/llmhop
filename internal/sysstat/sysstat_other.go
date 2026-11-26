//go:build !linux && !darwin

package sysstat

import (
	"context"
	"time"
)

// gpuSource reports no GPUs where no collector exists.
type gpuSource struct{}

func newGPUSource(context.Context, time.Duration) *gpuSource {
	return &gpuSource{}
}

func (*gpuSource) read(context.Context) []GPU {
	return nil
}
