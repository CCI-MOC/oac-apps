# Contributing to oac-apps

## Local pre-commit checks

We provide some pre-commit hooks for performing basic linting of your changes.
Configuring these checks to run automatically will save time when submitting
pull requests.

### Prerequisites

You will need:

- Python
- The [pre-commit] tool
- Node.js

[pre-commit]: https://pre-commit.com/

### Installing pre-commit hooks

Run:

```
pre-commit install -t pre-commit -t commit-msg
```

## Commit message standards

When writing commit messages, please follow [the 7 rules]:

1. Separate subject from body with a blank line
2. Limit the subject line to 50 characters
3. Capitalize the subject line
4. Do not end the subject line with a period
5. Use the imperative mood in the subject line
6. Wrap the body at 72 characters
7. Use the body to explain what and why vs. how

[the 7 rules]: https://cbea.ms/git-commit/

While we support the use of AI assistance when working with this repository, we
ask that you write commit messages and pull request descriptions yourself.
