package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type metrics struct {
	helloCount    prometheus.Counter
	helloDuration prometheus.Histogram
}

func newMetrics(reg prometheus.Registerer) *metrics {
	return &metrics{
		helloCount: promauto.With(reg).NewCounter(prometheus.CounterOpts{
			Name: "hello_requests_total",
			Help: "Number of requests handled by the hello handler.",
		}),
		helloDuration: promauto.With(reg).NewHistogram(prometheus.HistogramOpts{
			Name:    "hello_request_duration_seconds",
			Help:    "Latency of the hello handler.",
			Buckets: prometheus.DefBuckets,
		}),
	}
}

func hello(m *metrics) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		start := time.Now()
		w.Write([]byte("Hello World\n"))
		m.helloCount.Inc()
		m.helloDuration.Observe(time.Since(start).Seconds())
	}
}

func newhello(w http.ResponseWriter, _ *http.Request) {
	w.Write([]byte("new hello world\n"))
}

func health(w http.ResponseWriter, _ *http.Request) {
	w.Write([]byte("ok\n"))
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	reg := prometheus.NewRegistry()
	m := newMetrics(reg)

	mux := http.NewServeMux()
	mux.HandleFunc("/", hello(m))
	mux.HandleFunc("/healthz", health)
	mux.HandleFunc("/new-hello", newhello)
	mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		logger.Info("listening", "port", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	logger.Info("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown failed", "error", err)
	}
}

