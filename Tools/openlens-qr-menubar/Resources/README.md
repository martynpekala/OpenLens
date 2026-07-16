# Bundled cloudflared

Release builds require the pinned `cloudflared-arm64` and
`cloudflared-amd64` executables in this directory. Generate them with
`../Scripts/embed-cloudflared.sh`. The binaries are intentionally ignored by
Git; the release pipeline must run the script before signing the app.
