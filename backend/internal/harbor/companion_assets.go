package harbor

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"regexp"
	"slices"
	"strings"
	"sync"
)

const (
	companionTopologyVersion = 1
	companionFileLimit       = 64
	companionFileSizeLimit   = 64 << 20
	companionBundleSizeLimit = 100 << 20
	companionManifestLimit   = 32 << 10
)

var (
	companionReleasePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{0,79}$`)
	companionSegmentPattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]*$`)
	companionDigestPattern  = regexp.MustCompile(`^[a-f0-9]{64}$`)
)

type companionFile struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

type companionBundle struct {
	Release string          `json:"release"`
	Version int             `json:"version"`
	Files   []companionFile `json:"files"`
}

type companionCatalog struct {
	Current string            `json:"current"`
	Bundles []companionBundle `json:"bundles"`
}

type verifiedCompanionBundle struct {
	bundle companionBundle
	digest [sha256.Size]byte
	stats  map[string]os.FileInfo
}

type companionAssets struct {
	dir      string
	mu       sync.Mutex
	verified map[string]verifiedCompanionBundle
}

// RegisterCompanionAssets serves versioned companion assets via a manifest
// allowlist. A release directory, once published, is immutable.
func RegisterCompanionAssets(mux *http.ServeMux, dir string) {
	assets := &companionAssets{
		dir:      strings.TrimSpace(dir),
		verified: make(map[string]verifiedCompanionBundle),
	}
	mux.HandleFunc("GET /api/v1/companion/assets", assets.catalog)
	mux.HandleFunc("GET /companion-assets/{release}/{asset...}", assets.file)
}

func companionContentType(name string) string {
	switch path.Ext(name) {
	case ".glb", ".vrm":
		return "model/gltf-binary"
	case ".png":
		return "image/png"
	case ".webp":
		return "image/webp"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	default:
		return ""
	}
}

func validCompanionPath(name string) bool {
	if len(name) > 120 || companionContentType(name) == "" {
		return false
	}
	for segment := range strings.SplitSeq(name, "/") {
		if !companionSegmentPattern.MatchString(segment) {
			return false
		}
	}
	return true
}

func readCompanionMetadata(root *os.Root, name string, limit int64) []byte {
	info, err := root.Lstat(name)
	if err != nil || !info.Mode().IsRegular() || info.Size() > limit {
		return nil
	}
	file, err := root.Open(name)
	if err != nil {
		return nil
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || int64(len(raw)) > limit {
		return nil
	}
	return raw
}

func sameCompanionFile(a, b os.FileInfo) bool {
	return a != nil && b != nil && os.SameFile(a, b) &&
		a.Size() == b.Size() && a.ModTime().Equal(b.ModTime())
}

func companionFileMatches(root *os.Root, spec companionFile, info os.FileInfo) bool {
	file, err := root.Open(spec.Path)
	if err != nil {
		return false
	}
	defer file.Close()
	stat, err := file.Stat()
	if err != nil || !sameCompanionFile(info, stat) {
		return false
	}
	digest := sha256.New()
	size, err := io.Copy(digest, io.LimitReader(file, spec.Size+1))
	return err == nil && size == spec.Size && hex.EncodeToString(digest.Sum(nil)) == spec.SHA256
}

func (a *companionAssets) validate(releaseRoot *os.Root, release string) (verifiedCompanionBundle, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()

	raw := readCompanionMetadata(releaseRoot, "manifest.json", companionManifestLimit)
	digest := sha256.Sum256(raw)
	cached := a.verified[release]
	invalid := verifiedCompanionBundle{}
	if cached.stats != nil && cached.digest != digest {
		// Refuse to change the contents associated with an existing URL.
		return invalid, false
	}
	bundle := cached.bundle
	if cached.stats == nil {
		err := json.Unmarshal(raw, &bundle)
		if err != nil || bundle.Release != release || bundle.Version != companionTopologyVersion ||
			len(bundle.Files) == 0 || len(bundle.Files) > companionFileLimit {
			return invalid, false
		}
	}

	verified := verifiedCompanionBundle{bundle: bundle, digest: digest, stats: make(map[string]os.FileInfo, len(bundle.Files))}
	var model bool
	var total int64
	for _, item := range bundle.Files {
		if !validCompanionPath(item.Path) || !companionDigestPattern.MatchString(item.SHA256) ||
			item.Size < 1 || item.Size > companionFileSizeLimit || verified.stats[item.Path] != nil {
			return invalid, false
		}
		total += item.Size
		if total > companionBundleSizeLimit {
			return invalid, false
		}
		info, err := releaseRoot.Stat(item.Path)
		if err != nil || !info.Mode().IsRegular() || info.Size() != item.Size {
			return invalid, false
		}
		if !sameCompanionFile(cached.stats[item.Path], info) && !companionFileMatches(releaseRoot, item, info) {
			return invalid, false
		}
		verified.stats[item.Path] = info
		model = model || item.Path == "companion.glb"
	}
	if !model {
		return invalid, false
	}
	a.verified[release] = verified
	return verified, true
}

func openCompanionRelease(root *os.Root, release string) (*os.Root, error) {
	if !companionReleasePattern.MatchString(release) {
		return nil, fs.ErrNotExist
	}
	info, err := root.Lstat(release)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, fs.ErrNotExist
	}
	return root.OpenRoot(release)
}

func (a *companionAssets) catalog(w http.ResponseWriter, r *http.Request) {
	result := companionCatalog{Bundles: []companionBundle{}}
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if a.dir != "" {
		root, err := os.OpenRoot(a.dir)
		if err == nil {
			result = a.readCatalog(root)
			root.Close()
		}
	}
	_ = json.NewEncoder(w).Encode(result)
}

func (a *companionAssets) readCatalog(root *os.Root) companionCatalog {
	result := companionCatalog{Bundles: []companionBundle{}}
	entries, err := fs.ReadDir(root.FS(), ".")
	if err != nil {
		return result
	}
	current := strings.TrimSpace(string(readCompanionMetadata(root, "current", 128)))
	for _, entry := range slices.Backward(entries) {
		release := entry.Name()
		if !entry.IsDir() {
			continue
		}
		releaseRoot, err := openCompanionRelease(root, release)
		if err != nil {
			continue
		}
		verified, ok := a.validate(releaseRoot, release)
		releaseRoot.Close()
		if !ok {
			continue
		}
		result.Bundles = append(result.Bundles, verified.bundle)
		if release == current || result.Current == "" {
			result.Current = release
		}
	}
	return result
}

func (a *companionAssets) file(w http.ResponseWriter, r *http.Request) {
	release, asset := r.PathValue("release"), r.PathValue("asset")
	w.Header().Set("Cache-Control", "no-store")
	if a.dir == "" || !validCompanionPath(asset) {
		http.NotFound(w, r)
		return
	}
	root, err := os.OpenRoot(a.dir)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer root.Close()
	releaseRoot, err := openCompanionRelease(root, release)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer releaseRoot.Close()
	verified, ok := a.validate(releaseRoot, release)
	info := verified.stats[asset]
	if !ok || info == nil {
		http.NotFound(w, r)
		return
	}
	file, err := releaseRoot.Open(asset)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer file.Close()
	stat, err := file.Stat()
	if err != nil || !sameCompanionFile(info, stat) {
		http.NotFound(w, r)
		return
	}
	for _, item := range verified.bundle.Files {
		if item.Path == asset {
			w.Header().Set("ETag", `"`+item.SHA256+`"`)
			break
		}
	}
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	w.Header().Set("Content-Type", companionContentType(asset))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, asset, stat.ModTime(), file)
}
