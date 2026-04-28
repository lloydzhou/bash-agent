package httpclient

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

// HTTPError carries HTTP/network error information with status code and body.
type HTTPError struct {
	StatusCode int    // 0 when the request never reached the server (network error)
	Body       string // response body (may be empty for network errors)
}

func (e HTTPError) Error() string {
	if e.StatusCode > 0 {
		return fmt.Sprintf("HTTP %d: %s", e.StatusCode, e.Body)
	}
	return e.Body
}

// FormatDetailed returns the canonical error string matching the Bash format:
// "ERROR:{code}\tHTTP {code}: {body}" for HTTP errors
// "ERROR:0\t{body}" for network errors
func (e HTTPError) FormatDetailed() string {
	if e.StatusCode > 0 {
		return fmt.Sprintf("ERROR:%d\tHTTP %d: %s", e.StatusCode, e.StatusCode, e.Body)
	}
	return fmt.Sprintf("ERROR:0\t%s", e.Body)
}

type StreamClient struct {
	Client *http.Client
}

const (
	defaultRetryCount            = 2
	defaultRetryDelay            = time.Second
	defaultRetryMaxTime          = 20 * time.Second
	defaultConnectTimeout        = 5 * time.Second
	defaultStreamLowSpeedLimit   = 1
	defaultStreamLowSpeedTime    = 60 * time.Second
	defaultStreamCheckInterval   = time.Second
	defaultResponseHeaderTimeout = 60 * time.Second
)

func (c StreamClient) Post(url string, headers map[string]string, body []byte) (io.ReadCloser, error) {
	client := c.Client
	if client == nil {
		client = &http.Client{
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
					conn, err := (&net.Dialer{
						Timeout: defaultConnectTimeout,
					}).DialContext(ctx, network, addr)
					if err != nil {
						return nil, err
					}
					return &speedConn{
						Conn:          conn,
						lowSpeedLimit: defaultStreamLowSpeedLimit,
						lowSpeedTime:  defaultStreamLowSpeedTime,
						checkInterval: defaultStreamCheckInterval,
						start:         time.Now(),
					}, nil
				},
				ResponseHeaderTimeout: defaultResponseHeaderTimeout,
			},
		}
	}
	start := time.Now()
	for attempt := 0; ; attempt++ {
		req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		for key, value := range headers {
			req.Header.Set(key, value)
		}

		resp, err := client.Do(req)
		if err != nil {
			if shouldRetryAttempt(attempt, start) {
				time.Sleep(defaultRetryDelay)
				continue
			}
			return nil, HTTPError{
				StatusCode: 0,
				Body:       err.Error(),
			}
		}
		if resp.StatusCode >= 400 {
			data, _ := io.ReadAll(resp.Body)
			_ = resp.Body.Close()
			retryable := shouldRetryStatus(resp.StatusCode) && shouldRetryAttempt(attempt, start)
			if retryable {
				time.Sleep(defaultRetryDelay)
				continue
			}
			return nil, HTTPError{
				StatusCode: resp.StatusCode,
				Body:       string(bytes.TrimSpace(data)),
			}
		}
		return resp.Body, nil
	}
}

type streamSample struct {
	at    time.Time
	bytes int64
}

type speedConn struct {
	net.Conn
	lowSpeedLimit int64
	lowSpeedTime  time.Duration
	checkInterval time.Duration
	start         time.Time
	samples       []streamSample
	windowBytes   int64
}

func (c *speedConn) Read(b []byte) (int, error) {
	if c.lowSpeedLimit <= 0 || c.lowSpeedTime <= 0 {
		return c.Conn.Read(b)
	}
	checkInterval := c.checkInterval
	if checkInterval <= 0 {
		checkInterval = time.Second
	}
	for {
		_ = c.Conn.SetReadDeadline(time.Now().Add(checkInterval))
		n, err := c.Conn.Read(b)
		now := time.Now()
		if n > 0 {
			c.record(now, n)
			if err == nil {
				return n, nil
			}
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				return n, nil
			}
			return n, err
		}
		if err == nil {
			return 0, nil
		}
		if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
			if c.lowSpeedExceeded(now) {
				return 0, ErrStreamRetryable
			}
			continue
		}
		return 0, err
	}
}

func (c *speedConn) record(now time.Time, n int) {
	c.samples = append(c.samples, streamSample{at: now, bytes: int64(n)})
	c.windowBytes += int64(n)
	c.prune(now)
}

func (c *speedConn) prune(now time.Time) {
	cutoff := now.Add(-c.lowSpeedTime)
	idx := 0
	for idx < len(c.samples) && c.samples[idx].at.Before(cutoff) {
		c.windowBytes -= c.samples[idx].bytes
		idx++
	}
	if idx > 0 {
		c.samples = append([]streamSample(nil), c.samples[idx:]...)
	}
}

func (c *speedConn) lowSpeedExceeded(now time.Time) bool {
	c.prune(now)
	if now.Sub(c.start) < c.lowSpeedTime {
		return false
	}
	required := c.lowSpeedLimit * int64(c.lowSpeedTime/time.Second)
	return c.windowBytes < required
}

func shouldRetryAttempt(attempt int, start time.Time) bool {
	if attempt >= defaultRetryCount {
		return false
	}
	return time.Since(start)+defaultRetryDelay <= defaultRetryMaxTime
}

func shouldRetryStatus(code int) bool {
	switch code {
	case 408, 409, 425, 429, 500, 502, 503, 504:
		return true
	default:
		return false
	}
}

// ErrStreamRetryable indicates a stream-level error that can be retried
// (e.g. low-speed timeout mid-transfer). The caller may issue a new request.
var ErrStreamRetryable = errors.New("stream interrupted: retryable")

// IsRetryableStreamError returns true if the error is a retryable stream failure
// (low-speed timeout, connection reset during transfer).
func IsRetryableStreamError(err error) bool {
	if errors.Is(err, ErrStreamRetryable) {
		return true
	}
	if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
		return true
	}
	return false
}
