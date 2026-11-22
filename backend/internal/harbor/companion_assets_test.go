package harbor

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const testCompanionModel = "versioned companion geometry"

func writeCompanionFixture(t *testing.T, root, name string, body []byte) {
	t.Helper()
	name = filepath.Join(root, name)
	if err := os.MkdirAll(filepath.Dir(name), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(name, body, 0644); err != nil {
		t.Fatal(err)
	}
}

func writeCompanionManifest(t *testing.T, root string, bundle companionBundle) {
	t.Helper()
	value, err := json.Marshal(bundle)
	if err != nil {
		t.Fatal(err)
	}
	writeCompanionFixture(t, root, "manifest.json", value)
}

func companionFixtureFile(name, contents string) companionFile {
	digest := sha256.Sum256([]byte(contents))
	return companionFile{Path: name, Size: int64(len(contents)), SHA256: hex.EncodeToString(digest[:])}
}

func writeCompanionBundle(t *testing.T, dir, release string) companionBundle {
	t.Helper()
	root := filepath.Join(dir, release)
	bundle := companionBundle{
		Release: release,
		Version: 1,
		Files: []companionFile{
			companionFixtureFile("companion.glb", testCompanionModel),
			companionFixtureFile("thumbnails/hair-1.png", "a texture"),
		},
	}
	writeCompanionFixture(t, root, "companion.glb", []byte(testCompanionModel))
	writeCompanionFixture(t, root, "thumbnails/hair-1.png", []byte("a texture"))
	writeCompanionManifest(t, root, bundle)
	return bundle
}

func newCompanionTestServer(t *testing.T, dir string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	RegisterCompanionAssets(mux, dir)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func companionGet(t *testing.T, srv *httptest.Server, method, path string, headers map[string]string) (*http.Response, []byte) {
	t.Helper()
	req, err := http.NewRequest(method, srv.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	for name, value := range headers {
		req.Header.Set(name, value)
	}
	client := *srv.Client()
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp, body
}

func testCompanionCatalog(t *testing.T, srv *httptest.Server) companionCatalog {
	t.Helper()
	resp, body := companionGet(t, srv, http.MethodGet, "/api/v1/companion/assets", nil)
	if resp.StatusCode != http.StatusOK || resp.Header.Get("Cache-Control") != "no-cache" {
		t.Fatalf("catalog: status=%d, cache=%q", resp.StatusCode, resp.Header.Get("Cache-Control"))
	}
	var result companionCatalog
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	if result.Bundles == nil {
		t.Fatal("bundles should be a JSON array")
	}
	return result
}

func TestCompanionReleaseDiscoveryAndDownload(t *testing.T) {
	dir := t.TempDir()
	srv := newCompanionTestServer(t, dir)
	if empty := testCompanionCatalog(t, srv); empty.Current != "" || len(empty.Bundles) != 0 {
		t.Fatalf("empty directory: %+v", empty)
	}

	v1 := writeCompanionBundle(t, dir, "2026.11.14-01")
	v2 := writeCompanionBundle(t, dir, "2026.11.14-02")
	writeCompanionFixture(t, dir, "current", []byte(v1.Release+"\n"))
	rootV1 := filepath.Join(dir, v1.Release)
	writeCompanionFixture(t, rootV1, "extra.png", []byte("not in manifest"))
	writeCompanionFixture(t, rootV1, "viewer.js", []byte("not an asset"))
	if got := testCompanionCatalog(t, srv); got.Current != v1.Release ||
		len(got.Bundles) != 2 || got.Bundles[0].Release != v2.Release ||
		got.Bundles[1].Files[0] != v1.Files[0] {
		t.Fatalf("pinned release: %+v", got)
	}

	base := "/companion-assets/" + v1.Release
	modelURL := base + "/companion.glb"
	resp, body := companionGet(t, srv, http.MethodGet, modelURL, nil)
	tag := `"` + v1.Files[0].SHA256 + `"`
	if resp.StatusCode != 200 || string(body) != testCompanionModel ||
		resp.Header.Get("Cache-Control") != "public, max-age=31536000, immutable" ||
		resp.Header.Get("Content-Type") != "model/gltf-binary" ||
		resp.Header.Get("X-Content-Type-Options") != "nosniff" ||
		resp.Header.Get("ETag") != tag {
		t.Fatalf("model response=%+v, body=%q", resp, body)
	}

	resp, body = companionGet(t, srv, http.MethodGet, base+"/thumbnails/hair-1.png", nil)
	if resp.StatusCode != 200 || string(body) != "a texture" || resp.Header.Get("Content-Type") != "image/png" {
		t.Fatalf("nested image: status=%d mime=%q body=%q", resp.StatusCode, resp.Header.Get("Content-Type"), body)
	}
	resp, body = companionGet(t, srv, http.MethodHead, modelURL, nil)
	if resp.StatusCode != 200 || len(body) != 0 || resp.ContentLength != v1.Files[0].Size {
		t.Fatalf("head: status=%d content-length=%d body=%q", resp.StatusCode, resp.ContentLength, body)
	}
	resp, body = companionGet(t, srv, http.MethodGet, modelURL, map[string]string{"If-None-Match": tag})
	if resp.StatusCode != 304 || len(body) != 0 {
		t.Fatalf("conditional: status=%d body=%q", resp.StatusCode, body)
	}
	resp, body = companionGet(t, srv, http.MethodGet, modelURL, map[string]string{"Range": "bytes=0-3"})
	if resp.StatusCode != 206 || string(body) != testCompanionModel[:4] {
		t.Fatalf("range: status=%d body=%q", resp.StatusCode, body)
	}

	for _, asset := range []string{"extra.png", "viewer.js", "manifest.json", "%2e%2e/%2e%2e/private.png", "thumbnails/%2e%2e/companion.glb"} {
		resp, _ := companionGet(t, srv, http.MethodGet, base+"/"+asset, nil)
		if resp.StatusCode != 404 || resp.Header.Get("Cache-Control") != "no-store" {
			t.Errorf("%s unexpectedly served: status=%d cache=%q", asset, resp.StatusCode, resp.Header.Get("Cache-Control"))
		}
	}

	if err := os.Remove(filepath.Join(dir, "current")); err != nil {
		t.Fatal(err)
	}
	if got := testCompanionCatalog(t, srv); got.Current != v2.Release {
		t.Fatalf("automatic rollover selected %q", got.Current)
	}
	resp, _ = companionGet(t, srv, http.MethodGet, modelURL, nil)
	if resp.StatusCode != 200 {
		t.Fatalf("older bundle should remain download-able, status=%d", resp.StatusCode)
	}
}

func TestCompanionRejectsInvalidOrModifiedBundles(t *testing.T) {
	dir := t.TempDir()
	srv := newCompanionTestServer(t, dir)
	good := writeCompanionBundle(t, dir, "01-ready")
	version := writeCompanionBundle(t, dir, "02-incompatible")
	version.Version = 2
	writeCompanionManifest(t, filepath.Join(dir, version.Release), version)
	badHash := writeCompanionBundle(t, dir, "03-checksum")
	badHash.Files[0].SHA256 = badHash.Files[1].SHA256
	writeCompanionManifest(t, filepath.Join(dir, badHash.Release), badHash)
	unsafe := writeCompanionBundle(t, dir, "04-unsafe")
	unsafe.Files = append(unsafe.Files, companionFixtureFile("thumbnails/../companion.glb", testCompanionModel))
	writeCompanionManifest(t, filepath.Join(dir, unsafe.Release), unsafe)
	escape := writeCompanionBundle(t, dir, "05-escape")
	eRoot := filepath.Join(dir, escape.Release)
	if err := os.Remove(filepath.Join(eRoot, "companion.glb")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../"+good.Release+"/companion.glb", filepath.Join(eRoot, "companion.glb")); err != nil {
		t.Fatal(err)
	}
	executable := writeCompanionBundle(t, dir, "06-executable")
	executable.Files = append(executable.Files, companionFixtureFile("viewer.js", "run()"))
	writeCompanionFixture(t, filepath.Join(dir, executable.Release), "viewer.js", []byte("run()"))
	writeCompanionManifest(t, filepath.Join(dir, executable.Release), executable)
	missing := writeCompanionBundle(t, dir, "07-no-model")
	missing.Files = missing.Files[1:]
	writeCompanionManifest(t, filepath.Join(dir, missing.Release), missing)
	writeCompanionFixture(t, dir, "current", []byte(badHash.Release))

	if result := testCompanionCatalog(t, srv); result.Current != good.Release || len(result.Bundles) != 1 {
		t.Fatalf("invalid releases published: %+v", result)
	}
	for _, release := range []string{version.Release, badHash.Release, unsafe.Release, escape.Release, executable.Release, missing.Release} {
		resp, _ := companionGet(t, srv, http.MethodGet, "/companion-assets/"+release+"/companion.glb", nil)
		if resp.StatusCode != 404 {
			t.Errorf("invalid release %s served %d", release, resp.StatusCode)
		}
	}

	root := filepath.Join(dir, good.Release)
	mutated := "X" + testCompanionModel[1:]
	writeCompanionFixture(t, root, "companion.glb", []byte(mutated))
	modified := time.Now().Add(time.Minute)
	if err := os.Chtimes(filepath.Join(root, "companion.glb"), modified, modified); err != nil {
		t.Fatal(err)
	}
	if result := testCompanionCatalog(t, srv); result.Current != "" || len(result.Bundles) != 0 {
		t.Fatalf("modified bytes remained published: %+v", result)
	}
	good.Files[0] = companionFixtureFile("companion.glb", mutated)
	writeCompanionManifest(t, root, good)
	resp, _ := companionGet(t, srv, http.MethodGet, "/companion-assets/"+good.Release+"/companion.glb", nil)
	if resp.StatusCode != 404 {
		t.Fatalf("reused immutable URL served different bytes: %d", resp.StatusCode)
	}
}

func TestCompanionUnconfigured(t *testing.T) {
	srv := newCompanionTestServer(t, "")
	if result := testCompanionCatalog(t, srv); result.Current != "" || len(result.Bundles) != 0 {
		t.Fatalf("unconfigured: %+v", result)
	}
	resp, _ := companionGet(t, srv, http.MethodGet, "/companion-assets/one/companion.glb", nil)
	if resp.StatusCode != 404 {
		t.Fatalf("unconfigured asset: %d", resp.StatusCode)
	}
}
