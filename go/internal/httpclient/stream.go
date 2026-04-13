package httpclient

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"time"
)

type StreamClient struct {
	Client *http.Client
}

const (
	defaultRetryCount   = 2
	defaultRetryDelay   = time.Second
	defaultRetryMaxTime = 20 * time.Second
)

func (c StreamClient) Post(url string, headers map[string]string, body []byte) (io.ReadCloser, error) {
	client := c.Client
	if client == nil {
		client = http.DefaultClient
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
			return nil, err
		}
		if resp.StatusCode >= 400 {
			data, _ := io.ReadAll(resp.Body)
			_ = resp.Body.Close()
			httpErr := fmt.Errorf("http %d: %s", resp.StatusCode, bytes.TrimSpace(data))
			if shouldRetryStatus(resp.StatusCode) && shouldRetryAttempt(attempt, start) {
				time.Sleep(defaultRetryDelay)
				continue
			}
			return nil, httpErr
		}
		return resp.Body, nil
	}
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
