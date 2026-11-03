# Web flows

speedrun's web regression flows, on a small site in `site/` (plain HTML, no build). Serve it,
then run them:

```sh
python3 -m http.server 8781 --bind 127.0.0.1 --directory dev/flows/web/site &
./speedrun test --headless dev/flows/web
```

Maestro runs them too (`maestro test --headless dev/flows/web`), for comparing the two.
