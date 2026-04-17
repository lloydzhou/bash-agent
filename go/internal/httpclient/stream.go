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
	defaultRetryCount              = 2
	defaultRetryDelay              = time.Second
	defaultRetryMaxTime            = 20 * time.Second
	defaultConnectTimeout          = 5 * time.Second
	defaultStreamIdleTimeout       = 60 * time.Second
	defaultResponseHeaderTimeout   = 60 * time.Second
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
					return &deadlineConn{Conn: conn, idleTimeout: defaultStreamIdleTimeout}, nil
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

type deadlineConn struct {
	net.Conn
	idleTimeout time.Duration
}

func (c *deadlineConn) Read(b []byte) (int, error) {
	if c.idleTimeout > 0 {
		_ = c.Conn.SetReadDeadline(time.Now().Add(c.idleTimeout))
	}
	n, err := c.Conn.Read(b)
	if n > 0 && c.idleTimeout > 0 {
		_ = c.Conn.SetReadDeadline(time.Now().Add(c.idleTimeout))
	}
	if err != nil && n == 0 {
		if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
			return 0, ErrStreamRetryable
		}
	}
	return n, err
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
// (e.g. idle timeout mid-transfer). The caller may issue a new request.
var ErrStreamRetryable = errors.New("stream interrupted: retryable")

// IsRetryableStreamError returns true if the error is a retryable stream failure
// (idle timeout, connection reset during transfer).
func IsRetryableStreamError(err error) bool {
	if errors.Is(err, ErrStreamRetryable) {
		return true
	}
	if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
		return true
	}
	return false
}
