package httpclient

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
)

type StreamClient struct {
	Client *http.Client
}

func (c StreamClient) Post(url string, headers map[string]string, body []byte) (io.ReadCloser, error) {
	client := c.Client
	if client == nil {
		client = http.DefaultClient
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		defer resp.Body.Close()
		data, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("http %d: %s", resp.StatusCode, bytes.TrimSpace(data))
	}
	return resp.Body, nil
}
