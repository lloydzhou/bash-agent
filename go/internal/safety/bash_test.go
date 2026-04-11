package safety

import "testing"

func TestDenyBashCommandReason(t *testing.T) {
	cases := []struct {
		cmd  string
		want string
	}{
		{"sudo echo blocked", "blocked dangerous command prefix"},
		{"find /tmp -name example -delete", "blocked destructive find -delete pattern"},
		{"echo hi >/dev/null", ""},
		{"echo harmless", ""},
	}
	for _, tc := range cases {
		if got := DenyBashCommandReason(tc.cmd); got != tc.want {
			t.Fatalf("cmd=%q got=%q want=%q", tc.cmd, got, tc.want)
		}
	}
}
