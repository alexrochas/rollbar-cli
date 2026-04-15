# rollbar-cli

Minimal Rollbar API CLI for local use and for Codex/AI-driven fetches.

The executable remains `rollbar`; the repository name is `rollbar-cli`.

## Install

```bash
./install.sh
```

By default this links `rollbar` into `~/.local/bin` and adds that folder to your shell PATH if needed.

## Dependencies

- `curl`
- `jq`

## Usage

List items:

```bash
rollbar items
rollbar items --status active --level error --environment production
rollbar items 'is:active level:error framework:node'
```

Fetch a single item:

```bash
rollbar item 456
rollbar item --id 272505123
```

Fetch occurrences for an item:

```bash
rollbar occurrences 456
rollbar occurrences --id 272505123 --page 2
```

Fetch project metadata:

```bash
rollbar project
rollbar project 123456
```

Call any Rollbar REST endpoint directly:

```bash
rollbar --path /api/1/items
rollbar --path /api/1/project/123456
rollbar --path /api/1/rql/jobs ./body.json
```

Call a saved template from `./templates/`:

```bash
rollbar --path /api/1/rql/jobs my-job
rollbar --list-templates
```

## Config

The script looks for config in this order:

1. `--env-file <path>`
2. `./.rollbar.env`
3. `<project-root>/.rollbar.env`
4. `~/.rollbar.env`
5. Existing shell environment

Use shell-style env files. This tool supports your existing variables directly:

```bash
ROLLBAR_TOKEN=""
PROJECT_ID=""
```

It also supports the more explicit project variable name:

```bash
ROLLBAR_TOKEN=""
ROLLBAR_PROJECT_ID=""
```

Optional:

```bash
ROLLBAR_BASE_URL="https://api.rollbar.com"
```

## Notes

- Authentication uses the `X-Rollbar-Access-Token` header, matching the official Rollbar API docs.
- `rollbar item <counter>` defaults to the project counter you see in Rollbar item URLs. Use `--id` to fetch by raw Rollbar item ID instead.
- `rollbar occurrences` resolves counters to item IDs automatically before calling the occurrences endpoint.
- Response output is pretty-printed with `jq` by default. You can shape it with `--jq '<filter>'` or disable formatting with `--raw`.
- Use `--dry-run` to inspect the resolved endpoint and payload without sending a request.

## Homebrew

This repo is designed to be tapped from `alexrochas/tools` the same way as `jira-cli`.

Formula to add in `homebrew-tools/Formula/rollbar-cli.rb`:

```ruby
class RollbarCli < Formula
  desc "Minimal Rollbar API CLI"
  homepage "https://github.com/alexrochas/rollbar-cli"
  head "https://github.com/alexrochas/rollbar-cli.git", branch: "main"

  depends_on "jq"

  def install
    libexec.install "rollbar", "rollbar.sh", "templates"
    bin.install_symlink libexec/"rollbar"
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/rollbar --help")
  end
end
```
