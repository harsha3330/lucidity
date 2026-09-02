package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestHello(t *testing.T) {
	m := newMetrics(prometheus.NewRegistry())
	rec := httptest.NewRecorder()

	hello(m)(rec, httptest.NewRequest(http.MethodGet, "/", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if got := rec.Body.String(); got != "Hello World\n" {
		t.Fatalf("body = %q, want %q", got, "Hello World\n")
	}
	if got := testutil.ToFloat64(m.helloCount); got != 1 {
		t.Fatalf("hello_requests_total = %v, want 1", got)
	}
}

func TestHelloUnknownPath(t *testing.T) {
	m := newMetrics(prometheus.NewRegistry())
	rec := httptest.NewRecorder()

	hello(m)(rec, httptest.NewRequest(http.MethodGet, "/nope", nil))

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusNotFound)
	}
	if got := testutil.ToFloat64(m.helloCount); got != 0 {
		t.Fatalf("hello_requests_total = %v, want 0", got)
	}
}

func TestHealth(t *testing.T) {
	rec := httptest.NewRecorder()

	health(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
}
