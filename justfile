# The loop analyses this project by running `just <recipe> <dir>`, in whatever
# directory the work names as its project; it does not know mix or exunit.

export MIX_ENV := "test"

# Make a new copy of this project runnable, once, after the loop makes it.
copy-setup:
    mix deps.get

# Take down what this copy made for itself, before the loop removes it: this
# project makes nothing outside its own directory, so there is nothing to take down.
copy-teardown:

run dir:
    mix test

certify dir:
    mix compile --warnings-as-errors
    mix test

# Build the prod release and its Homebrew tarball (on an Apple silicon Mac), then
# print the tarball's path and sha256 for packaging/codemyspec.rb. `app` is
# the CodeMySpec app's repository: its plugins/phoenix and its interview skill go
# into the release as the default plugin and instructions that `workflow init` writes.
package app="":
    @test -n "{{app}}" || { echo "just package: give the app repository's path: just package <path>" >&2; exit 1; }
    @test -d "{{app}}" || { echo "just package: the app repository {{app}} does not exist" >&2; exit 1; }
    @test -f "{{app}}/plugins/phoenix/.claude-plugin/plugin.json" || { echo "just package: {{app}} has no plugin plugins/phoenix (with .claude-plugin/plugin.json)" >&2; exit 1; }
    @test -f "{{app}}/plugins/claude/directory/skills/interview/SKILL.md" || { echo "just package: {{app}} has no instructions file plugins/claude/directory/skills/interview/SKILL.md" >&2; exit 1; }
    @# The tarball is public: personal paths, emails (but example.com and its subdomains, yourdomain placeholders and Resend's public resend.dev test addresses; kamal-proxy's own /home/kamal-proxy on a server) and key-shaped values in what it would carry stop the build, each named by file and line.
    @found=$(grep -rnoIE -e '/(Users|Volumes|home)/[^ )`"]*' -e '~/(Documents|Desktop|Downloads|github|Projects|src|code|dev)/[^ )`"]*' -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -e '(sk-[A-Za-z0-9]{16,}|sk_(live|test)_[A-Za-z0-9]+|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[abp]-[A-Za-z0-9-]+|whsec_[A-Za-z0-9+/=]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY)' "{{app}}/plugins/phoenix" "{{app}}/plugins/claude/directory/skills/interview/SKILL.md" | grep -vE '@(([A-Za-z0-9-]+\.)*example\.(com|org|net)|yourdomain\.[a-z]+|resend\.dev)$' | grep -vE ':/home/kamal-proxy/'); if [ -n "$found" ]; then echo "just package: these would ship in the public tarball; clean them in the app repository, then build again:" >&2; echo "$found" >&2; exit 1; fi
    MIX_ENV=prod mix deps.get
    MIX_ENV=prod mix release --overwrite
    rm -rf _build/prod/rel/workflow/plugin _build/prod/rel/workflow/instructions.md
    cp -R "{{app}}/plugins/phoenix" _build/prod/rel/workflow/plugin
    cp "{{app}}/plugins/claude/directory/skills/interview/SKILL.md" _build/prod/rel/workflow/instructions.md
    tar -C _build/prod/rel/workflow -czf _build/codemyspec-darwin-arm64.tar.gz .
    @echo "tarball: {{justfile_directory()}}/_build/codemyspec-darwin-arm64.tar.gz"
    @shasum -a 256 _build/codemyspec-darwin-arm64.tar.gz | cut -d ' ' -f 1 | sed 's/^/sha256: /'

# Publish the commit tagged v<version> as the brew release: package it with `app`,
# upload the tarball as GitHub release v<version>, and write the formula, filled in
# from packaging/codemyspec.rb, to Code-My-Spec/homebrew-tap. It never tags.
release version app:
    #!/usr/bin/env bash
    set -euo pipefail
    version="{{version}}"
    tag="v$version"
    repo="Code-My-Spec/workflow"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "just release: version $version is not N.N.N (for example 3.0.4)" >&2; exit 1; }
    tags=$(git tag --points-at HEAD 2>/dev/null || true)
    grep -qx "$tag" <<<"$tags" || { echo "just release: HEAD is not tagged $tag; check out the commit tagged $tag (release never tags)" >&2; exit 1; }
    if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then echo "just release: release $tag already exists in $repo" >&2; exit 1; fi
    out=$(just --justfile "{{justfile()}}" --working-directory "$PWD" package "{{app}}")
    echo "$out"
    tarball=$(sed -n 's/^tarball: //p' <<<"$out")
    sha=$(sed -n 's/^sha256: //p' <<<"$out")
    [ -n "$tarball" ] && [ -n "$sha" ] || { echo "just release: just package printed no tarball or sha256" >&2; exit 1; }
    gh release create "$tag" "$tarball" --repo "$repo" --title "$tag" --notes "codemyspec $version for macOS on Apple silicon"
    url="https://github.com/$repo/releases/download/$tag/codemyspec-darwin-arm64.tar.gz"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    git clone -q https://github.com/Code-My-Spec/homebrew-tap.git "$tmp/tap"
    mkdir -p "$tmp/tap/Formula"
    sed -e "s|__URL__|$url|" -e "s|__SHA256__|$sha|" "{{justfile_directory()}}/packaging/codemyspec.rb" > "$tmp/tap/Formula/codemyspec.rb"
    git -C "$tmp/tap" add Formula/codemyspec.rb
    git -C "$tmp/tap" rm -q --ignore-unmatch Formula/codemyspec-loop.rb
    if git -C "$tmp/tap" diff --cached --quiet; then echo "just release: the tap's formula is already $version; nothing to push"; exit 0; fi
    git -C "$tmp/tap" commit -q -m "codemyspec $version"
    git -C "$tmp/tap" push -q
