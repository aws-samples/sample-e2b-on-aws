package pii

const (
	tagStart = "{E}"
	tagEnd   = "{/E}"
)

func Tag(value string) string {
	if value == "" {
		return ""
	}

	return tagStart + value + tagEnd
}
