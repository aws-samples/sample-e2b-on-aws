package build

import "testing"

func TestExpandEnvVars(t *testing.T) {
	tests := []struct {
		name   string
		value  string
		envs   map[string]string
		expect string
	}{
		{
			name:   "braced var",
			value:  "/new:${PATH}",
			envs:   map[string]string{"PATH": "/usr/bin"},
			expect: "/new:/usr/bin",
		},
		{
			name:   "unbraced var",
			value:  "/new:$PATH",
			envs:   map[string]string{"PATH": "/usr/bin"},
			expect: "/new:/usr/bin",
		},
		{
			name:   "undefined var expands to empty",
			value:  "${UNDEFINED}",
			envs:   map[string]string{},
			expect: "",
		},
		{
			name:   "no expansion needed",
			value:  "/static/path",
			envs:   map[string]string{"PATH": "/usr/bin"},
			expect: "/static/path",
		},
		{
			name:   "multiple vars",
			value:  "$HOME/$USER",
			envs:   map[string]string{"HOME": "/root", "USER": "admin"},
			expect: "/root/admin",
		},
		{
			name:   "empty value",
			value:  "",
			envs:   map[string]string{"PATH": "/usr/bin"},
			expect: "",
		},
		{
			name:   "self reference via snapshot",
			value:  "/new/bin:${PATH}",
			envs:   map[string]string{"PATH": "/usr/local/bin:/usr/bin:/bin"},
			expect: "/new/bin:/usr/local/bin:/usr/bin:/bin",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := expandEnvVars(tt.value, tt.envs)
			if got != tt.expect {
				t.Errorf("expandEnvVars(%q) = %q, want %q", tt.value, got, tt.expect)
			}
		})
	}
}
