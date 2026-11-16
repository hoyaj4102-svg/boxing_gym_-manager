package templates

import (
	"html/template"
	"os"
	"strings"
	"testing"
)

func render(t *testing.T, path string, data map[string]any) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := template.New(path).Parse(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	var builder strings.Builder
	if err := parsed.Execute(&builder, data); err != nil {
		t.Fatal(err)
	}
	return builder.String()
}

func TestLocaleBranches(t *testing.T) {
	var nilMap map[string]any
	cases := []struct {
		name    string
		data    map[string]any
		english bool
	}{
		{name: "english", data: map[string]any{"Data": map[string]any{"locale": "en"}}, english: true},
		{name: "korean", data: map[string]any{"Data": map[string]any{"locale": "ko"}}, english: false},
		{name: "missing locale", data: map[string]any{"Data": map[string]any{}}, english: false},
		{name: "nil metadata map", data: map[string]any{"Data": nilMap}, english: false},
		{name: "no data field", data: map[string]any{}, english: false},
	}

	for _, file := range []string{"confirmation.html", "recovery.html"} {
		for _, tc := range cases {
			payload := map[string]any{
				"ConfirmationURL": "https://example.test/auth/v1/verify?token=example&type=signup",
				"RedirectTo":      "https://example.test/login?lang=en",
			}
			for key, value := range tc.data {
				payload[key] = value
			}
			body := render(t, file, payload)
			if tc.english {
				if !strings.Contains(body, "Confirm your email address") && !strings.Contains(body, "Reset your password") {
					t.Fatalf("%s %s did not render English: %s", file, tc.name, body)
				}
				if strings.Contains(body, "이메일 주소를 확인해 주세요") || strings.Contains(body, "비밀번호를 다시 설정해 주세요") {
					t.Fatalf("%s %s also rendered Korean: %s", file, tc.name, body)
				}
			} else {
				if !strings.Contains(body, "이메일 주소를 확인해 주세요") && !strings.Contains(body, "비밀번호를 다시 설정해 주세요") {
					t.Fatalf("%s %s did not render Korean: %s", file, tc.name, body)
				}
				if strings.Contains(body, "Confirm your email address") || strings.Contains(body, "Reset your password") {
					t.Fatalf("%s %s also rendered English: %s", file, tc.name, body)
				}
			}
		}
	}
}
