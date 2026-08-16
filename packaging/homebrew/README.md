# Homebrew tap

The release workflow at `.github/workflows/release.yml` renders
`xbookmark.rb.erb` after each promoted tag and pushes the result to
the **separate** tap repository
[`ivankuznetsov/homebrew-tap`](https://github.com/ivankuznetsov/homebrew-tap)
on the `main` branch as `Formula/xbookmark.rb`.

The tap repo only needs:

```
Formula/
  xbookmark.rb   (rewritten by CI on every release)
README.md        (one-line description + install one-liner)
```

The deploy key for the tap repo is stored as the
`HOMEBREW_TAP_DEPLOY_KEY` repository secret on the xbookmark repo.

The placeholders in the template are:

| placeholder    | source                                             |
|----------------|----------------------------------------------------|
| `__VERSION__`  | `github.ref_name` with the leading `v` stripped    |
| `__REPO__`     | `github.repository` (e.g. `ivankuznetsov/xbkmrk`) |
| `__SHA256__`   | sha256 of the `arm64-darwin` Tebako binary         |
