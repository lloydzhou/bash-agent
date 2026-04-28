package httpclient

import (
	"net"
	"testing"
	"time"
)

type noopConn struct{}

func (noopConn) Read(b []byte) (int, error)         { return 0, nil }
func (noopConn) Write(b []byte) (int, error)        { return len(b), nil }
func (noopConn) Close() error                       { return nil }
func (noopConn) LocalAddr() net.Addr                { return nil }
func (noopConn) RemoteAddr() net.Addr               { return nil }
func (noopConn) SetDeadline(t time.Time) error      { return nil }
func (noopConn) SetReadDeadline(t time.Time) error  { return nil }
func (noopConn) SetWriteDeadline(t time.Time) error { return nil }

func TestSpeedConnLowSpeedWindow(t *testing.T) {
	start := time.Unix(0, 0)
	conn := &speedConn{
		Conn:          noopConn{},
		lowSpeedLimit: 1,
		lowSpeedTime:  60 * time.Second,
		start:         start,
	}

	if conn.lowSpeedExceeded(start.Add(59 * time.Second)) {
		t.Fatal("unexpected timeout before window elapsed")
	}
	if !conn.lowSpeedExceeded(start.Add(60 * time.Second)) {
		t.Fatal("expected timeout after 60 seconds with no bytes")
	}

	conn.record(start.Add(30*time.Second), 100)
	if conn.lowSpeedExceeded(start.Add(60 * time.Second)) {
		t.Fatal("unexpected timeout with enough recent bytes")
	}

	if !conn.lowSpeedExceeded(start.Add(91 * time.Second)) {
		t.Fatal("expected timeout once bytes age out of the window")
	}
}
