# Telegram TL schema

`api.tl` and `mtproto.tl` are copied unmodified from Telegram Desktop
(`Telegram/SourceFiles/mtproto/scheme/` in github.com/telegramdesktop/tdesktop) at commit
`a6df181ac41763a9ff9edae264dad407fb1c35ec` (2026-11-05, "Update API scheme to layer 233").

LAYER: 233 (stated by the `// LAYER 233` line at the end of `api.tl`; the client reads it from there).

To move to a newer layer, replace both files from a newer tdesktop commit and update this note.
The client sends the layer in `invokeWithLayer`, so the server answers in the shape this schema
describes.
