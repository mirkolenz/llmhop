// Package hubcache prunes the Hugging Face hub cache of a worker down to the
// revisions it serves. The fetcher controls everything in the cache, so every
// read and delete goes through an [os.Root] of it, and no directory is entered
// through a symlink.
package hubcache

import (
	"errors"
	"io/fs"
	"maps"
	"os"
	"path"
	"strings"
	"syscall"
)

// Repository is a repository the hub cache keeps.
type Repository struct {
	// Name is the cache directory of the repository, as in `models--org--name`.
	Name string `json:"name"`
	// Revision is the ref or commit kept, or empty (JSON null) for every ref.
	Revision string `json:"revision"`
}

// Specification is the hub cache of a worker and the repositories it keeps.
type Specification struct {
	Hub          string       `json:"hub"`
	Repositories []Repository `json:"repositories"`
}

// Prune deletes everything in the hub cache that spec does not reference.
func Prune(spec Specification) error {
	root, err := os.OpenRoot(spec.Hub)
	if err != nil {
		return err
	}

	defer func() { _ = root.Close() }()

	wanted := map[string]map[string]bool{}

	for _, r := range spec.Repositories {
		if wanted[r.Name] == nil {
			wanted[r.Name] = map[string]bool{}
		}

		wanted[r.Name][r.Revision] = true
	}

	fsys := root.FS()

	entries, err := fs.ReadDir(fsys, ".")
	if err != nil {
		return err
	}

	repos := []string{}

	for _, entry := range entries {
		repo := entry.Name()

		if !strings.HasPrefix(repo, "models--") {
			continue
		}

		// Anything but a directory is stale, a symlink is removed itself.
		if revisions, ok := wanted[repo]; ok && entry.IsDir() {
			repos = append(repos, repo)
			err = pruneRepository(root, repo, revisions)
		} else {
			err = removeStale(root, repo)
		}

		if err != nil {
			return err
		}
	}

	return pruneBlobs(root, repos)
}

// removeStale deletes the stale repo and its locks.
func removeStale(root *os.Root, repo string) error {
	if err := root.RemoveAll(repo); err != nil {
		return err
	}

	if ok, err := isDir(root.FS(), ".locks"); !ok {
		return err
	}

	return root.RemoveAll(path.Join(".locks", repo))
}

// pruneRepository deletes the refs of repo that revisions do not name, and
// the snapshots that no remaining ref or revision names.
func pruneRepository(root *os.Root, repo string, revisions map[string]bool) error {
	fsys := root.FS()
	refs := path.Join(repo, "refs")
	// A revision without a ref names a commit.
	commits := maps.Clone(revisions)

	err := walk(fsys, refs, func(ref string, entry fs.DirEntry) error {
		if !entry.Type().IsRegular() {
			return nil
		}

		if !revisions[""] && !revisions[strings.TrimPrefix(ref, refs+"/")] {
			return root.Remove(ref)
		}

		commit, err := fs.ReadFile(fsys, ref)
		if err != nil {
			return err
		}

		commits[strings.TrimSpace(string(commit))] = true

		return nil
	})
	if err != nil {
		return err
	}

	snapshots := path.Join(repo, "snapshots")

	if ok, err := isDir(fsys, snapshots); !ok {
		return err
	}

	entries, err := fs.ReadDir(fsys, snapshots)
	if err != nil {
		return err
	}

	for _, snapshot := range entries {
		if commits[snapshot.Name()] {
			continue
		}

		if err := root.RemoveAll(path.Join(snapshots, snapshot.Name())); err != nil {
			return err
		}
	}

	return nil
}

// fileID identifies a file independent of the links leading to it.
type fileID struct{ dev, ino uint64 }

// resolve returns the file that name is or links to, unless it is dangling
// or escapes the root.
func resolve(root *os.Root, name string) (fileID, bool) {
	info, err := root.Stat(name)
	if err != nil {
		return fileID{}, false
	}

	stat := info.Sys().(*syscall.Stat_t)

	return fileID{uint64(stat.Dev), stat.Ino}, true
}

// pruneBlobs deletes every blob of repos and of the shared blob store that
// recent `huggingface_hub` releases keep, unless a snapshot links to it.
func pruneBlobs(root *os.Root, repos []string) error {
	fsys := root.FS()
	used := map[fileID]bool{}
	blobs := map[string]fileID{}

	useSnapshot := func(name string, _ fs.DirEntry) error {
		if id, ok := resolve(root, name); ok {
			used[id] = true
		}

		return nil
	}

	collectBlob := func(name string, _ fs.DirEntry) error {
		id, ok := resolve(root, name)
		if !ok {
			return root.Remove(name)
		}

		blobs[name] = id

		return nil
	}

	for _, repo := range repos {
		err := errors.Join(
			walk(fsys, path.Join(repo, "snapshots"), useSnapshot),
			walk(fsys, path.Join(repo, "blobs"), collectBlob),
		)
		if err != nil {
			return err
		}
	}

	if err := walk(fsys, "blobs", collectBlob); err != nil {
		return err
	}

	for blob, id := range blobs {
		if used[id] {
			continue
		}

		if err := root.Remove(blob); err != nil {
			return err
		}
	}

	return nil
}

// isDir tells whether name is a directory rather than a symlink to one, and
// false for a missing name.
func isDir(fsys fs.FS, name string) (bool, error) {
	info, err := fs.Lstat(fsys, name)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}

	return err == nil && info.IsDir(), err
}

// walk calls fn with every entry below dir that is not a directory. Unlike
// [fs.WalkDir], it never enters a dir that is a symlink, and a missing dir
// has no entries.
func walk(fsys fs.FS, dir string, fn func(name string, entry fs.DirEntry) error) error {
	if ok, err := isDir(fsys, dir); !ok {
		return err
	}

	return fs.WalkDir(fsys, dir, func(name string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}

		return fn(name, entry)
	})
}
