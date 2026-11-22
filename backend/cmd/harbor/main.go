package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/oines/xlgw-mono/backend/internal/ai"
	"github.com/oines/xlgw-mono/backend/internal/harbor"
	"github.com/oines/xlgw-mono/backend/migrations"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx); err != nil {
		slog.Error("harbor stopped", "error", err)
		os.Exit(1)
	}
}
func run(ctx context.Context) error {
	database := os.Getenv("DATABASE_URL")
	if database == "" {
		return fmt.Errorf("DATABASE_URL is required")
	}
	pool, err := pgxpool.New(ctx, database)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err = migrations.Apply(ctx, pool); err != nil {
		return err
	}
	business := &harbor.Server{DB: pool}
	if err = business.Bootstrap(ctx, os.Getenv("HARBOR_ADMIN_ACCOUNT"), os.Getenv("HARBOR_ADMIN_PASSWORD")); err != nil {
		return fmt.Errorf("admin bootstrap: %w", err)
	}
	companion, err := ai.New(pool, ai.Config{UserID: harbor.UserID, SessionActive: business.SessionActive})
	if err != nil {
		return err
	}
	defer func() {
		closeCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := companion.Close(closeCtx); err != nil {
			slog.Error("close AI host", "error", err)
		}
	}()
	business.ShareMessages = companion.ShareMessages
	mux := http.NewServeMux()
	business.Register(mux)
	harbor.RegisterCompanionAssets(mux, os.Getenv("HARBOR_COMPANION_DIR"))
	companion.Register(mux, business.Student, business.Admin)
	if dir := os.Getenv("HARBOR_CONSOLE_DIR"); dir != "" {
		mux.Handle("GET /", spa(dir))
	}
	if dir := os.Getenv("HARBOR_MOBILE_DIR"); dir != "" {
		mux.Handle("GET /mobile/", http.StripPrefix("/mobile", spa(dir)))
	}
	addr := os.Getenv("HARBOR_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	server := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 90 * time.Second}
	done := make(chan error, 1)
	go func() { slog.Info("harbor listening", "addr", addr); done <- server.ListenAndServe() }()
	go func() {
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for {
			if err := business.ProcessDue(ctx); err != nil && ctx.Err() == nil {
				slog.Error("process due work", "error", err)
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	select {
	case err := <-done:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return server.Shutdown(shutdown)
	}
}
func spa(dir string) http.Handler {
	assets := http.FileServer(http.Dir(dir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			http.NotFound(w, r)
			return
		}
		path := filepath.Join(dir, filepath.Clean("/"+r.URL.Path))
		if _, err := os.Stat(path); err == nil {
			assets.ServeHTTP(w, r)
			return
		}
		if filepath.Ext(path) != "" {
			http.NotFound(w, r)
			return
		}
		http.ServeFile(w, r, filepath.Join(dir, "index.html"))
	})
}
