#!/bin/bash
# Patch go-prompt: replace getMultilinePrefix body to return ""
# so continuation lines have no prefix, matching Rust rustyline behavior.
set -e

dir=$(ls -d "$1"/github.com/joeycumines/go-prompt@* 2>/dev/null || true)
if [ -z "$dir" ]; then
    echo "go-prompt not found in gomodcache, skipping patch"
    exit 0
fi

file="$dir/renderer.go"
if ! grep -q 'multilinePrefixBuilder\.String()' "$file"; then
    echo "go-prompt already patched or different version, skipping"
    exit 0
fi

chmod u+w "$dir" "$file"

# Use perl to match the function definition and replace the entire body
# Match: func (r *Renderer) getMultilinePrefix(...) string {
#   ... anything ...
#   return multilinePrefixBuilder.String()
# }
perl -0777 -pi -e '
    s{
        func[ ]\(r[ ]\*Renderer\)[ ]getMultilinePrefix\(prefix[ ]string\)[ ]string[ ]\{
        .*?
        return[ ]multilinePrefixBuilder\.String\(\)\n\}
    }{func (r *Renderer) getMultilinePrefix(prefix string) string {\n\treturn ""\n}}xs
' "$file"

echo "Patched $file: getMultilinePrefix now returns empty string"
