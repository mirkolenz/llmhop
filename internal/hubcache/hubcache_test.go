package hubcache

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// download fetches commit of repo at ref, as `hf download` would.
func download(t *testing.T, repo, commit, ref string) {
	t.Helper()

	snapshot := filepath.Join(repo, "snapshots", commit)

	for _, dir := range []string{filepath.Join(repo, "refs"), snapshot, filepath.Join(repo, "blobs")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	files := map[string]string{
		filepath.Join(repo, "blobs", commit): commit,
		filepath.Join(repo, "refs", ref):     commit + "\n",
	}

	for name, content := range files {
		if err := os.WriteFile(name, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if err := os.Symlink(filepath.Join("..", "..", "blobs", commit), filepath.Join(snapshot, "model")); err != nil {
		t.Fatal(err)
	}
}

func TestPrune(t *testing.T) {
	hub := t.TempDir()
	repo := filepath.Join(hub, "models--a--b")
	every := filepath.Join(hub, "models--c--d")
	outside := t.TempDir()
	keep := filepath.Join(outside, "keep")
	spec := Specification{Hub: hub, Repositories: []Repository{
		{Name: "models--a--b", Revision: "main"},
		// llama.cpp pins no revision, so every ref stays.
		{Name: "models--c--d"},
	}}

	prune := func() {
		t.Helper()

		if err := Prune(spec); err != nil {
			t.Fatal(err)
		}
	}

	check := func(path string, exists bool) {
		t.Helper()

		if _, err := os.Lstat(path); (err == nil) != exists {
			t.Errorf("%s: exists %v, want %v", path, err == nil, exists)
		}
	}

	download(t, repo, "a1", "main")
	download(t, repo, "p1", "pr")
	download(t, every, "x1", "main")
	download(t, every, "y1", "trunk")

	if err := os.WriteFile(keep, nil, 0o644); err != nil {
		t.Fatal(err)
	}

	if err := os.MkdirAll(filepath.Join(hub, "models--stale", "snapshots", "s1"), 0o755); err != nil {
		t.Fatal(err)
	}

	// Neither a stale symlink nor a blob linking out of the hub is followed.
	if err := os.Symlink(outside, filepath.Join(hub, "models--escape")); err != nil {
		t.Fatal(err)
	}

	if err := os.Symlink(outside, filepath.Join(repo, "blobs", "escape")); err != nil {
		t.Fatal(err)
	}

	// A planted blobs symlink is never entered, so the files it leads to stay.
	planted := filepath.Join(every, "extra")

	if err := os.MkdirAll(planted, 0o755); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(filepath.Join(planted, "keep"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	if err := os.Symlink(planted, filepath.Join(hub, "blobs")); err != nil {
		t.Fatal(err)
	}

	prune()
	check(filepath.Join(hub, "models--stale"), false)
	check(filepath.Join(hub, "models--escape"), false)
	check(filepath.Join(repo, "blobs", "escape"), false)
	check(keep, true)
	check(filepath.Join(repo, "refs", "pr"), false)
	check(filepath.Join(repo, "snapshots", "p1"), false)
	check(filepath.Join(repo, "blobs", "p1"), false)
	check(filepath.Join(planted, "keep"), true)
	check(filepath.Join(repo, "snapshots", "a1"), true)
	check(filepath.Join(repo, "blobs", "a1"), true)
	check(filepath.Join(every, "snapshots", "x1"), true)
	check(filepath.Join(every, "snapshots", "y1"), true)

	// Pruning drops the previous snapshot of a moved ref and its blobs.
	download(t, repo, "b2", "main")
	prune()
	check(filepath.Join(repo, "snapshots", "a1"), false)
	check(filepath.Join(repo, "blobs", "a1"), false)
	check(filepath.Join(repo, "snapshots", "b2"), true)
	check(filepath.Join(repo, "blobs", "b2"), true)
}

// The payloads of the shared blob store that a snapshot uses stay with their
// manifests, the others go, and a marker deleted by pruning before returns.
func TestPruneShared(t *testing.T) {
	hub := t.TempDir()
	repo := filepath.Join(hub, "models--a--b")
	marker := filepath.Join(hub, sharedMarker)
	spec := Specification{Hub: hub, Repositories: []Repository{{Name: "models--a--b", Revision: "main"}}}

	download(t, repo, "a1", "main")
	download(t, repo, "b2", "pr")

	// share moves the blob of commit into the store, as huggingface_hub does.
	share := func(commit string) string {
		t.Helper()

		hash := strings.Repeat(commit, 32)
		payload := filepath.Join(hub, "blobs", hash[:2], hash)
		blob := filepath.Join(repo, "blobs", commit)

		err := errors.Join(
			os.MkdirAll(filepath.Dir(payload), 0o755),
			os.Rename(blob, payload),
			os.Symlink(filepath.Join("..", "..", "blobs", hash[:2], hash), blob),
			os.WriteFile(payload+".refs", []byte("models--a--b/blobs/"+commit+"\n"), 0o644),
		)
		if err != nil {
			t.Fatal(err)
		}

		return payload
	}

	kept, dropped := share("a1"), share("b2")

	if err := os.WriteFile(marker, []byte(sharedLayout), 0o644); err != nil {
		t.Fatal(err)
	}

	for i := range 2 {
		if i == 1 {
			if err := os.Remove(marker); err != nil {
				t.Fatal(err)
			}
		}

		if err := Prune(spec); err != nil {
			t.Fatal(err)
		}

		if got, err := os.ReadFile(marker); string(got) != sharedLayout {
			t.Errorf("marker %q, %v", got, err)
		}

		for name, want := range map[string]bool{kept: true, kept + ".refs": true, dropped: false, dropped + ".refs": false} {
			if _, err := os.Lstat(name); (err == nil) != want {
				t.Errorf("%s: exists %v, want %v", name, err == nil, want)
			}
		}
	}
}
